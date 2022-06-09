//
//  EventsFetcher.swift
//  WireNotificationEngine
//
//  Created by Marcin Ratajczak on 08/06/2022.
//  Copyright © 2022 Wire. All rights reserved.
//

import Foundation
import WireRequestStrategy

public protocol EventsFetcher {
    func fetchEventWithId(eventId: UUID, completionHandler: @escaping () -> Void)
}


extension PushNotificationStatus: EventsFetcher {
    public func fetchEventWithId(eventId: UUID, completionHandler: @escaping () -> Void) {
        fetch(eventId: eventId, completionHandler: completionHandler)
    }
}
