import AppKit

/// Maccy's hover preview: full text or a larger image, then source app, copy times and count.
final class PreviewViewController: NSViewController {
  static let decodeQueue = DispatchQueue(label: "clipkeep.preview", qos: .userInitiated)
  static let maxWidth: CGFloat = 480

  static func maxImageSize(on screen: NSScreen?) -> NSSize {
    let visible = (screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
    return NSSize(width: min(maxWidth, visible.width / 2), height: visible.height / 2)
  }

  private let item: ClipItem
  private let image: CGImage?
  private let scale: CGFloat

  /// `image` is decoded by the caller off the main thread.
  init(item: ClipItem, image: CGImage?, scale: CGFloat) {
    self.item = item
    self.image = image
    self.scale = scale
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Explicit frames matching Maccy's PreviewItemView: `.padding()` (16pt), a divider with `.padding(.vertical)`,
  /// metadata lines in the body font, and `.padding(.bottom)` before the shortcut hint.
  override func loadView() {
    let pad: CGFloat = 16
    let root = FlippedView()

    let content: NSView
    if item.kind == .image, let cg = image {
      let size = NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale)
      let imageView = NSImageView(image: NSImage(cgImage: cg, size: size))
      imageView.wantsLayer = true
      imageView.layer?.cornerRadius = 5
      imageView.layer?.masksToBounds = true
      imageView.frame.size = size
      content = imageView
    } else {
      content = Self.textView(item.previewText, maxWidth: Self.maxWidth, maxHeight: 400)
    }

    let lines = metadataLines()
    let width = max(content.frame.width, lines.map(\.frame.width).max() ?? 0)
    var y = pad
    content.frame.origin = NSPoint(x: pad, y: y)
    root.addSubview(content)
    y += content.frame.height + pad

    let divider = SeparatorView(frame: NSRect(x: pad, y: y, width: width, height: 1))
    root.addSubview(divider)
    y += 1 + pad

    for (index, line) in lines.enumerated() {
      if index == lines.count - 1 { y += pad } // gap before the shortcut hint
      line.frame.origin = NSPoint(x: pad - 2, y: y) // labels draw with a 2pt inset; align text with the content
      root.addSubview(line)
      y += line.frame.height
    }
    root.frame = NSRect(x: 0, y: 0, width: width + 2 * pad, height: y + pad)
    preferredContentSize = root.frame.size
    view = root
  }

  private func metadataLines() -> [NSView] {
    func label(_ text: String) -> NSTextField {
      let label = NSTextField(labelWithString: text)
      label.font = Style.font
      label.sizeToFit()
      return label
    }
    var lines: [NSView] = []
    if let bundleID = item.application {
      let row = FlippedView()
      let prefix = label("Application:")
      var x = prefix.frame.width + 3
      row.addSubview(prefix)
      if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.frame = NSRect(x: x, y: (prefix.frame.height - 11) / 2, width: 11, height: 11)
        row.addSubview(icon)
        x += 11 + 3
      }
      let name = label(Self.applicationName(bundleID))
      name.frame.origin.x = x
      row.addSubview(name)
      row.frame.size = NSSize(width: x + name.frame.width, height: prefix.frame.height)
      lines.append(row)
    }
    lines.append(label("First copy time: \(Self.format(item.firstCopiedAt))"))
    lines.append(label("Last copy time: \(Self.format(item.lastCopiedAt))"))
    lines.append(label("Number of copies: \(item.numberOfCopies)"))
    lines.append(label("Press ⌥⌫ to delete."))
    return lines
  }

  /// Wrapped, non-editable text sized to its content; scrolls when taller than `maxHeight`.
  private static func textView(_ string: String, maxWidth: CGFloat, maxHeight: CGFloat) -> NSView {
    let textView = NSTextView()
    textView.isEditable = false
    textView.isSelectable = false
    textView.drawsBackground = false
    textView.font = Style.font
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.containerSize = NSSize(width: maxWidth, height: .greatestFiniteMagnitude)
    textView.string = string
    guard let container = textView.textContainer, let layout = textView.layoutManager else { return textView }
    layout.ensureLayout(for: container)
    let used = layout.usedRect(for: container).size
    // usedRect spans the full container when the text ends in a newline; measure the real lines instead.
    var lineWidth: CGFloat = 0
    layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, usedRect, _, _, _ in
      lineWidth = max(lineWidth, usedRect.width)
    }
    let width = max(ceil(lineWidth), 1)
    container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    textView.frame = NSRect(x: 0, y: 0, width: width, height: ceil(used.height))

    guard used.height > maxHeight else { return textView }
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: maxHeight))
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.documentView = textView
    return scroll
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    view.window?.sharingType = .none // set before the first frame is drawn
  }

  /// Maccy shows `Text(date, style: .date)` followed by `Text(date, style: .time)`.
  private static func format(_ date: Date) -> String {
    "\(date.formatted(date: .long, time: .omitted)) \(date.formatted(date: .omitted, time: .shortened))"
  }

  private static func applicationName(_ bundleID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
    return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
  }
}
