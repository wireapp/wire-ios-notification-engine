//
// Wire
// Copyright (C) 2022 Wire Swiss GmbH
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

import WireRequestStrategy
import Foundation

public protocol NotificationSessionDelegate: AnyObject {
    func notificationSessionDidGenerateNotification(_ notification: ZMLocalNotification?, unreadConversationCount: Int)
    func reportCallEvent(_ event: ZMUpdateEvent, currentTimestamp: TimeInterval)
}

final class PushNotificationStrategy: AbstractRequestStrategy, ZMRequestGeneratorSource, UpdateEventProcessor {

    // MARK: - Properties
    
    var sync: NotificationStreamSync!
    private var pushNotificationStatus: PushNotificationStatus!
    private var eventProcessor: UpdateEventProcessor!
    private var moc: NSManagedObjectContext!

    private var callEvent: ZMUpdateEvent?
    private var localNotifications = [ZMLocalNotification]()

    private weak var delegate: NotificationSessionDelegate?

    private let useLegacyPushNotifications: Bool
    
    var eventDecoder: EventDecoder!
    var eventMOC: NSManagedObjectContext!

    // MARK: - Life cycle

    init(withManagedObjectContext managedObjectContext: NSManagedObjectContext,
         eventContext: NSManagedObjectContext,
         applicationStatus: ApplicationStatus,
         pushNotificationStatus: PushNotificationStatus,
         notificationsTracker: NotificationsTracker?,
         notificationSessionDelegate: NotificationSessionDelegate?,
         useLegacyPushNotifications: Bool) {

        self.useLegacyPushNotifications = useLegacyPushNotifications
        
        super.init(withManagedObjectContext: managedObjectContext,
                   applicationStatus: applicationStatus)
       
        sync = NotificationStreamSync(moc: managedObjectContext,
                                      notificationsTracker: notificationsTracker,
                                      delegate: self)
        self.eventProcessor = self
        self.pushNotificationStatus = pushNotificationStatus
        self.delegate = notificationSessionDelegate
        self.moc = managedObjectContext
        self.eventDecoder = EventDecoder(eventMOC: eventContext, syncMOC: managedObjectContext)
    }

    // MARK: - Methods
    
    public override func nextRequestIfAllowed(for apiVersion: APIVersion) -> ZMTransportRequest? {
        return isFetchingStreamForAPNS && !useLegacyPushNotifications ? requestGenerators.nextRequest(for: apiVersion) : nil
    }
    
    public override func nextRequest(for apiVersion: APIVersion) -> ZMTransportRequest? {
        return isFetchingStreamForAPNS && !useLegacyPushNotifications ? requestGenerators.nextRequest(for: apiVersion) : nil
    }
    
    public var requestGenerators: [ZMRequestGenerator] {
           return [sync]
       }
    
    public var isFetchingStreamForAPNS: Bool {
        return self.pushNotificationStatus.hasEventsToFetch
    }

    func processEventsIfReady() -> Bool {
        return true
    }

    var eventConsumers: [ZMEventConsumer] {
        get {
            return []
        }
        set(newValue) {
        }
    }

    @objc public func storeUpdateEvents(_ updateEvents: [ZMUpdateEvent], ignoreBuffer: Bool) {
        eventDecoder.decryptAndStoreEvents(updateEvents) { decryptedUpdateEvents in
            self.processEventsWhileInBackground(decryptedUpdateEvents)
        }
    }

    @objc public func storeAndProcessUpdateEvents(_ updateEvents: [ZMUpdateEvent], ignoreBuffer: Bool) {
        // Events will be processed in the foreground
    }

}

// MARK: - Notification stream sync delegate

extension PushNotificationStrategy: NotificationStreamSyncDelegate {

    public func fetchedEvents(_ events: [ZMUpdateEvent], hasMoreToFetch: Bool) {
        var eventIds: [UUID] = []
        var parsedEvents: [ZMUpdateEvent] = []
        var latestEventId: UUID? = nil

        for event in events {
            event.appendDebugInformation("From missing update events transcoder, processUpdateEventsAndReturnLastNotificationIDFromPayload")
            parsedEvents.append(event)

            if let uuid = event.uuid {
                eventIds.append(uuid)
            }

            if !event.isTransient {
                latestEventId = event.uuid
            }
        }

        eventProcessor.storeUpdateEvents(parsedEvents, ignoreBuffer: true)
        pushNotificationStatus.didFetch(eventIds: eventIds, lastEventId: latestEventId, finished: !hasMoreToFetch)

        if !hasMoreToFetch {
            processCallEvent()

            // We should only process local notifications once after we've finished fetching
            // all events because otherwise we tell the delegate (i.e the notification
            // service extension) to use its content handler more than once, which may lead
            // to unexpected behavior.
            processLocalNotifications()
            localNotifications.removeAll()
        }
    }
    
    public func failedFetchingEvents() {
        pushNotificationStatus.didFailToFetchEvents()
    }
}

extension PushNotificationStrategy {

    private func processEventsWhileInBackground(_ events: [ZMUpdateEvent]) {
        for event in events {
            // TODO: only store call event if CallKit is actually enabled by the user.
            // The notification service can only report call events from iOS 14.5. Otherwise,
            // we should continue to generate a call local notification, even if CallKit is enabled.
            if #available(iOSApplicationExtension 14.5, *), event.isCallEvent {
                // Only store the last call event.
                callEvent =  event
            } else if let notification = notification(from: event, in: moc) {
                localNotifications.append(notification)
            }
        }
    }

    private func processCallEvent() {
        if let callEvent = callEvent {
            delegate?.reportCallEvent(callEvent, currentTimestamp: managedObjectContext.serverTimeDelta)
            self.callEvent = nil
        }
    }

    private func processLocalNotifications() {
        let notification: ZMLocalNotification?

        if localNotifications.count > 1 {
            notification = ZMLocalNotification.bundledMessages(count: localNotifications.count, in: moc)
        } else {
            notification = localNotifications.first
        }
        let unreadCount = Int(ZMConversation.unreadConversationCount(in: moc))
        delegate?.notificationSessionDidGenerateNotification(notification, unreadConversationCount: unreadCount)
    }

}

// MARK: - Converting events to localNotifications

extension PushNotificationStrategy {

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
            let currentTimestamp = Date().addingTimeInterval(managedObjectContext.serverTimeDelta)

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
            case .incoming = content.callState
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
