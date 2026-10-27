import Foundation

let target: [String: Any] = ["v": 1, "peer": "paired-peer", "room": "room-a"]
func suppress(_ active: Bool, _ peer: String?, _ room: String?, _ payload: [String: Any]? = target) -> Bool {
  NotificationPresentationPolicy.suppress(isActive: active, visiblePeer: peer, visibleRoom: room, target: payload)
}
assert(suppress(true, "paired-peer", "room-a"))
assert(!suppress(false, "paired-peer", "room-a"))
assert(!suppress(true, "paired-peer", "room-b"))
assert(!suppress(true, "other-peer", "room-a"))
assert(!suppress(true, nil, nil))
assert(!suppress(true, "paired-peer", "room-a", nil))
assert(!suppress(true, "paired-peer", "room-a", ["peer": "paired-peer", "room": "room-a"]))
print("PASS: seven foreground notification suppression cases")
