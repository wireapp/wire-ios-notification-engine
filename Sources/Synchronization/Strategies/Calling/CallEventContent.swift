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

struct CallEventContent: Decodable {

    /// Call event type
    let type: String

    let resp: Bool

    /// Caller Id
    let callerIDString: String

    private enum CodingKeys: String, CodingKey {
        case type
        case resp
        case callerIDString = "src_userid"
    }

    // MARK: - Initialization

     init?(from data: Data) {
         let decoder = JSONDecoder()
         do {
             self = try decoder.decode(Self.self, from: data)
         } catch {
             return nil
         }
     }

    var callerID: UUID? {
        return UUID(uuidString: callerIDString)
    }

    // A call event is considered an incoming call if:
    // 'type' is “SETUP” or “GROUPSTART” or “CONFSTART” and
    // 'resp' is false
    var callState: LocalNotificationType.CallState? {
        switch (isStartCall, resp) {
        case (true, false):
            return .incomingCall(video: false)
        case (false, _):
            return .missedCall(cancelled: true)
        default:
            return nil
        }
    }

    var isStartCall: Bool {
        switch type {
        case "SETUP", "GROUPSTART", "CONFSTART":
            return true
        case "CANCEL":
            return false
        default:
            return false
        }
    }

 }

