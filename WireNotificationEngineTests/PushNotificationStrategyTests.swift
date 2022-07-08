////
////  PushNotificationStrategyTests.swift
////  WireNotificationEngineTests
////
////  Created by Marcin Ratajczak on 07/06/2022.
////  Copyright © 2022 Wire. All rights reserved.
////
//
//import XCTest
//import WireDataModel
//import WireTesting
//import WireMockTransport
//@testable import WireNotificationEngine
//
//class PushNotificationStrategyTests: XCTestCase {
//
//    var authenticationStatus: FakeAuthenticationStatus!
//    var accountIdentifier: UUID!
//    var notificationSession: NotificationSession!
//    var eventsFetcher: EventsFetcherMock!
//
//    override func setUp() {
//        super.setUp()
//
//        eventsFetcher = EventsFetcherMock()
//        accountIdentifier = UUID(uuidString: "123e4567-e89b-12d3-a456-426614174001")!
//        authenticationStatus = FakeAuthenticationStatus()
//        let url = try! FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
//        //        let account = Account(userName: "", userIdentifier: accountIdentifier)
//
//        let account = Account(userName: "Additional Account", userIdentifier: UUID(uuidString: "123e4567-e89b-12d3-a456-426614174001")!)
//        let sharedContainerURL = FileManager.sharedContainerDirectory(for:  "123")
//        let accountManager = AccountManager(sharedDirectory: sharedContainerURL)
//        accountManager.addOrUpdate(account)
//
//        let coreDataStack: CoreDataStack = CoreDataStack(account: account,
//                                                         applicationContainer: url,
//                                                         inMemoryStore: true,
//                                                         dispatchGroup: nil)
//        let mockTransport = MockTransportSession(dispatchGroup: nil)
//        let transportSession = mockTransport.mockedTransportSession()
//
//        let registrationStatus = ClientRegistrationStatus(context: coreDataStack.syncContext)
//
//        let applicationStatusDirectory = ApplicationStatusDirectory(
//            managedObjectContext: coreDataStack.syncContext,
//            transportSession: transportSession,
//            authenticationStatus: authenticationStatus,
//            clientRegistrationStatus: registrationStatus,
//            linkPreviewDetector: LinkPreviewDetector()
//        )
//
//        let pushNotificationStrategy = PushNotificationStrategy(
//            withManagedObjectContext: coreDataStack.syncContext,
//            eventContext: coreDataStack.eventContext,
//            applicationStatus: applicationStatusDirectory,
//            pushNotificationStatus: applicationStatusDirectory.pushNotificationStatus,
//            notificationsTracker: nil
//        )
//        let operationLoop = RequestGeneratingOperationLoop(
//            userContext: coreDataStack.viewContext,
//            syncContext: coreDataStack.syncContext,
//            callBackQueue: .main,
//            requestGeneratorStore: RequestGeneratorStore(strategies: [pushNotificationStrategy]),
//            transportSession: transportSession
//        )
//        let accountContainer =  CoreDataStack.accountDataFolder(accountIdentifier: accountIdentifier, applicationContainer: sharedContainerURL)
//        let saveNotificationPersistence = ContextDidSaveNotificationPersistence(accountContainer: accountContainer)
//
//
//        do {
//            notificationSession = try NotificationSession(coreDataStack: coreDataStack,
//                                                          transportSession: transportSession,
//                                                          cachesDirectory: url,
//                                                          saveNotificationPersistence: saveNotificationPersistence,
//                                                          applicationStatusDirectory: applicationStatusDirectory,
//                                                          operationLoop: operationLoop,
//                                                          accountIdentifier: accountIdentifier,
//                                                          pushNotificationStrategy: pushNotificationStrategy,
//                                                          eventsFetcher: eventsFetcher)
//        } catch {
//            XCTFail()
//        }
//    }
//
////    func test
//}
