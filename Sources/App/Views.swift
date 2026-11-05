import AppKit

/// Metrics copied from Maccy 2.6.1 (Popup.swift, ListItemView.swift, SearchFieldView.swift) for macOS 26.
enum Style {
  static let width: CGFloat = 450
  static let maxHeight: CGFloat = 800
  static let padding: CGFloat = 5
  static let itemHeight: CGFloat = 24
  static let cornerRadius: CGFloat = 6
  static let imageMaxHeight: CGFloat = 40
  static let imageMaxWidth: CGFloat = 340
  static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
  static let boldFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
}

class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

func makeLabel(_ string: String = "", color: NSColor = .labelColor) -> NSTextField {
  let label = NSTextField(labelWithString: string)
  label.font = Style.font
  label.textColor = color
  label.lineBreakMode = .byTruncatingMiddle
  label.maximumNumberOfLines = 1
  label.cell?.usesSingleLineMode = true
  return label
}

/// One selectable line: history entry or footer action. Selection is drawn like Maccy's (accent at 80%).
final class RowView: FlippedView {
  var onHover: (() -> Void)?
  var onClick: (() -> Void)?

  var isSelected = false {
    didSet {
      guard isSelected != oldValue else { return }
      applyColors()
      needsDisplay = true
    }
  }

  private let titleLabel = makeLabel()
  private let modifierLabel = makeLabel()
  private let keyLabel = makeLabel()
  private var imageView: NSImageView?
  private var attributedTitle: NSAttributedString?
  private var trackingArea: NSTrackingArea?

  init(title: String, highlights: [Range<String.Index>] = [], modifiers: String = "", key: String = "", image: CGImage? = nil) {
    super.init(frame: .zero)
    if let image {
      let view = NSImageView()
      let scale = NSScreen.main?.backingScaleFactor ?? 2
      view.image = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
      view.imageScaling = .scaleProportionallyDown
      addSubview(view)
      imageView = view
    } else {
      setTitle(title, highlights: highlights)
      addSubview(titleLabel)
    }
    modifierLabel.stringValue = modifiers
    modifierLabel.alignment = .right
    modifierLabel.lineBreakMode = .byClipping
    keyLabel.stringValue = key
    keyLabel.alignment = .center
    keyLabel.lineBreakMode = .byClipping
    addSubview(modifierLabel)
    addSubview(keyLabel)
    applyColors()
  }

  required init?(coder: NSCoder) { fatalError() }

  var preferredHeight: CGFloat {
    guard let size = imageView?.image?.size else { return Style.itemHeight }
    return max(Style.itemHeight, min(size.height, Style.imageMaxHeight) + 10)
  }

  private func setTitle(_ title: String, highlights: [Range<String.Index>]) {
    guard !highlights.isEmpty else {
      titleLabel.stringValue = title
      return
    }
    // Same as Maccy: highlight within the first 500 characters only.
    let shown = String(title.prefix(500))
    let string = NSMutableAttributedString(string: shown, attributes: [.font: Style.font])
    for range in highlights where range.upperBound <= shown.endIndex {
      string.addAttribute(.font, value: Style.boldFont, range: NSRange(range, in: shown))
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingMiddle
    string.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: string.length))
    attributedTitle = string
  }

  private func applyColors() {
    let color: NSColor = isSelected ? .white : .labelColor
    if let attributedTitle {
      let colored = NSMutableAttributedString(attributedString: attributedTitle)
      colored.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: colored.length))
      titleLabel.attributedStringValue = colored
    } else {
      titleLabel.textColor = color
    }
    modifierLabel.textColor = color.withAlphaComponent(0.7)
    keyLabel.textColor = color.withAlphaComponent(0.7)
  }

  override func layout() {
    super.layout()
    let h = bounds.height
    // Maccy: 55pt modifiers + 12pt key column. NSTextField labels add ~2pt inset per side, hence 16pt here.
    let shortcutWidth: CGFloat = 55 + 16
    let keyX = bounds.width - 8 - 16
    keyLabel.frame = NSRect(x: keyX, y: (h - 16) / 2, width: 16, height: 16)
    modifierLabel.frame = NSRect(x: keyX - 55 + 2, y: (h - 16) / 2, width: 55, height: 16)
    let contentWidth = bounds.width - 10 - 5 - 10 - shortcutWidth
    if let imageView, let size = imageView.image?.size {
      let scale = min(1, Style.imageMaxHeight / size.height, Style.imageMaxWidth / size.width)
      imageView.frame = NSRect(x: 10, y: 5, width: size.width * scale, height: size.height * scale)
    } else {
      titleLabel.frame = NSRect(x: 10, y: (h - 16) / 2, width: contentWidth, height: 16)
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    guard isSelected else { return }
    NSColor.controlAccentColor.withAlphaComponent(0.8).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: Style.cornerRadius, yRadius: Style.cornerRadius).fill()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    // mouseMoved (not mouseEntered) so rows scrolling under a still cursor do not steal keyboard selection.
    let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseMoved(with event: NSEvent) {
    onHover?()
  }

  override var mouseDownCanMoveWindow: Bool { false }

  override func mouseDown(with event: NSEvent) {}

  override func mouseUp(with event: NSEvent) {
    if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
  }
}

/// Rounded search box from Maccy: 10% secondary fill, magnifier, plain text field, clear button.
final class SearchFieldView: NSView {
  let textField = NSTextField()
  private let icon = NSImageView()
  private let clearButton = NSButton()
  var onClear: (() -> Void)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
    icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(config)
    icon.contentTintColor = .labelColor
    icon.alphaValue = 0.8
    addSubview(icon)

    textField.isBordered = false
    textField.isBezeled = false
    textField.drawsBackground = false
    textField.focusRingType = .none
    textField.font = Style.font
    textField.placeholderString = "type to search…"
    textField.cell?.usesSingleLineMode = true
    textField.cell?.isScrollable = true
    textField.isAutomaticTextCompletionEnabled = false
    addSubview(textField)

    clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear search")?.withSymbolConfiguration(config)
    clearButton.isBordered = false
    clearButton.imagePosition = .imageOnly
    clearButton.contentTintColor = .secondaryLabelColor
    clearButton.target = self
    clearButton.action = #selector(clearPressed)
    clearButton.isHidden = true
    addSubview(clearButton)
  }

  required init?(coder: NSCoder) { fatalError() }

  func queryChanged() {
    clearButton.isHidden = textField.stringValue.isEmpty
  }

  @objc private func clearPressed() {
    onClear?()
  }

  override func draw(_ dirtyRect: NSRect) {
    let box = NSRect(x: 0, y: (bounds.height - 23) / 2, width: bounds.width, height: 23)
    NSColor.secondaryLabelColor.withAlphaComponent(0.1).setFill()
    NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
  }

  override func layout() {
    super.layout()
    let midY = bounds.midY
    icon.frame = NSRect(x: 5, y: midY - 7, width: 14, height: 14)
    clearButton.frame = NSRect(x: bounds.width - 5 - 14, y: midY - 7, width: 14, height: 14)
    textField.frame = NSRect(x: 25, y: midY - 8, width: bounds.width - 25 - 24, height: 16)
  }
}

final class SeparatorView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSColor.separatorColor.setFill()
    NSRect(x: 0, y: (bounds.height - 1) / 2, width: bounds.width, height: 1).fill()
  }
}
