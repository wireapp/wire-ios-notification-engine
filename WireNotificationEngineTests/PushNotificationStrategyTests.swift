//
//  PushNotificationStrategyTests.swift
//  WireNotificationEngineTests
//
//  Created by Marcin Ratajczak on 07/06/2022.
//  Copyright © 2022 Wire. All rights reserved.
//

import XCTest
import WireTesting
@testable import WireNotificationEngine


import WireRequestStrategy

class PushNotificationStrategyTests: NotificationStrategyTestBase {

    override func setUp() {
        super.setUp()

        coreDataStack.syncContext.performGroupedBlockAndWait {
            let selfUser = ZMUser.selfUser(in: self.coreDataStack.syncContext)
            selfUser.remoteIdentifier = self.accountIdentifier
            let selfConversation = ZMConversation.insertNewObject(in: self.coreDataStack.syncContext)
            selfConversation.remoteIdentifier = self.accountIdentifier
            selfConversation.conversationType = .self
        }
    }

    func testStoreUpdateEventsCallsDelegate() {
        let notificationStrategyDelegate = NotificationStrategyDelegateMock()
        pushNotificationStrategy.delegate = notificationStrategyDelegate
        let uuid = UUID()
        let event = eventStreamEvent(uuid: uuid)
        pushNotificationStrategy.storeUpdateEvents([event], ignoreBuffer: true)
        XCTAssertEqual(notificationStrategyDelegate.fetchedEvents?.count, 1)
        XCTAssertEqual(notificationStrategyDelegate.fetchedEvents?.first?.uuid, uuid)
    }

    func testFetchEventsCallsDelegate() {
        let notificationStrategyDelegate = NotificationStrategyDelegateMock()
        pushNotificationStrategy.delegate = notificationStrategyDelegate
        let uuid = UUID()
        let events = [eventStreamEvent(uuid: uuid)]
        pushNotificationStrategy.fetchedEvents(events, hasMoreToFetch: false)
        XCTAssertTrue(notificationStrategyDelegate.didFinishFetchingEvents)
    }


}

extension PushNotificationStrategyTests {

    func eventStreamEvent(uuid: UUID? = nil) -> ZMUpdateEvent {
        let conversation = ZMConversation.insertNewObject(in: syncContext)
        let user = ZMUser.insertNewObject(in: conversation.managedObjectContext!)
        user.remoteIdentifier = UUID.create()
        let payload = ["conversation": conversation.remoteIdentifier?.transportString() ?? "",
                       "data": ["foo": "bar"],
                       "from": user.remoteIdentifier.transportString(),
                       "time": "",
                       "type": "conversation.message-add"
        ] as ZMTransportData
        return ZMUpdateEvent(fromEventStreamPayload: payload, uuid: uuid ?? UUID.create())!
    }
}

class NotificationStrategyDelegateMock: PushNotificationStrategyDelegate {
    var fetchedEvents: [ZMUpdateEvent]? = nil
    var didFinishFetchingEvents = false

    func pushNotificationStrategy(_ strategy: PushNotificationStrategy, didFetchEvents events: [ZMUpdateEvent]) {
        fetchedEvents = events
    }

    func pushNotificationStrategyDidFinishFetchingEvents(_ strategy: PushNotificationStrategy) {
        didFinishFetchingEvents = true
    }


}
