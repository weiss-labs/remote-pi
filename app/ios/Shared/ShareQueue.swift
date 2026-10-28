// Plan/74 — App Group hand-off between the Share extension and the app.
// Compiled into BOTH targets. The extension only writes (a copied file plus
// one JSON entry bound to the pane the user picked); the app reads, sends over
// its paired channel, then deletes. Nothing here talks to the network.
import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum ShareQueue {
  static let appGroup = "group.ai.weisslabs.remotepi"
  static let openURL = URL(string: "remotepi://share")!
  /// Entries older than this are dropped unsent (the app was never opened).
  static let maxAge: TimeInterval = 7 * 24 * 3600
  static let maxBytes = 200 * 1024 * 1024

  static var container: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
  }
  static var inbox: URL? { container?.appendingPathComponent("inbox", isDirectory: true) }
  static var panesFile: URL? { container?.appendingPathComponent("panes.json") }

  struct Pane: Codable {
    var peer: String, room: String, workspace: String, tab: String?, pane: String, device: String, online: Bool
  }
  struct Entry: Codable {
    var id: String, peer: String, room: String, label: String
    var name: String, mime: String, size: Int, path: String, created: Double
    var duration_ms: Int?
  }

  // MARK: app side
  static func publish(panes: [Pane]) throws {
    guard let url = panesFile, let container = container else { return }
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    let data = try JSONEncoder().encode(panes)
    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  /// Oldest first. Corrupt or expired entries are deleted, never guessed.
  static func pending() -> [Entry] {
    guard let inbox = inbox, let names = try? FileManager.default.contentsOfDirectory(atPath: inbox.path) else { return [] }
    var out: [Entry] = []
    for name in names where name.hasSuffix(".json") {
      let url = inbox.appendingPathComponent(name)
      guard let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(Entry.self, from: data),
        entry.id == String(name.dropLast(5)), Date().timeIntervalSince1970 - entry.created < maxAge,
        FileManager.default.fileExists(atPath: entry.path) else {
        remove(id: String(name.dropLast(5)))
        continue
      }
      out.append(entry)
    }
    return out.sorted { $0.created < $1.created }
  }

  static func remove(id: String) {
    guard let inbox = inbox, id.range(of: "^[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil else { return }
    try? FileManager.default.removeItem(at: inbox.appendingPathComponent("\(id).json"))
    try? FileManager.default.removeItem(at: inbox.appendingPathComponent(id, isDirectory: true))
  }

  // MARK: extension side
  static func panes() -> [Pane] {
    guard let url = panesFile, let data = try? Data(contentsOf: url) else { return [] }
    return (try? JSONDecoder().decode([Pane].self, from: data)) ?? []
  }

  /// Copies [source] into the container and queues it for [pane].
  static func enqueue(source: URL, name: String, mime: String, durationMs: Int?, pane: Pane) throws -> Entry {
    guard let inbox = inbox else { throw ShareError.noContainer }
    let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int) ?? 0
    guard size > 0 else { throw ShareError.empty }
    guard size <= maxBytes else { throw ShareError.tooLarge }
    let id = UUID().uuidString
    let dir = inbox.appendingPathComponent(id, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    let safe = safeName(name)
    let dest = dir.appendingPathComponent(safe)
    try FileManager.default.copyItem(at: source, to: dest)
    let label = pane.tab.map { "\(pane.workspace) › \($0) › \(pane.pane)" } ?? "\(pane.workspace) › \(pane.pane)"
    let entry = Entry(id: id, peer: pane.peer, room: pane.room, label: label, name: safe, mime: mime, size: size,
      path: dest.path, created: Date().timeIntervalSince1970, duration_ms: durationMs)
    let data = try JSONEncoder().encode(entry)
    try data.write(to: inbox.appendingPathComponent("\(id).json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    return entry
  }

  static func safeName(_ raw: String) -> String {
    var text = raw.components(separatedBy: CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))).joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    while text.hasPrefix(".") { text.removeFirst() }
    if text.isEmpty { text = "attachment" }
    return String(text.prefix(120))
  }

  enum ShareError: LocalizedError {
    case noContainer, empty, tooLarge, unsupported
    var errorDescription: String? {
      switch self {
      case .noContainer: return "The shared storage is unavailable. Reinstall Remote Pi."
      case .empty: return "That item is empty."
      case .tooLarge: return "Files are limited to 200 MiB."
      case .unsupported: return "Only photos, videos and files can be shared."
      }
    }
  }
}

/// Which pasteboard/share item types become attachments, and how to copy them.
enum AttachmentTypes {
  /// The first registered type that is real file bytes (not text, not a web URL).
  static func pick(_ provider: NSItemProvider) -> UTType? {
    var fallback: UTType?
    for id in provider.registeredTypeIdentifiers {
      guard let type = UTType(id) else { continue }
      if type.conforms(to: .movie) || type.conforms(to: .image) || type.conforms(to: .audio) || type.conforms(to: .pdf) { return type }
      if type.conforms(to: .text) || type.conforms(to: .url) || type == .fileURL || type.conforms(to: .propertyList) { continue }
      if fallback == nil && type.conforms(to: .data) && type != .data && type != .item && type != .content { fallback = type }
    }
    if fallback == nil && provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { return .fileURL }
    return fallback
  }

  static func mime(for type: UTType, name: String) -> String {
    if let m = type.preferredMIMEType { return m }
    if type.conforms(to: .movie) { return "video/quicktime" }
    if type.conforms(to: .image) { return "image/jpeg" }
    return "application/octet-stream"
  }

  /// Copies the provider's file representation into [directory]/<uuid>/<name>
  /// and reports {path,name,mime,size,duration_ms?}. Nil when it cannot.
  static func copy(provider: NSItemProvider, type: UTType, into directory: URL, _ done: @escaping ([String: Any]?) -> Void) {
    let finish: (URL?) -> Void = { source in
      guard let source = source else { done(nil); return }
      let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var name = ShareQueue.safeName(provider.suggestedName ?? source.lastPathComponent)
        if (name as NSString).pathExtension.isEmpty, let ext = (type == .fileURL ? UTType(filenameExtension: source.pathExtension) : type)?.preferredFilenameExtension {
          name += ".\(ext)"
        }
        let dest = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: dest)
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
        guard size > 0, size <= ShareQueue.maxBytes else { try? FileManager.default.removeItem(at: folder); done(nil); return }
        let resolved = type == .fileURL ? (UTType(filenameExtension: dest.pathExtension) ?? .data) : type
        var item: [String: Any] = ["path": dest.path, "name": name, "mime": mime(for: resolved, name: name), "size": size]
        if resolved.conforms(to: .movie) {
          Task {
            if let seconds = try? await AVURLAsset(url: dest).load(.duration).seconds, seconds.isFinite, seconds > 0 {
              item["duration_ms"] = Int(seconds * 1000)
            }
            done(item)
          }
        } else { done(item) }
      } catch { try? FileManager.default.removeItem(at: folder); done(nil) }
    }
    if type == .fileURL {
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
        let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
        guard let url = url, url.isFileURL else { finish(nil); return }
        let scoped = url.startAccessingSecurityScopedResource()
        finish(url)
        if scoped { url.stopAccessingSecurityScopedResource() }
      }
    } else {
      // The temporary URL is only valid inside the handler, so copy synchronously there.
      provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in finish(url) }
    }
  }
}
