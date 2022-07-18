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

public protocol NotificationSessionProtocol {

    var delegate: NotificationSessionDelegate? { get set }

    init(
        accountID: UUID,
        appGroupID: String,
        environment: BackendEnvironmentProvider
    ) throws

    func processPushPayload(_ payload: [AnyHashable: Any])

}

public protocol NotificationSessionDelegate: AnyObject {

    func notificationSessionFailedwithError(error: NotificationSessionError)

    func notificationSessionDidGenerateNotification(
        _ notification: ZMLocalNotification?,
        unreadConversationCount: Int
    )

    func reportCallEvent(
        _ event: ZMUpdateEvent,
        currentTimestamp: TimeInterval
    )

}

public enum NotificationSessionError: Error {

    case unknownAccount
    case accountNotAuthenticated
    case noEventID

}
