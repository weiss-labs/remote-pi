// Plan/74 — "Share → Remote Pi": pick a pane (same Herdr grouping and names as
// Home), the item is copied into the App Group inbox bound to that pane, and
// the app opens on that pane with the item attached (unsent) so the user can
// add a note or voice memo. If iOS won't open the app, it picks the item up on
// the next manual open.
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
  private var sections: [(title: String, panes: [ShareQueue.Pane])] = []
  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private var busy = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGroupedBackground
    title = "Open in pane"
    navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
    var grouped: [(String, [ShareQueue.Pane])] = []
    for pane in ShareQueue.panes() {
      if let last = grouped.last, last.0 == pane.workspace { grouped[grouped.count - 1].1.append(pane) }
      else { grouped.append((pane.workspace, [pane])) }
    }
    sections = grouped.map { (title: $0.0, panes: $0.1) }
    table.dataSource = self; table.delegate = self
    table.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(table)
    NSLayoutConstraint.activate([
      table.topAnchor.constraint(equalTo: view.topAnchor), table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      table.leadingAnchor.constraint(equalTo: view.leadingAnchor), table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    if sections.isEmpty {
      let label = UILabel(); label.numberOfLines = 0; label.textAlignment = .center; label.textColor = .secondaryLabel
      label.text = "No panes yet. Open Remote Pi once so it can list your panes here."
      table.backgroundView = label
    }
  }

  // The system wraps the principal class in a navigation controller only for SLComposeServiceViewController;
  // provide our own bar when presented bare.
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if navigationController == nil {
      let nav = UINavigationController(rootViewController: ShareViewController())
      nav.modalPresentationStyle = .fullScreen
      nav.view.frame = view.bounds
      addChild(nav); view.addSubview(nav.view); nav.didMove(toParent: self)
      table.isHidden = true
    }
  }

  @objc private func cancel() {
    extensionContext?.cancelRequest(withError: NSError(domain: "ai.weisslabs.remotepi.share", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cancelled"]))
  }

  func numberOfSections(in tableView: UITableView) -> Int { sections.count }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].panes.count }
  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let pane = sections[indexPath.section].panes[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "pane") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "pane")
    cell.textLabel?.text = pane.pane
    let detail = [pane.tab, pane.device].compactMap { $0 }.joined(separator: " · ")
    cell.detailTextLabel?.text = (pane.online ? "● " : "○ ") + detail
    cell.detailTextLabel?.textColor = pane.online ? .systemGreen : .secondaryLabel
    cell.accessoryType = .disclosureIndicator
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard !busy else { return }
    busy = true
    let pane = sections[indexPath.section].panes[indexPath.row]
    let providers = (extensionContext?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
    let usable = providers.compactMap { p in AttachmentTypes.pick(p).map { (p, $0) } }
    guard !usable.isEmpty else { fail(ShareQueue.ShareError.unsupported); return }
    let staging = FileManager.default.temporaryDirectory.appendingPathComponent("share-staging-\(UUID().uuidString)", isDirectory: true)
    let group = DispatchGroup()
    var queued: [ShareQueue.Entry] = []
    var failure: Error?
    let lock = NSLock()
    for (provider, type) in usable.prefix(10) {
      group.enter()
      AttachmentTypes.copy(provider: provider, type: type, into: staging) { item in
        defer { group.leave() }
        guard let item = item, let path = item["path"] as? String, let name = item["name"] as? String, let mime = item["mime"] as? String else {
          lock.lock(); failure = failure ?? ShareQueue.ShareError.unsupported; lock.unlock(); return
        }
        do {
          let entry = try ShareQueue.enqueue(source: URL(fileURLWithPath: path), name: name, mime: mime, durationMs: item["duration_ms"] as? Int, pane: pane)
          lock.lock(); queued.append(entry); lock.unlock()
        } catch { lock.lock(); failure = failure ?? error; lock.unlock() }
      }
    }
    group.notify(queue: .main) { [weak self] in
      try? FileManager.default.removeItem(at: staging)
      guard let self = self else { return }
      if queued.isEmpty { self.fail(failure ?? ShareQueue.ShareError.unsupported); return }
      if self.openApp() { self.extensionContext?.completeRequest(returningItems: nil); return }
      let label = queued[0].label
      let names = queued.map { $0.name }.joined(separator: ", ")
      let alert = UIAlertController(title: "Ready for \(label)",
        message: "Open Remote Pi to add a note and send \(names).", preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "Done", style: .default) { _ in self.extensionContext?.completeRequest(returningItems: nil) })
      self.present(alert, animated: true)
    }
  }

  private func fail(_ error: Error) {
    busy = false
    let alert = UIAlertController(title: "Not shared", message: error.localizedDescription, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }

  /// Best effort: extensions have no public API to launch their app. The
  /// responder-chain `openURL:` works on current iOS; if it ever stops, the
  /// queue still drains the next time the app is opened by hand.
  private func openApp() -> Bool {
    let selector = sel_registerName("openURL:")
    var responder: UIResponder? = self
    while let r = responder {
      if r.responds(to: selector) && !(r is UIViewController) {
        _ = r.perform(selector, with: ShareQueue.openURL)
        return true
      }
      responder = r.next
    }
    return false
  }
}
