//
//  NotificationSessionTests.swift
//  WireNotificationEngineTests
//
//  Created by Marcin Ratajczak on 07/06/2022.
//  Copyright © 2022 Wire. All rights reserved.
//

import XCTest
import WireTesting
import WireDataModel
@testable import WireNotificationEngine

class FakeAuthenticationStatus: AuthenticationStatusProvider {
    var state: AuthenticationState = .authenticated
}


class NotificationSessionTests: NotificationStrategyTestBase {

    var notificationSession: NotificationSession!
    var eventsFetcher: EventsFetcherMock!

    override func setUp() {
        super.setUp()

        eventsFetcher = EventsFetcherMock()
        let operationLoop = RequestGeneratingOperationLoop(
            userContext: coreDataStack.viewContext,
            syncContext: coreDataStack.syncContext,
            callBackQueue: .main,
            requestGeneratorStore: RequestGeneratorStore(strategies: [pushNotificationStrategy]),
            transportSession: transportSession
        )
        let sharedContainerURL = FileManager.sharedContainerDirectory(for:  "123")
        let accountContainer =  CoreDataStack.accountDataFolder(accountIdentifier: accountIdentifier, applicationContainer: sharedContainerURL)
        let saveNotificationPersistence = ContextDidSaveNotificationPersistence(accountContainer: accountContainer)


        do {
            notificationSession = try NotificationSession(coreDataStack: coreDataStack,
                                                          transportSession: transportSession,
                                                          cachesDirectory: coreDataStack.applicationContainer,
                                                          saveNotificationPersistence: saveNotificationPersistence,
                                                          applicationStatusDirectory: applicationStatusDirectory,
                                                          operationLoop: operationLoop,
                                                          accountIdentifier: accountIdentifier,
                                                          pushNotificationStrategy: pushNotificationStrategy,
                                                          eventsFetcher: eventsFetcher)
        } catch {
            XCTFail()
        }
    }

    func testThatFetchCorrectEvent() { // WireShareEngine
        // given
        let notification = ["data": ["data": ["id" : "123e4567-e89b-12d3-a456-426614174000"]]]
        // when
        notificationSession.processPushNotification(with: notification) { [weak self] _ in
            // then
            XCTAssertEqual(self?.eventsFetcher.fetchedEventID, UUID(uuidString: "123e4567-e89b-12d3-a456-426614174000"))
        }
    }

    func testAbortFetchingEventWhenNotUnAuthenticated() {
        // given
        let notification = ["data": ["data": ["id" : "123e4567-e89b-12d3-a456-426614174000"]]]
        authenticationStatus.state = .unauthenticated
        // when
        notificationSession.processPushNotification(with: notification) { result in
            // then
            XCTAssertFalse(result)
        }
    }

}

class EventsFetcherMock: EventsFetcher {
    private(set) var fetchedEventID: UUID?

    func fetchEventWithId(eventId: UUID, completionHandler: @escaping () -> Void) {
        fetchedEventID = eventId
        completionHandler()
    }
}

