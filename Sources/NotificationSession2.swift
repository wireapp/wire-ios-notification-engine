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

import Foundation
import WireRequestStrategy

public final class NotificationSession2: NotificationSessionProtocol {

    // MARK: - Properties

    public weak var delegate: NotificationSessionDelegate?

    private let coreDataStack: CoreDataStack
    private let transportSession: ZMTransportSession

    // MARK: - Life cycle

    public init(
        accountID: UUID,
        appGroupID: String,
        environment: BackendEnvironmentProvider
    ) throws {
        let sharedContainerURL = FileManager.sharedContainerDirectory(for: appGroupID)
        let accountManager = AccountManager(sharedDirectory: sharedContainerURL)

        guard let account = accountManager.account(with: accountID) else {
            throw NotificationSessionError.unknownAccount
        }

        coreDataStack = CoreDataStack(
            account: account,
            applicationContainer: sharedContainerURL
        )

        coreDataStack.loadStores { error in
            // TODO: error handling
        }

        let cookieStorage = ZMPersistentCookieStorage(
            forServerName: environment.backendURL.host!,
            userIdentifier: accountID
        )

        let reachabilityGroup = ZMSDispatchGroup(
            dispatchGroup: DispatchGroup(),
            label: "Sharing session reachability"
        )!

        let serverNames = [environment.backendURL, environment.backendWSURL].compactMap(\.host)
        let reachability = ZMReachability(serverNames: serverNames, group: reachabilityGroup)

        transportSession = ZMTransportSession(
            environment: environment,
            cookieStorage: cookieStorage,
            reachability: reachability,
            initialAccessToken: nil,
            applicationGroupIdentifier: appGroupID,
            applicationVersion: "1.0.0"
        )
    }

    deinit {
        transportSession.tearDown()
    }

    // MARK: - Methods

    public func processPushPayload(_ payload: [AnyHashable: Any]) {
        guard isUserAuthenticated else {
            delegate?.notificationSessionFailedwithError(error: .accountNotAuthenticated)
            return
        }

        guard let eventID = eventID(fromPayload: payload) else {
            delegate?.notificationSessionFailedwithError(error: .noEventID)
            return
        }

        // TODO: fetch events starting with eventID
    }

    var isUserAuthenticated: Bool {
        transportSession.cookieStorage.authenticationCookieData != nil
    }

    func eventID(fromPayload payload: [AnyHashable: Any]) -> UUID? {
        guard
            let payloadData = payload["data"] as? [AnyHashable: Any],
            let data = payloadData["data"] as? [AnyHashable: Any],
            let eventID = data["id"] as? String
        else {
            return nil
        }

        return UUID(uuidString: eventID)
    }

}
