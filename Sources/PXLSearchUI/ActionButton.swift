import AppKit

/// Keep NSButton's native action, keyboard and accessibility behaviour, while drawing
/// explicit foreground/background pairs instead of AppKit's translucent accent bezel.
@MainActor final class ActionButton: NSButton {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isBordered = false
    setButtonType(.momentaryPushIn)
    focusRingType = .exterior
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

  override var intrinsicContentSize: NSSize {
    let label = NSAttributedString(string: title, attributes: [.font: labelFont]).size()
    return NSSize(
      width: ceil(label.width) + (image == nil ? 0 : 22) + 28,
      height: controlSize == .large ? 34 : 28)
  }
  private var labelFont: NSFont { .systemFont(ofSize: 13, weight: .medium) }
  override var isEnabled: Bool { didSet { needsDisplay = true } }

  override func draw(_ dirtyRect: NSRect) {
    let foreground = isEnabled ? SearchStyle.background : SearchStyle.secondary
    let pressed = cell?.isHighlighted == true
    let background =
      isEnabled
      ? (pressed ? SearchStyle.accent.blended(withFraction: 0.15, of: .black)! : SearchStyle.accent)
      : SearchStyle.raised
    let outline = NSBezierPath(
      roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
    background.setFill()
    outline.fill()
    (isEnabled ? SearchStyle.accent : SearchStyle.line).setStroke()
    outline.lineWidth = 1
    outline.stroke()
    let label = NSAttributedString(
      string: title,
      attributes: [.font: labelFont, .foregroundColor: foreground])
    let size = label.size()
    let iconWidth: CGFloat = image == nil ? 0 : 22
    let left = (bounds.width - size.width - iconWidth) / 2
    if let image {
      let tinted = image.withSymbolConfiguration(.init(hierarchicalColor: foreground)) ?? image
      tinted.draw(
        in: NSRect(x: left, y: (bounds.height - 15) / 2, width: 15, height: 15),
        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    label.draw(at: NSPoint(x: left + iconWidth, y: (bounds.height - size.height) / 2))
  }
  override var focusRingMaskBounds: NSRect { bounds }
  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
  }
}
