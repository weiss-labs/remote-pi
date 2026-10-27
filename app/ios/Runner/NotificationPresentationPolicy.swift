import Foundation

// Pure policy shared by the notification delegate and native regression tests.
enum NotificationPresentationPolicy {
  static func suppress(isActive: Bool, visiblePeer: String?, visibleRoom: String?, target: [String: Any]?) -> Bool {
    guard isActive, let peer = visiblePeer, let room = visibleRoom,
          !peer.isEmpty, !room.isEmpty, target?["v"] as? Int == 1 else { return false }
    return target?["peer"] as? String == peer && target?["room"] as? String == room
  }
}
