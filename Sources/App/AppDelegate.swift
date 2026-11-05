import AppKit
import ServiceManagement

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, PopupHost {
  // NSApplication.delegate is weak.
  private static var instance: AppDelegate?

  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    instance = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.mainMenu = editMenu()
    app.run()
  }

  let history = History()
  let hotKey = HotKey()
  private let monitor = ClipboardMonitor()
  private lazy var popup = PopupController(host: self)
  private var statusItem: NSStatusItem!
  private let thumbnailQueue = DispatchQueue(label: "clipkeep.thumbnails", qos: .utility)
  private var lastCloseTime = Date.distantPast

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = statusItem.button {
      button.image = Self.menuIcon()
      button.target = self
      button.action = #selector(statusItemClicked)
      button.sendAction(on: [.leftMouseDown, .rightMouseDown])
    }

    monitor.onCapture = { [weak self] item in self?.captured(item) }
    monitor.start()

    hotKey.onPress = { [weak self] in self?.hotKeyPressed() }
    hotKey.register()
    updateStatusItem()
  }

  // MARK: capture

  private func captured(_ item: ClipItem) {
    history.add(item)
    popup.reload()
    // A repeat copy may have kept the older entry (and its thumbnail) instead of this one.
    guard history.items.first === item, item.kind == .image, item.thumbnail == nil, let content = item.imageContent else { return }
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    let id = item.id
    thumbnailQueue.async { [weak self] in
      let thumbnail = ImageRender.downscaled(content, maxPixelWidth: Style.imageMaxWidth * scale,
                                             maxPixelHeight: Style.imageMaxHeight * scale)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, let item = self.history.items.first(where: { $0.id == id }) else { return }
          item.thumbnail = thumbnail
          self.popup.reload()
        }
      }
    }
  }

  // MARK: popup

  private func hotKeyPressed() {
    guard !popup.isOpen else { return popup.close() }
    popup.open(at: .cursor, mode: .opening)
    // While open, the popup's own key monitor handles ⇧⌘C (cycle/toggle), as Maccy does.
    if popup.isKey { hotKey.unregister() }
  }

  @objc private func statusItemClicked() {
    if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
      popup.close()
      togglePause()
      return
    }
    if popup.isOpen {
      popup.close()
      return
    }
    // The mouse-down that closed the popup (outside click) must not reopen it.
    guard Date().timeIntervalSince(lastCloseTime) > 0.3,
          let button = statusItem.button, let window = button.window else { return }
    let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
    popup.open(at: .statusItem(rect), mode: .toggle)
    button.highlight(true)
    if popup.isKey { hotKey.unregister() }
  }

  func popupDidClose() {
    lastCloseTime = Date()
    statusItem.button?.highlight(false)
    hotKey.register()
    updateStatusItem()
  }

  func popupSelected(_ item: ClipItem) {
    monitor.write(item)
    history.promote(item.id, now: Date())
    popup.close()
  }

  func popupDeleted(_ item: ClipItem) {
    history.remove(item.id)
  }

  func popupCopyText(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    popup.close()
  }

  func footerItems() -> [FooterItem] {
    [
      FooterItem(title: "Clear", modifiers: "⌥⌘", key: "⌫", confirmation: "Clear the clipboard history?") { [weak self] in
        self?.history.clear()
        self?.popup.reload()
      },
      FooterItem(title: monitor.isPaused ? "Resume" : "Pause") { [weak self] in
        self?.togglePause()
        self?.popup.close()
      },
      FooterItem(title: "Launch at Login", key: isLaunchAtLoginEnabled ? "✓" : "") { [weak self] in
        self?.toggleLaunchAtLogin()
        self?.popup.close()
      },
      FooterItem(title: "Quit", modifiers: "⌘", key: "Q") { NSApp.terminate(nil) },
    ]
  }

  // MARK: settings

  private func togglePause() {
    monitor.isPaused.toggle()
    updateStatusItem()
  }

  private func updateStatusItem() {
    guard let button = statusItem?.button else { return }
    button.appearsDisabled = monitor.isPaused
    var tip = "Clipkeep"
    if monitor.isPaused { tip += " (paused, ⌥-click to resume)" }
    if !hotKey.isRegistered && !popup.isOpen { tip += "\n\(HotKey.display) is in use by another app" }
    button.toolTip = tip
  }

  private var isLaunchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

  private func toggleLaunchAtLogin() {
    do {
      if isLaunchAtLoginEnabled {
        try SMAppService.mainApp.unregister()
      } else {
        try SMAppService.mainApp.register()
      }
    } catch {
      NSLog("Clipkeep: launch at login failed: %@", String(describing: error))
    }
    if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
  }

  /// Never shown (accessory app), but AppKit routes ⌘C/⌘V/⌘X/⌘A/⌘Z in the search field through it.
  private static func editMenu() -> NSMenu {
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let main = NSMenu()
    main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
    return main
  }

  /// Maccy's paperclip menu icon (MIT, see MACCY-LICENSE), as a template so it follows the menu bar appearance.
  private static func menuIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 16, height: 16))
    for name in ["MenuIcon-16", "MenuIcon-32"] {
      if let url = Bundle.main.url(forResource: name, withExtension: "png"), let rep = NSImageRep(contentsOf: url) {
        rep.size = NSSize(width: 16, height: 16)
        image.addRepresentation(rep)
      }
    }
    image.isTemplate = true
    return image
  }
}
