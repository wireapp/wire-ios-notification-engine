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
import WireTransport.ZMRequestCancellation
import WireLinkPreview

class StrategyFactory {

    unowned let contextProvider: ContextProvider
    let applicationStatus: ApplicationStatus
    let pushNotificationStatus: PushNotificationStatus
    let notificationsTracker: NotificationsTracker?
    private(set) var strategies = [AnyObject]()
    private(set) var delegate: PushNotificationStrategyDelegate?

    private var tornDown = false

    init(contextProvider: ContextProvider,
         applicationStatus: ApplicationStatus,
         pushNotificationStatus: PushNotificationStatus,
         notificationsTracker: NotificationsTracker?,
         pushNotificationStrategyDelegate: PushNotificationStrategyDelegate?,
         useLegacyPushNotifications: Bool) {

        self.contextProvider = contextProvider
        self.applicationStatus = applicationStatus
        self.pushNotificationStatus = pushNotificationStatus
        self.notificationsTracker = notificationsTracker
        self.delegate = pushNotificationStrategyDelegate

        self.strategies = [
            createPushNotificationStrategy(useLegacyPushNotifications: useLegacyPushNotifications)
        ]
    }

    deinit {
        precondition(tornDown, "Need to call `tearDown` before `deinit`")
    }

    func tearDown() {
        strategies.forEach {
            if $0.responds(to: #selector(ZMObjectSyncStrategy.tearDown)) {
                ($0 as? ZMObjectSyncStrategy)?.tearDown()
            }
        }
        tornDown = true
    }

    private func createPushNotificationStrategy(useLegacyPushNotifications: Bool) -> PushNotificationStrategy {
        return PushNotificationStrategy(withManagedObjectContext: contextProvider.syncContext,
                                        eventContext: contextProvider.eventContext,
                                        applicationStatus: applicationStatus,
                                        pushNotificationStatus: pushNotificationStatus,
                                        notificationsTracker: notificationsTracker,
                                        delegate: delegate,
                                        useLegacyPushNotifications: useLegacyPushNotifications)
    }
}

