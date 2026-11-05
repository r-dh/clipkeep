import AppKit
import Carbon.HIToolbox

struct FooterItem {
  let title: String
  var modifiers = ""
  var key = ""
  /// When set, the action runs only after the user confirms this question.
  var confirmation: String?
  let action: () -> Void
}

@MainActor
protocol PopupHost: AnyObject {
  var history: History { get }
  var hotKey: HotKey { get }
  func footerItems() -> [FooterItem]
  func popupSelected(_ item: ClipItem)
  func popupDeleted(_ item: ClipItem)
  func popupCopyText(_ text: String)
  func popupDidClose()
}

/// Non-activating panel: takes keyboard focus without activating the app, so the previous app stays frontmost.
final class PopupPanel: NSPanel {
  var onResignKey: (() -> Void)?
  /// Set while our confirmation sheet is up, so the sheet taking focus does not close the popup.
  var isShowingSheet = false

  init() {
    super.init(contentRect: NSRect(x: 0, y: 0, width: Style.width, height: 100),
               styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
    isReleasedWhenClosed = false
    isRestorable = false
    animationBehavior = .none
    isFloatingPanel = true
    level = .statusBar
    collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    titlebarSeparatorStyle = .none
    isMovableByWindowBackground = true
    hidesOnDeactivate = false
    sharingType = .none // keep history out of screen sharing and recordings
    backgroundColor = .clear
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      standardWindowButton(button)?.isHidden = true
    }
  }

  override var canBecomeKey: Bool { true }

  override func resignKey() {
    super.resignKey()
    // Close on outside click, but not while our own confirmation sheet has focus.
    if !isShowingSheet { onResignKey?() }
  }
}

@MainActor
final class PopupController: NSObject, NSTextFieldDelegate {
  enum Anchor {
    case cursor
    case statusItem(NSRect)
  }

  /// Maccy's hotkey modes: a quick press toggles; holding the modifiers and pressing again cycles,
  /// and releasing them selects.
  enum Mode { case toggle, opening, cycle }

  private unowned let host: PopupHost
  private var panel: PopupPanel?
  private let root = FlippedView()
  private let titleLabel = makeLabel("Clipkeep", color: .secondaryLabelColor)
  private let search = SearchFieldView()
  private let scroll = NSScrollView()
  private let list = FlippedView()
  private let footerSeparator = SeparatorView()

  private var items: [ClipItem] = []
  private var itemRows: [RowView] = []
  private var footer: [FooterItem] = []
  private var footerRows: [RowView] = []
  private var selected: Int?
  private var mode = Mode.toggle
  private var anchorTop: CGFloat = 0
  private var anchorX: CGFloat = 0
  private var positioned = false
  private var eventMonitor: Any?
  private var previewTimer: Timer?
  private var popover: NSPopover?
  private var previewDelay: TimeInterval = 1.5
  private var sheetObserver: NSObjectProtocol?

  init(host: PopupHost) {
    self.host = host
    super.init()
    root.addSubview(titleLabel)
    titleLabel.sizeToFit()
    root.addSubview(search)
    search.textField.delegate = self
    search.onClear = { [weak self] in self?.setQuery("") }
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.documentView = list
    root.addSubview(scroll)
    root.addSubview(footerSeparator)
  }

  var isOpen: Bool { panel != nil }
  var isKey: Bool { panel?.isKeyWindow ?? false }
  var openedFromStatusItem = false

  func open(at anchor: Anchor, mode: Mode) {
    guard panel == nil else { return }
    self.mode = mode
    previewDelay = 1.5
    search.textField.stringValue = ""
    search.queryChanged()

    let panel = PopupPanel()
    panel.onResignKey = { [weak self] in self?.close() }
    panel.contentView = makeBackground()
    self.panel = panel

    footer = host.footerItems()
    footerRows.forEach { $0.removeFromSuperview() }
    footerRows = footer.enumerated().map { index, entry in
      let row = RowView(title: entry.title, modifiers: entry.modifiers, key: entry.key)
      wire(row, index: { [weak self] in (self?.items.count ?? 0) + index })
      root.addSubview(row)
      return row
    }

    positioned = false
    let mouse = NSEvent.mouseLocation
    switch anchor {
    case .cursor:
      openedFromStatusItem = false
      anchorX = mouse.x
      anchorTop = mouse.y
    case .statusItem(let rect):
      openedFromStatusItem = true
      anchorX = rect.minX
      anchorTop = rect.minY
    }

    // A quick tap may be released before the panel is key; then it is a toggle, not a cycle.
    if mode == .opening, !NSEvent.modifierFlags.isSuperset(of: HotKey.modifiers) { self.mode = .toggle }

    reload(keepSelection: false)
    panel.orderFrontRegardless()
    panel.makeKey()
    panel.makeFirstResponder(search.textField)
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
      let consumed = MainActor.assumeIsolated { self?.consume(event) ?? false }
      return consumed ? nil : event
    }
  }

  func close() {
    guard let panel else { return }
    self.panel = nil
    if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    eventMonitor = nil
    cancelPreview()
    if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
    sheetObserver = nil
    panel.isShowingSheet = false
    if let sheet = panel.attachedSheet { panel.endSheet(sheet) }
    panel.onResignKey = nil
    panel.orderOut(nil)
    // Drop every view that references history data; the panel and its backing store are rebuilt on next open.
    panel.contentView = nil
    itemRows.forEach { $0.removeFromSuperview() }
    itemRows = []
    items = []
    footerRows.forEach { $0.removeFromSuperview() }
    footerRows = []
    footer = []
    root.removeFromSuperview()
    search.textField.stringValue = ""
    selected = nil
    host.popupDidClose()
  }

  /// Rebuilds rows after a capture, thumbnail, deletion or search change.
  func reload(keepSelection: Bool = true) {
    guard panel != nil else { return }
    let selectedID = keepSelection ? selectedItem?.id : nil
    let selectedFooter = keepSelection ? selectedFooterIndex : nil
    let results = host.history.search(search.textField.stringValue)
    items = results.map(\.item)
    itemRows.forEach { $0.removeFromSuperview() }
    itemRows = results.enumerated().map { index, result in
      let shortcut = index < 9 ? String(index + 1) : ""
      let row = RowView(title: result.item.title, highlights: result.ranges,
                        modifiers: shortcut.isEmpty ? "" : "⌘", key: shortcut,
                        image: result.item.kind == .image ? result.item.thumbnail : nil)
      wire(row, index: { index })
      list.addSubview(row)
      return row
    }
    layout()

    let newSelection: Int?
    if let selectedID, let i = items.firstIndex(where: { $0.id == selectedID }) {
      newSelection = i
    } else if let selectedFooter {
      newSelection = items.count + selectedFooter
    } else {
      newSelection = items.isEmpty ? nil : 0
    }
    let previewWasShown = popover != nil
    let previewWasPending = previewTimer != nil
    let sameItem = selectedID != nil && newSelection.map { $0 < items.count && items[$0].id == selectedID } == true
    selected = nil
    select(newSelection, scroll: true, preview: !sameItem)
    // Rows were rebuilt, so re-anchor a visible preview instead of restarting its delay.
    if sameItem && previewWasShown { showPreview() } else if sameItem && previewWasPending { schedulePreview() }
  }

  // MARK: layout

  private func makeBackground() -> NSView {
    root.removeFromSuperview()
    if #available(macOS 26.0, *) {
      let glass = NSGlassEffectView()
      glass.contentView = root
      return glass
    }
    let effect = NSVisualEffectView()
    effect.material = .popover
    effect.blendingMode = .behindWindow
    effect.state = .active
    root.frame = effect.bounds
    root.autoresizingMask = [.width, .height]
    effect.addSubview(root)
    return effect
  }

  private func layout() {
    guard let panel else { return }
    let pad = Style.padding
    let innerWidth = Style.width - 2 * pad
    var y = pad

    titleLabel.frame.origin = NSPoint(x: pad + 10, y: y + (Style.itemHeight + 3 - titleLabel.frame.height) / 2)
    let searchX = titleLabel.frame.maxX + 8
    search.frame = NSRect(x: searchX, y: y, width: Style.width - pad - 10 - searchX, height: Style.itemHeight + 3)
    y += Style.itemHeight + 3 + 5

    let footerHeight = 13 + CGFloat(footerRows.count) * Style.itemHeight
    // Top-left stays anchored (cursor or status item, then wherever the user dragged it) and on screen.
    if positioned {
      anchorX = panel.frame.minX
      anchorTop = panel.frame.maxY
    }
    positioned = true
    let screen = screenForAnchor()
    let maxHeight = min(Style.maxHeight, screen.visibleFrame.height)
    let listHeight = itemRows.reduce(0) { $0 + $1.preferredHeight }
    let scrollHeight = max(0, min(listHeight, maxHeight - y - footerHeight - pad))

    scroll.frame = NSRect(x: pad, y: y, width: innerWidth, height: scrollHeight)
    list.frame = NSRect(x: 0, y: 0, width: innerWidth, height: listHeight)
    var rowY: CGFloat = 0
    for row in itemRows {
      row.frame = NSRect(x: 0, y: rowY, width: innerWidth, height: row.preferredHeight)
      rowY += row.preferredHeight
    }
    y += scrollHeight

    footerSeparator.frame = NSRect(x: pad + 10, y: y, width: innerWidth - 20, height: 13)
    y += 13
    for row in footerRows {
      row.frame = NSRect(x: pad, y: y, width: innerWidth, height: Style.itemHeight)
      y += Style.itemHeight
    }
    y += pad

    let visible = screen.visibleFrame
    let x = min(max(anchorX, visible.minX), visible.maxX - Style.width)
    let top = min(max(anchorTop, visible.minY + y), visible.maxY)
    panel.setFrame(NSRect(x: x, y: top - y, width: Style.width, height: y), display: true)
    root.frame = NSRect(x: 0, y: 0, width: Style.width, height: y)
  }

  private func screenForAnchor() -> NSScreen {
    let point = NSPoint(x: anchorX, y: anchorTop)
    return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
  }

  // MARK: selection

  private var rowCount: Int { itemRows.count + footerRows.count }
  private var selectedItem: ClipItem? { selected.flatMap { $0 < items.count ? items[$0] : nil } }
  private var selectedFooterIndex: Int? { selected.flatMap { $0 >= items.count ? $0 - items.count : nil } }

  private func row(at index: Int) -> RowView? {
    if index < itemRows.count { return itemRows[index] }
    let f = index - itemRows.count
    return f < footerRows.count ? footerRows[f] : nil
  }

  private func wire(_ row: RowView, index: @escaping () -> Int) {
    row.onHover = { [weak self] in self?.select(index(), scroll: false, preview: true) }
    row.onClick = { [weak self] in
      guard let self else { return }
      self.select(index(), scroll: false, preview: false)
      self.activateSelection()
    }
  }

  private func select(_ index: Int?, scroll: Bool, preview: Bool = true) {
    guard index != selected else { return }
    if let selected { row(at: selected)?.isSelected = false }
    selected = index.flatMap { (0..<rowCount).contains($0) ? $0 : nil }
    cancelPreview()
    guard let selected, let row = row(at: selected) else { return }
    row.isSelected = true
    if scroll, selected < itemRows.count { list.scrollToVisible(row.frame) }
    if preview, selected < items.count { schedulePreview() }
  }

  private func move(_ delta: Int) {
    guard rowCount > 0 else { return }
    guard let selected else {
      if delta > 0 { select(0, scroll: true) } // Maccy: with nothing selected, only ↓ moves (to the first row)
      return
    }
    select(min(max(selected + delta, 0), rowCount - 1), scroll: true)
  }

  private func activateSelection() {
    if let item = selectedItem {
      host.popupSelected(item)
    } else if let f = selectedFooterIndex {
      runFooter(footer[f])
    } else if !search.textField.stringValue.isEmpty {
      host.popupCopyText(search.textField.stringValue)
    }
  }

  private func runFooter(_ entry: FooterItem) {
    guard let question = entry.confirmation, let panel else { return entry.action() }
    cancelPreview()
    let alert = NSAlert()
    alert.messageText = question
    alert.addButton(withTitle: "Clear")
    alert.addButton(withTitle: "Cancel")
    panel.isShowingSheet = true
    alert.beginSheetModal(for: panel) { [weak self] response in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.panel?.isShowingSheet = false
        if let observer = self.sheetObserver { NotificationCenter.default.removeObserver(observer) }
        self.sheetObserver = nil
        if response == .alertFirstButtonReturn { entry.action() }
        self.panel?.makeKey()
      }
    }
    // The panel's own resignKey fired when the sheet took focus; an outside click now only defocuses the sheet.
    sheetObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: alert.window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard let self, let panel = self.panel, panel.isShowingSheet,
                  !panel.isKeyWindow, panel.attachedSheet?.isKeyWindow != true else { return }
            self.close()
          }
        }
      }
    }
  }

  private func deleteSelected() {
    guard let item = selectedItem, let index = selected else { return }
    host.popupDeleted(item)
    selected = nil
    reload(keepSelection: false)
    select(items.isEmpty ? nil : min(index, items.count - 1), scroll: true)
  }

  private func setQuery(_ query: String) {
    search.textField.stringValue = query
    queryDidChange()
  }

  private func queryDidChange() {
    search.queryChanged()
    reload(keepSelection: false)
  }

  func controlTextDidChange(_ obj: Notification) {
    queryDidChange()
  }

  // MARK: preview

  private func schedulePreview() {
    guard panel?.isShowingSheet == false else { return }
    previewTimer = Timer.scheduledTimer(withTimeInterval: previewDelay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.showPreview() }
    }
  }

  private func cancelPreview() {
    previewTimer?.invalidate()
    previewTimer = nil
    popover?.close()
    popover = nil
  }

  private func showPreview() {
    guard let panel, !panel.isShowingSheet, let item = selectedItem else { return }
    guard item.kind == .image, let content = item.imageContent else { return presentPreview(item.id, image: nil) }
    let id = item.id
    let scale = panel.backingScaleFactor
    let size = PreviewViewController.maxImageSize(on: panel.screen)
    PreviewViewController.decodeQueue.async { [weak self] in
      let image = ImageRender.downscaled(content, maxPixelWidth: size.width * scale, maxPixelHeight: size.height * scale)
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.presentPreview(id, image: image) }
      }
    }
  }

  private func presentPreview(_ id: UUID, image: CGImage?) {
    // The selection may have moved while the image was decoding.
    guard let panel, !panel.isShowingSheet, let item = selectedItem, item.id == id, let index = selected, let row = row(at: index) else { return }
    popover?.close()
    let popover = NSPopover()
    popover.behavior = .semitransient
    popover.animates = false
    popover.contentViewController = PreviewViewController(item: item, image: image, scale: panel.backingScaleFactor)
    popover.show(relativeTo: row.bounds, of: row, preferredEdge: .maxX)
    self.popover = popover
    previewDelay = 0.2
  }

  // MARK: keyboard

  /// Returns true when the popup handled the key and the text field must not see it.
  private func consume(_ event: NSEvent) -> Bool {
    guard let panel, event.window === panel else { return false }
    let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])

    if event.type == .flagsChanged {
      if mods.isEmpty {
        if mode == .cycle {
          selectedItem == nil ? close() : activateSelection()
          return true
        }
        if mode == .opening { mode = .toggle }
      }
      return false
    }

    // The modifier release may have gone to the previous app before the panel became key.
    if mode == .opening, !mods.isSuperset(of: HotKey.modifiers) { mode = .toggle }
    let cycling = mode != .toggle && UInt32(event.keyCode) == host.hotKey.keyCode
    if host.hotKey.matches(event) || cycling {
      if event.isARepeat { return true }
      switch mode {
      case .opening, .cycle:
        // Cycle through history only: releasing on a footer row like Quit would be a nasty surprise.
        mode = .cycle
        if !items.isEmpty { select(((selectedItem == nil ? -1 : selected!) + 1) % items.count, scroll: true) }
      case .toggle:
        close()
      }
      return true
    }

    // Leave composition (Japanese/Chinese input) to the text field.
    if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }

    switch Int(event.keyCode) {
    case kVK_DownArrow where mods.contains(.command) || mods.contains(.option), kVK_PageDown:
      // Maccy: last history entry first, then the first footer row, then the last footer row.
      if selectedFooterIndex != nil {
        select(rowCount - 1, scroll: true)
      } else {
        select(selected == items.count - 1 || items.isEmpty ? items.count : items.count - 1, scroll: true)
      }
      return true
    case kVK_DownArrow:
      move(1)
      return true
    case kVK_UpArrow where mods.contains(.command) || mods.contains(.option), kVK_PageUp:
      if !items.isEmpty { select(0, scroll: true) }
      return true
    case kVK_UpArrow:
      move(-1)
      return true
    case kVK_Return, kVK_ANSI_KeypadEnter:
      activateSelection()
      return true
    case kVK_Escape:
      close()
      return true
    case kVK_Delete where mods == [.option]:
      deleteSelected()
      return true
    case kVK_Delete where mods.isSuperset(of: [.option, .command]):
      if let clear = footer.first(where: { $0.confirmation != nil }) { runFooter(clear) }
      return true
    default:
      break
    }

    let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
    if mods == [.control], ["n", "j", "p", "k"].contains(chars) {
      move(chars == "n" || chars == "j" ? 1 : -1)
      return true
    }
    if mods == [.command] {
      let digitKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
      if let n = digitKeys.firstIndex(of: Int(event.keyCode)) {
        if n < items.count {
          select(n, scroll: true, preview: false)
          activateSelection()
        }
        return true
      }
      if chars == "q" {
        NSApp.terminate(nil)
        return true
      }
    }
    return false
  }
}
