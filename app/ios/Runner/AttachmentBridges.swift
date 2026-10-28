// Plan/74 — native halves of (1) paste-as-attachment and (2) the Share
// extension queue. Both only move files inside app-private storage and hand
// paths/metadata to Dart; the paired channel does the sending.
import Flutter
import UIKit
import UniformTypeIdentifiers

/// Copies real pasteboard items (images, movies, files) into a private temp
/// directory. Text and URLs are never returned: those stay text in the composer.
final class PasteboardBridge {
  private let channel: FlutterMethodChannel
  private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pasted-attachments", isDirectory: true)

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "ai.weisslabs.remotepi/pasteboard", binaryMessenger: messenger)
    try? FileManager.default.removeItem(at: directory)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "hasAttachments":
        // Type checks only: no content is read, so no paste banner.
        result(UIPasteboard.general.itemProviders.contains { AttachmentTypes.pick($0) != nil })
      case "readAttachments": self.read(result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func read(_ result: @escaping FlutterResult) {
    let providers = UIPasteboard.general.itemProviders.prefix(10)
    let group = DispatchGroup()
    var items: [[String: Any]] = []
    let lock = NSLock()
    for provider in providers {
      guard let type = AttachmentTypes.pick(provider) else { continue }
      group.enter()
      AttachmentTypes.copy(provider: provider, type: type, into: directory) { item in
        if let item = item { lock.lock(); items.append(item); lock.unlock() }
        group.leave()
      }
    }
    group.notify(queue: .main) { result(items) }
  }
}

/// App side of the Share extension queue (see ios/Shared/ShareQueue.swift).
final class ShareInboxBridge {
  private let channel: FlutterMethodChannel
  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "ai.weisslabs.remotepi/share", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "takeQueued":
        result(ShareQueue.pending().map { e -> [String: Any] in
          var m: [String: Any] = ["id": e.id, "peer": e.peer, "room": e.room, "label": e.label, "name": e.name,
            "mime": e.mime, "size": e.size, "path": e.path]
          if let d = e.duration_ms { m["duration_ms"] = d }
          return m
        })
      case "complete":
        if let id = (call.arguments as? [String: Any])?["id"] as? String { ShareQueue.remove(id: id) }
        result(nil)
      case "publishPanes":
        let raw = (call.arguments as? [String: Any])?["panes"] as? [[String: Any]] ?? []
        let panes = raw.compactMap { p -> ShareQueue.Pane? in
          guard let peer = p["peer"] as? String, let room = p["room"] as? String, let workspace = p["workspace"] as? String,
            let pane = p["pane"] as? String, let device = p["device"] as? String else { return nil }
          return ShareQueue.Pane(peer: peer, room: room, workspace: workspace, tab: p["tab"] as? String, pane: pane,
            device: device, online: p["online"] as? Bool ?? false)
        }
        do { try ShareQueue.publish(panes: panes); result(nil) } catch {
          result(FlutterError(code: "publish_failed", message: "Unable to publish panes", details: nil))
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
}
