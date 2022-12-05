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
import WireRequestStrategy
import OSLog

struct WireLogger {

    private var logger: Any?
    private var infoBlock: ((String) -> Void)?

    init(category: String) {
        if #available(iOS 14, *) {
            let logger = Logger(subsystem: "VoIP Push", category: category)
            infoBlock = { message in
                logger.info("\(message, privacy: .public)")
            }
            self.logger = logger
        }
    }

    func info(_ message: String) {
        infoBlock?(message)
    }

}

let logger = WireLogger(category: "Notification Engine")

public enum NotificationSessionError: Error {

    case accountNotAuthenticated
    case noEventID
    case invalidEventID
    case alreadyFetchedEvent
    case unknown

}

public protocol NotificationSessionDelegate: AnyObject {

    func notificationSessionDidFailWithError(error: NotificationSessionError)

    func notificationSessionDidGenerateNotification(
        _ notification: ZMLocalNotification?,
        unreadConversationCount: Int
    )

    func reportCallEvent(
        _ event: ZMUpdateEvent,
        currentTimestamp: TimeInterval,
        callerName: String
    )

}

/// A syncing layer for the notification processing
/// - note: this is the entry point of this framework. Users of
/// the framework should create an instance as soon as possible in
/// the lifetime of the notification extension, and hold on to that session
/// for the entire lifetime.
///
public class NotificationSession {

    /// The failure reason of a `NotificationSession` initialization
    /// - noAccount: Account doesn't exist

    public enum InitializationError: Error {
        case noAccount
    }

    // MARK: - Properties

    /// Directory of all application statuses.

    private let applicationStatusDirectory : ApplicationStatusDirectory

    /// The list to which save notifications of the UI moc are appended and persisted.

    private let saveNotificationPersistence: ContextDidSaveNotificationPersistence

    private var contextSaveObserverToken: NSObjectProtocol?
    private let transportSession: ZMTransportSession
    private let coreDataStack: CoreDataStack
    private let operationLoop: RequestGeneratingOperationLoop

    public let accountIdentifier: UUID

    private var callEvent: ZMUpdateEvent?
    private var localNotifications = [ZMLocalNotification]()

    private var context: NSManagedObjectContext {
        return coreDataStack.syncContext
    }

    public weak var delegate: NotificationSessionDelegate?

    // MARK: - Life cycle
        
    /// Initializes a new `SessionDirectory` to be used in an extension environment
    /// - parameter databaseDirectory: The `NSURL` of the shared group container
    /// - throws: `InitializationError.noAccount` in case the account does not exist
    /// - returns: The initialized session object if no error is thrown
    
    public convenience init(
        applicationGroupIdentifier: String,
        accountIdentifier: UUID,
        environment: BackendEnvironmentProvider,
        analytics: AnalyticsType?
    ) throws {
        let sharedContainerURL = FileManager.sharedContainerDirectory(for: applicationGroupIdentifier)
        let accountManager = AccountManager(sharedDirectory: sharedContainerURL)

        guard let account = accountManager.account(with: accountIdentifier) else {
            throw InitializationError.noAccount
        }

        let coreDataStack = CoreDataStack(
            account: account,
            applicationContainer: sharedContainerURL
        )

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
            accountIdentifier: accountIdentifier
        )
    }

    convenience init(
        coreDataStack: CoreDataStack,
        transportSession: ZMTransportSession,
        cachesDirectory: URL,
        accountContainer: URL,
        analytics: AnalyticsType?,
        accountIdentifier: UUID
    ) throws {
        let applicationStatusDirectory = ApplicationStatusDirectory(
            syncContext: coreDataStack.syncContext,
            transportSession: transportSession
        )

        let notificationsTracker = (analytics != nil) ? NotificationsTracker(analytics: analytics!) : nil

        let pushNotificationStrategy = PushNotificationStrategy(
            withManagedObjectContext: coreDataStack.syncContext,
            eventContext: coreDataStack.eventContext,
            applicationStatus: applicationStatusDirectory,
            pushNotificationStatus: applicationStatusDirectory.pushNotificationStatus,
            notificationsTracker: notificationsTracker
        )

        let requestGeneratorStore = RequestGeneratorStore(strategies: [pushNotificationStrategy])
        
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
            accountIdentifier: accountIdentifier,
            pushNotificationStrategy: pushNotificationStrategy
        )
    }

    init(
        coreDataStack: CoreDataStack,
        transportSession: ZMTransportSession,
        cachesDirectory: URL,
        saveNotificationPersistence: ContextDidSaveNotificationPersistence,
        applicationStatusDirectory: ApplicationStatusDirectory,
        operationLoop: RequestGeneratingOperationLoop,
        accountIdentifier: UUID,
        pushNotificationStrategy: PushNotificationStrategy
    ) throws {
        self.coreDataStack = coreDataStack
        self.transportSession = transportSession
        self.saveNotificationPersistence = saveNotificationPersistence
        self.applicationStatusDirectory = applicationStatusDirectory
        self.operationLoop = operationLoop
        self.accountIdentifier = accountIdentifier
        pushNotificationStrategy.delegate = self
    }

    deinit {
        if let token = contextSaveObserverToken {
            NotificationCenter.default.removeObserver(token)
            contextSaveObserverToken = nil
        }

        transportSession.reachability.tearDown()
        transportSession.tearDown()
    }

    // MARK: - Methods
    
    public func processPushNotification(with payload: [AnyHashable: Any]) {
        Logging.network.debug("Received push notification with payload: \(payload)")

        coreDataStack.syncContext.performGroupedBlock {
            if self.applicationStatusDirectory.authenticationStatus.state == .unauthenticated {
                Logging.push.safePublic("Not displaying notification because app is not authenticated")
                self.delegate?.notificationSessionDidFailWithError(error: .accountNotAuthenticated)
                return
            }

            self.fetchEvents(fromPushChannelPayload: payload)
        }
    }
    
    func fetchEvents(fromPushChannelPayload payload: [AnyHashable: Any]) {
        guard let nonce = self.messageNonce(fromPushChannelData: payload) else {
            delegate?.notificationSessionDidFailWithError(error: .noEventID)
            return
        }

        applicationStatusDirectory.pushNotificationStatus.fetch(eventId: nonce) { result in
            switch result {
            case .success:
                break

            case .failure(.alreadyFetchedEvent):
                self.delegate?.notificationSessionDidFailWithError(error: .alreadyFetchedEvent)

            case .failure(.invalidEventID):
                self.delegate?.notificationSessionDidFailWithError(error: .invalidEventID)

            case .failure(.unknown):
                self.delegate?.notificationSessionDidFailWithError(error: .unknown)
            }
        }
    }

    private func messageNonce(fromPushChannelData payload: [AnyHashable: Any]) -> UUID? {
        guard
            let notificationData = payload[PushChannelKeys.data.rawValue] as? [AnyHashable: Any],
            let data = notificationData[PushChannelKeys.data.rawValue] as? [AnyHashable: Any],
            let rawUUID = data[PushChannelKeys.identifier.rawValue] as? String
        else {
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
            if shouldHandleCallEvent(event) {
                // Only store the last call event.
                callEvent =  event
            } else if let notification = notification(from: event, in: context) {
                localNotifications.append(notification)
            }
        }
    }

    private func shouldHandleCallEvent(_ event: ZMUpdateEvent) -> Bool {
        // The API to report VoIP pushes from the notification service extension
        // is only available from iOS 14.5.
        guard #available(iOSApplicationExtension 14.5, *) else {
            return false
        }

        // Ensure this actually is a call event.
        guard let callContent = CallEventContent(from: event) else {
            return false
        }

        logger.info("did receive call event: \(callContent)")

        guard let callerID = event.senderUUID else {
            logger.info("should not handle call event: senderUUID missing from event")
            return false
        }

        guard ZMUser.fetch(with: callerID, domain: event.senderDomain, in: context) != nil else {
            logger.info("should not handle call event: caller not in db")
            return false
        }

        guard let conversationID = event.conversationUUID else {
            logger.info("should not handle call event: conversationUUID missing from event")
            return false
        }

        guard let conversation = ZMConversation.fetch(
            with: conversationID,
            domain: event.conversationDomain,
            in: context
        ) else {
            logger.info("should not handle call event: conversation not in db")
            return false
        }

        guard !conversation.needsToBeUpdatedFromBackend else {
            logger.info("should not handle call event: conversation not synced")
            return false
        }

        if conversation.mutedMessageTypesIncludingAvailability != .none {
            logger.info("should not handle call event: conversation is muted or user is not available")
            return false
        }

        guard VoIPPushHelper.isAVSReady else {
            logger.info("should not handle call event: AVS is not ready")
            return false
        }

        guard VoIPPushHelper.isCallKitAvailable else {
            logger.info("should not handle call event: CallKit is not available")
            return false
        }

        guard VoIPPushHelper.isUserSessionLoaded(accountID: accountIdentifier) else {
            logger.info("should not handle call event: user session is not loaded")
            return false
        }

        let handle = "\(accountIdentifier.transportString())+\(conversationID.transportString())"
        let wasCallHandleReported = VoIPPushHelper.knownCallHandles.contains(handle)

        // Should not handle a call if the caller is a self user and it's an incoming call or call end.
        // The caller can be the same as the self user if it's a rejected call or answered elsewhere.
        if
            let selfUserID = selfUserID(in: conversation.managedObjectContext),
            let callerID = callContent.callerID,
            callerID == selfUserID,
            (callContent.isIncomingCall || callContent.isEndCall)
        {
            logger.info("should not handle call event: self call")
            return false
        }

        if callContent.initiatesRinging, !wasCallHandleReported {
            logger.info("should initiate ringing")
            return true
        } else if callContent.terminatesRinging, wasCallHandleReported {
            logger.info("should terminate ringing")
            return true
        } else {
            logger.info("should not handle call event: nothing to report")
            return false
        }
    }

    private func selfUserID(in managedObjectContext: NSManagedObjectContext?) -> UUID? {
        guard let moc = managedObjectContext else {
            return nil
        }
        return ZMUser.selfUser(in: moc).remoteIdentifier
    }

    private func conversation(in event: ZMUpdateEvent) -> ZMConversation? {
        guard
            let id = event.conversationUUID,
            let conversation = ZMConversation.fetch(with: id, domain: event.conversationDomain, in: context),
            !conversation.needsToBeUpdatedFromBackend
        else {
            return nil
        }

        return conversation
    }

    private func caller(in callEvent: ZMUpdateEvent) -> ZMUser? {
        guard let callContent = CallEventContent(from: callEvent),
              let callerID = callContent.callerID,
              let user = ZMUser.fetch(with: callerID, in: context) else {
                  return nil
              }

        return user
    }

    private func callerName(in callEvent: ZMUpdateEvent) -> String {
        guard let conversation = conversation(in: callEvent),
              let user = caller(in: callEvent) else {
                  return "someone"
              }

        return conversation.localizedCallerName(with: user)
    }

    func pushNotificationStrategyDidFinishFetchingEvents(_ strategy: PushNotificationStrategy) {
        processCallEvent()
        processLocalNotifications()
    }

    private func processCallEvent() {
        if let callEvent = callEvent {
            delegate?.reportCallEvent(callEvent, currentTimestamp: context.serverTimeDelta, callerName: callerName(in: callEvent))
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
        localNotifications.removeAll()
    }

}

// MARK: - Converting events to localNotifications

extension NotificationSession {

    private func notification(from event: ZMUpdateEvent, in context: NSManagedObjectContext) -> ZMLocalNotification? {
        var note: ZMLocalNotification?

        guard let conversationID = event.conversationUUID else {
            return nil
        }

        let conversation = ZMConversation.fetch(with: conversationID, domain: event.conversationDomain, in: context)

        if let callEventContent = CallEventContent(from: event) {
            let currentTimestamp = Date().addingTimeInterval(context.serverTimeDelta)

            /// The caller should not be the same as the user receiving the call event and
            /// the age of the event is less than 30 seconds
            guard
                let callState = callEventContent.callState,
                let callerID = callEventContent.callerID,
                let caller = ZMUser.fetch(with: callerID, domain: event.senderDomain, in: context),
                caller != ZMUser.selfUser(in: context),
                !isEventTimedOut(currentTimestamp: currentTimestamp, eventTimestamp: event.timestamp)
            else {
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
