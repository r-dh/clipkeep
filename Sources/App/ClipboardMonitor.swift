import AppKit

/// macOS has no clipboard-changed notification, so poll the change counter like Maccy does.
/// Only the counter is read on each tick; contents are read once per actual change.
@MainActor
final class ClipboardMonitor {
  var onCapture: ((ClipItem) -> Void)?
  var isPaused = false

  private let pasteboard = NSPasteboard.general
  private var changeCount: Int
  private var pending = false
  private var emptyTicks = 0
  private var timer: Timer?

  init() {
    changeCount = pasteboard.changeCount
  }

  func start() {
    let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll() }
    }
    timer.tolerance = 0.2
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func poll() {
    let current = pasteboard.changeCount
    // Only clearContents() bumps the counter; the writer's data (and a concealed marker) can follow later
    // without another bump. So read one tick after the change, and keep waiting while it is still empty.
    if current != changeCount {
      changeCount = current
      // Decide on pause now: resuming must not record a copy made while paused.
      pending = !isPaused
      emptyTicks = 0
      return
    }
    guard pending else { return }
    guard !isPaused else {
      pending = false
      return
    }

    // Decide on the declared types alone, so concealed data (passwords) is never read.
    let allTypes = (pasteboard.types ?? []).map(\.rawValue)
    guard !allTypes.isEmpty else {
      // Cleared and never refilled (e.g. a password manager's timeout): stop asking after ~2s.
      emptyTicks += 1
      if emptyTicks >= 4 { pending = false }
      return
    }
    pending = false
    guard !CapturePolicy.shouldIgnore(types: allTypes),
          let pbItems = pasteboard.pasteboardItems, !pbItems.isEmpty else { return }
    // Per-item types can differ from the union above (Maccy #241), so check them too.
    let itemTypes = pbItems.map { $0.types.map(\.rawValue) }
    guard !itemTypes.contains(where: CapturePolicy.shouldIgnore) else { return }

    let contents = CapturePolicy.collect(itemTypes: itemTypes) { index, type in
      pbItems[index].data(forType: NSPasteboard.PasteboardType(type))
    }
    // Another copy landed while reading: drop this mix, the next tick records the new one.
    guard pasteboard.changeCount == current else { return }

    let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    if let item = CapturePolicy.makeItem(contents: contents, application: app, now: Date()) {
      onCapture?(item)
    }
  }

  func write(_ item: ClipItem) {
    // Record a copy made elsewhere moments ago before overwriting it, instead of waiting for the next tick.
    if pasteboard.changeCount != changeCount {
      changeCount = pasteboard.changeCount
      pending = true
    }
    if pending { poll() }
    pasteboard.clearContents()
    for content in item.contents where content.type != PBType.fileURL {
      pasteboard.setData(content.data, forType: NSPasteboard.PasteboardType(content.type))
    }
    // Separate pasteboard items so pasting several files works (same approach as Maccy).
    let files = item.contents.filter { $0.type == PBType.fileURL }.map { content -> NSPasteboardItem in
      let pbItem = NSPasteboardItem()
      pbItem.setData(content.data, forType: .fileURL)
      return pbItem
    }
    if !files.isEmpty { pasteboard.writeObjects(files) }
    changeCount = pasteboard.changeCount
    pending = false
  }
}
