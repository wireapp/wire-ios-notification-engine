//
//  NotificationSessionTests.swift
//  WireNotificationEngineTests
//
//  Created by Marcin Ratajczak on 07/06/2022.
//  Copyright © 2022 Wire. All rights reserved.
//

import XCTest
import WireTransport
import WireDataModel
@testable import WireNotificationEngine

class NotificationSessionTests: XCTestCase {

    func addAccount() {
        let additionalAccount = Account(userName: "Additional Account", userIdentifier: UUID(uuidString: "123e4567-e89b-12d3-a456-426614174001")!)
        let sharedContainerURL = FileManager.sharedContainerDirectory(for:  "123")
        let accountManager = AccountManager(sharedDirectory: sharedContainerURL)
        accountManager.addOrUpdate(additionalAccount)
    }

    func notificationSession(eventsFetcher: EventsFetcher)  throws  -> NotificationSession{
        return try NotificationSession.init(applicationGroupIdentifier: "123",
                                        accountIdentifier: UUID(uuidString: "123e4567-e89b-12d3-a456-426614174001")!,
                                        environment: MockEnvironment(),
                                        analytics: nil,
                                        eventsFetcher: eventsFetcher)
    }

    func testThatFetchCorrectEvent() { // WireShareEngine 
        // given
        addAccount()
        let eventsFetcher = EventsFetcherMock()
        let notification = ["data": ["data": ["id" : "123e4567-e89b-12d3-a456-426614174000"]]]
        // when
        do {
            let session = try notificationSession(eventsFetcher: eventsFetcher)
            session.processPushNotification(with: notification) { _ in }
        } catch {
            XCTFail()
        }
        // then
        XCTAssertEqual(eventsFetcher.fetchedEventID, UUID(uuidString: "123e4567-e89b-12d3-a456-426614174000"))
    }

    func testAbortFetchingEventWhenNotUnAuthenticated() {
        // given
        addAccount()
        let eventsFetcher = EventsFetcherMock()
        let notification = ["data": ["data": ["id" : "123e4567-e89b-12d3-a456-426614174000"]]]
        // when
        do {
            let session = try notificationSession(eventsFetcher: eventsFetcher)
            session.processPushNotification(with: notification) { result in
                // then
                XCTAssertTrue(false)
            }
        } catch {
            XCTFail()
        }
    }
}

class EventsFetcherMock: EventsFetcher {
    private(set) var fetchedEventID: UUID?

    func fetchEventWithId(eventId: UUID, completionHandler: @escaping () -> Void) {
        fetchedEventID = eventId
    }
}
