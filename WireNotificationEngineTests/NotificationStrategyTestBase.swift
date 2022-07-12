//
//  NotificationStrategyTestBase.swift
//  WireNotificationEngineTests
//
//  Created by Marcin Ratajczak on 12/07/2022.
//  Copyright © 2022 Wire. All rights reserved.
//

import XCTest
import WireTesting
import WireDataModel
import WireMockTransport
@testable import WireNotificationEngine

class NotificationStrategyTestBase: XCTestCase {

    var authenticationStatus: FakeAuthenticationStatus!
    var accountIdentifier: UUID!
    var pushNotificationStrategy: PushNotificationStrategy!
    var syncContext: NSManagedObjectContext!
    var coreDataStack: CoreDataStack!
    var applicationStatusDirectory: ApplicationStatusDirectory!
    var transportSession: ZMTransportSession!



    override func setUp() {
        super.setUp()

        accountIdentifier = UUID(uuidString: "123e4567-e89b-12d3-a456-426614174001")!
        authenticationStatus = FakeAuthenticationStatus()
        let url = try! FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let account = Account(userName: "", userIdentifier:accountIdentifier)

        coreDataStack = CoreDataStack(account: account,
                                      applicationContainer: url)

        coreDataStack.loadStores { error in
            XCTAssertNil(error)
        }
        let mockTransport = MockTransportSession(dispatchGroup: nil)
        transportSession = mockTransport.mockedTransportSession()
        syncContext = coreDataStack.syncContext

        let registrationStatus = ClientRegistrationStatus(context: coreDataStack.syncContext)

        applicationStatusDirectory = ApplicationStatusDirectory(
            managedObjectContext: coreDataStack.syncContext,
            transportSession: transportSession,
            authenticationStatus: authenticationStatus,
            clientRegistrationStatus: registrationStatus,
            linkPreviewDetector: LinkPreviewDetector()
        )

        pushNotificationStrategy = PushNotificationStrategy(
            withManagedObjectContext: coreDataStack.syncContext,
            eventContext: coreDataStack.eventContext,
            applicationStatus: applicationStatusDirectory,
            pushNotificationStatus: applicationStatusDirectory.pushNotificationStatus,
            notificationsTracker: nil
        )
    }
}
