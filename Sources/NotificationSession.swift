//
// Wire
// Copyright (C) 2020 Wire Swiss GmbH
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
//


import Foundation
import WireDataModel
import WireTransport
import WireRequestStrategy
import WireLinkPreview

class ClientRegistrationStatus : NSObject, ClientRegistrationDelegate {
    
    let context : NSManagedObjectContext
    
    init(context: NSManagedObjectContext) {
        self.context = context
    }
    
    var clientIsReadyForRequests: Bool {
        if let clientId = context.persistentStoreMetadata(forKey: "PersistedClientId") as? String { // TODO move constant into shared framework
            return !clientId.isEmpty
        }
        
        return false
    }
    
    func didDetectCurrentClientDeletion() {
        // nop
    }
}

class AuthenticationStatus : AuthenticationStatusProvider {
    
    let transportSession : ZMTransportSession
    
    init(transportSession: ZMTransportSession) {
        self.transportSession = transportSession
    }
    
    var state: AuthenticationState {
        return isLoggedIn ? .authenticated : .unauthenticated
    }
    
    private var isLoggedIn : Bool {
        return transportSession.cookieStorage.authenticationCookieData != nil
    }
    
}

extension BackendEnvironmentProvider {
    func cookieStorage(for account: Account) -> ZMPersistentCookieStorage {
        let backendURL = self.backendURL.host!
        return ZMPersistentCookieStorage(forServerName: backendURL, userIdentifier: account.userIdentifier)
    }
    
    public func isAuthenticated(_ account: Account) -> Bool {
        return cookieStorage(for: account).authenticationCookieData != nil
    }
}

class ApplicationStatusDirectory : ApplicationStatus {

    let transportSession : ZMTransportSession

    /// The authentication status used to verify a user is authenticated
    public let authenticationStatus: AuthenticationStatusProvider

    /// The client registration status used to lookup if a user has registered a self client
    public let clientRegistrationStatus : ClientRegistrationDelegate

    public let linkPreviewDetector: LinkPreviewDetectorType
    
    public var pushNotificationStatus: PushNotificationStatus

    public init(managedObjectContext: NSManagedObjectContext,
                transportSession: ZMTransportSession,
                authenticationStatus: AuthenticationStatusProvider,
                clientRegistrationStatus: ClientRegistrationStatus,
                linkPreviewDetector: LinkPreviewDetectorType) {
        self.transportSession = transportSession
        self.authenticationStatus = authenticationStatus
        self.clientRegistrationStatus = clientRegistrationStatus
        self.linkPreviewDetector = linkPreviewDetector
        self.pushNotificationStatus = PushNotificationStatus(managedObjectContext: managedObjectContext)
    }

    public convenience init(syncContext: NSManagedObjectContext, transportSession: ZMTransportSession) {
        let authenticationStatus = AuthenticationStatus(transportSession: transportSession)
        let clientRegistrationStatus = ClientRegistrationStatus(context: syncContext)
        let linkPreviewDetector = LinkPreviewDetector()
        
        self.init(managedObjectContext: syncContext,transportSession: transportSession, authenticationStatus: authenticationStatus, clientRegistrationStatus: clientRegistrationStatus, linkPreviewDetector: linkPreviewDetector)
    }

    public var synchronizationState: SynchronizationState {
        if clientRegistrationStatus.clientIsReadyForRequests {
            return .online
        } else {
            return .unauthenticated
        }
    }

    public var operationState: OperationState {
        return .background
    }

    public var clientRegistrationDelegate: ClientRegistrationDelegate {
        return self.clientRegistrationStatus
    }

    public var requestCancellation: ZMRequestCancellation {
        return transportSession
    }

    func requestSlowSync() {
        // we don't do slow syncing in the notification engine
    }

}

public protocol NotificationSessionDelegate: AnyObject {

    func notificationSessionDidGenerateNotification(_ notification: ZMLocalNotification?, unreadConversationCount: Int)
    func reportCallEvent(_ event: ZMUpdateEvent, currentTimestamp: TimeInterval)

}

/// A syncing layer for the notification processing
/// - note: this is the entry point of this framework. Users of
/// the framework should create an instance as soon as possible in
/// the lifetime of the notification extension, and hold on to that session
/// for the entire lifetime.
public class NotificationSession {

    /// The failure reason of a `NotificationSession` initialization
    /// - noAccount: Account doesn't exist
    public enum InitializationError: Error {
        case noAccount
    }

    // MARK: - Properties

    /// Directory of all application statuses
    private let applicationStatusDirectory : ApplicationStatusDirectory

    /// The list to which save notifications of the UI moc are appended and persistet
    private let saveNotificationPersistence: ContextDidSaveNotificationPersistence
    private var contextSaveObserverToken: NSObjectProtocol?
    private let transportSession: ZMTransportSession
    private let coreDataStack: CoreDataStack
    private let operationLoop: RequestGeneratingOperationLoop
    private let strategyFactory: StrategyFactory

    public let accountIdentifier: UUID

    private var callEvent: ZMUpdateEvent?
    private var localNotifications = [ZMLocalNotification]()

    private var context: NSManagedObjectContext {
        return coreDataStack.syncContext
    }

    weak var delegate: NotificationSessionDelegate?

    // MARK: - Life cycle
        
    /// Initializes a new `SessionDirectory` to be used in an extension environment
    /// - parameter databaseDirectory: The `NSURL` of the shared group container
    /// - throws: `InitializationError.noAccount` in case the account does not exist
    /// - returns: The initialized session object if no error is thrown
    
    public convenience init(applicationGroupIdentifier: String,
                            accountIdentifier: UUID,
                            environment: BackendEnvironmentProvider,
                            analytics: AnalyticsType?,
                            delegate: NotificationSessionDelegate?,
                            useLegacyPushNotifications: Bool) throws {
       
        let sharedContainerURL = FileManager.sharedContainerDirectory(for: applicationGroupIdentifier)

        let accountManager = AccountManager(sharedDirectory: sharedContainerURL)
        guard let account = accountManager.account(with: accountIdentifier) else {
            throw InitializationError.noAccount
        }

        let coreDataStack = CoreDataStack(account: account,
                                          applicationContainer: sharedContainerURL)

        coreDataStack.loadStores { error in
            // TODO jacob error handling
        }

        let cookieStorage = ZMPersistentCookieStorage(forServerName: environment.backendURL.host!, userIdentifier: accountIdentifier)
        let reachabilityGroup = ZMSDispatchGroup(dispatchGroup: DispatchGroup(), label: "Sharing session reachability")!
        let serverNames = [environment.backendURL, environment.backendWSURL].compactMap { $0.host }
        let reachability = ZMReachability(serverNames: serverNames, group: reachabilityGroup)
        
        let transportSession =  ZMTransportSession(
            environment: environment,
            cookieStorage: cookieStorage,
            reachability: reachability,
            initialAccessToken: nil,
            applicationGroupIdentifier: applicationGroupIdentifier,
            applicationVersion: "1.0.0"
        )
        
        try self.init(
            coreDataStack: coreDataStack,
            transportSession: transportSession,
            cachesDirectory: FileManager.default.cachesURLForAccount(with: accountIdentifier, in: sharedContainerURL),
            accountContainer: CoreDataStack.accountDataFolder(accountIdentifier: accountIdentifier, applicationContainer: sharedContainerURL),
            analytics: analytics,
            useLegacyPushNotifications: useLegacyPushNotifications,
            accountIdentifier: accountIdentifier
        )
    }
    
    internal init(coreDataStack: CoreDataStack,
                  transportSession: ZMTransportSession,
                  cachesDirectory: URL,
                  saveNotificationPersistence: ContextDidSaveNotificationPersistence,
                  applicationStatusDirectory: ApplicationStatusDirectory,
                  operationLoop: RequestGeneratingOperationLoop,
                  strategyFactory: StrategyFactory,
                  accountIdentifier: UUID) throws {
        
        self.coreDataStack = coreDataStack
        self.transportSession = transportSession
        self.saveNotificationPersistence = saveNotificationPersistence
        self.applicationStatusDirectory = applicationStatusDirectory
        self.operationLoop = operationLoop
        self.strategyFactory = strategyFactory
        self.accountIdentifier = accountIdentifier
    }
    
    convenience init(coreDataStack: CoreDataStack,
                     transportSession: ZMTransportSession,
                     cachesDirectory: URL,
                     accountContainer: URL,
                     analytics: AnalyticsType?,
                     useLegacyPushNotifications: Bool,
                     accountIdentifier: UUID) throws {
        
        let applicationStatusDirectory = ApplicationStatusDirectory(syncContext: coreDataStack.syncContext,
                                                                    transportSession: transportSession)
        let notificationsTracker = (analytics != nil) ? NotificationsTracker(analytics: analytics!) : nil
        let strategyFactory = StrategyFactory(contextProvider: coreDataStack,
                                              applicationStatus: applicationStatusDirectory,
                                              pushNotificationStatus: applicationStatusDirectory.pushNotificationStatus,
                                              notificationsTracker: notificationsTracker,
                                              pushNotificationStrategyDelegate: nil,
                                              useLegacyPushNotifications: useLegacyPushNotifications)
        
        let requestGeneratorStore = RequestGeneratorStore(strategies: strategyFactory.strategies)
        
        let operationLoop = RequestGeneratingOperationLoop(
            userContext: coreDataStack.viewContext,
            syncContext: coreDataStack.syncContext,
            callBackQueue: .main,
            requestGeneratorStore: requestGeneratorStore,
            transportSession: transportSession
        )
        
        let saveNotificationPersistence = ContextDidSaveNotificationPersistence(accountContainer: accountContainer)
        
        try self.init(
            coreDataStack: coreDataStack,
            transportSession: transportSession,
            cachesDirectory: cachesDirectory,
            saveNotificationPersistence: saveNotificationPersistence,
            applicationStatusDirectory: applicationStatusDirectory,
            operationLoop: operationLoop,
            strategyFactory: strategyFactory,
            accountIdentifier: accountIdentifier
        )
    }

    deinit {
        if let token = contextSaveObserverToken {
            NotificationCenter.default.removeObserver(token)
            contextSaveObserverToken = nil
        }
        transportSession.reachability.tearDown()
        transportSession.tearDown()
        strategyFactory.tearDown()
    }
    
    public func processPushNotification(with payload: [AnyHashable: Any], completion: @escaping (Bool) -> Void) {
        Logging.network.debug("Received push notification with payload: \(payload)")

        coreDataStack.syncContext.performGroupedBlock {
            if self.applicationStatusDirectory.authenticationStatus.state == .unauthenticated {
                Logging.push.safePublic("Not displaying notification because app is not authenticated")
                completion(false)
                return
            }
            
            let completionHandler = {
                completion(true)
            }
            
            self.fetchEvents(fromPushChannelPayload: payload, completionHandler: completionHandler)
        }
    }
    
    func fetchEvents(fromPushChannelPayload payload: [AnyHashable : Any], completionHandler: @escaping () -> Void) {
        guard let nonce = self.messageNonce(fromPushChannelData: payload) else {
            return completionHandler()
        }
        self.applicationStatusDirectory.pushNotificationStatus.fetch(eventId: nonce, completionHandler: {
            completionHandler()
        })
    }

    private func messageNonce(fromPushChannelData payload: [AnyHashable : Any]) -> UUID? {
        guard let notificationData = payload[PushChannelKeys.data.rawValue] as? [AnyHashable : Any],
            let data = notificationData[PushChannelKeys.data.rawValue] as? [AnyHashable : Any],
            let rawUUID = data[PushChannelKeys.identifier.rawValue] as? String else {
                return nil
        }
        return UUID(uuidString: rawUUID)
    }
    
    private enum PushChannelKeys: String {
        case data = "data"
        case identifier = "id"
    }
}

extension NotificationSession: PushNotificationStrategyDelegate {

    func pushNotificationStrategy(_ strategy: PushNotificationStrategy, didFetchEvents events: [ZMUpdateEvent]) {
        for event in events {
            // TODO: only store call event if CallKit is actually enabled by the user.
            // The notification service can only report call events from iOS 14.5. Otherwise,
            // we should continue to generate a call local notification, even if CallKit is enabled.
            if #available(iOSApplicationExtension 14.5, *), event.isCallEvent {
                // Only store the last call event.
                callEvent =  event
            } else if let notification = notification(from: event, in: context) {
                localNotifications.append(notification)
            }
        }
    }

    func pushNotificationStrategyDidFinishFetchingEvents(_ strategy: PushNotificationStrategy) {
        processCallEvent()

        // We should only process local notifications once after we've finished fetching
        // all events because otherwise we tell the delegate (i.e the notification
        // service extension) to use its content handler more than once, which may lead
        // to unexpected behavior.
        processLocalNotifications()
        localNotifications.removeAll()
    }

    private func processCallEvent() {
        if let callEvent = callEvent {
            delegate?.reportCallEvent(callEvent, currentTimestamp: context.serverTimeDelta)
            self.callEvent = nil
        }
    }

    private func processLocalNotifications() {
        let notification: ZMLocalNotification?

        if localNotifications.count > 1 {
            notification = ZMLocalNotification.bundledMessages(count: localNotifications.count, in: context)
        } else {
            notification = localNotifications.first
        }
        let unreadCount = Int(ZMConversation.unreadConversationCount(in: context))
        delegate?.notificationSessionDidGenerateNotification(notification, unreadConversationCount: unreadCount)
    }

}

// MARK: - Converting events to localNotifications

extension NotificationSession {

    private func convertToLocalNotifications(_ events: [ZMUpdateEvent], moc: NSManagedObjectContext) -> [ZMLocalNotification] {
        return events.compactMap { event in
            return notification(from: event, in: moc)
        }
    }

    private func notification(from event: ZMUpdateEvent, in context: NSManagedObjectContext) -> ZMLocalNotification? {
        var note: ZMLocalNotification?
        guard let conversationID = event.conversationUUID else {
            return nil
        }

        let conversation = ZMConversation.fetch(with: conversationID, in: context)

        if let callEventContent = CallEventContent(from: event) {
            let currentTimestamp = Date().addingTimeInterval(context.serverTimeDelta)

            /// The caller should not be the same as the user receiving the call event and
            /// the age of the event is less than 30 seconds
            guard let callState = callEventContent.callState,
                  let callerID = callEventContent.callerID,
                  let caller = ZMUser.fetch(with: callerID, domain: event.senderDomain, in: context),
                  caller != ZMUser.selfUser(in: context),
                  !isEventTimedOut(currentTimestamp: currentTimestamp, eventTimestamp: event.timestamp) else {
                      return nil
                  }
            note = ZMLocalNotification.init(callState: callState, conversation: conversation, caller: caller, moc: context)
        } else {
            note = ZMLocalNotification.init(event: event, conversation: conversation, managedObjectContext: context)
        }

        note?.increaseEstimatedUnreadCount(on: conversation)
        return note
    }

    private func isEventTimedOut(currentTimestamp: Date, eventTimestamp: Date?) -> Bool {
        guard let eventTimestamp = eventTimestamp else {
            return true
        }

        return Int(currentTimestamp.timeIntervalSince(eventTimestamp)) > 30
    }

}


// MARK: - Helpers

private extension CallEventContent {

    init?(from event: ZMUpdateEvent) {
        guard
            event.type == .conversationOtrMessageAdd,
            let message = GenericMessage(from: event),
            message.hasCalling,
            let payload = message.calling.content.data(using: .utf8, allowLossyConversion: false)
        else {
            return nil
        }

        self.init(from: payload)
    }

}

// MARK: - Helper

private extension ZMUpdateEvent {

    var isCallEvent: Bool {
        return CallEventContent(from: self) != nil
    }

    var isIncomingCallEvent: Bool {
        guard
            let content = CallEventContent(from: self),
            case .incomingCall = content.callState
        else {
            return false
        }

        return true
    }

    var isMissedCallEvent: Bool {
        guard
            let content = CallEventContent(from: self),
            case .missedCall = content.callState
        else {
            return false
        }

        return true
    }

}
