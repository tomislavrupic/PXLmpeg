import AppKit

/// App-only presentation tokens. The media and analysis libraries have no UI dependency.
@MainActor enum SearchStyle {
  static let background = colour(0x0A0B0C)
  static let panel = colour(0x111315)
  static let raised = colour(0x191C1F)
  static let line = colour(0x292D31)
  static let text = colour(0xF0F1ED)
  static let secondary = colour(0xA5AAA8)
  static let accent = colour(0x9CE8DB)
  private static func colour(_ hex: UInt32) -> NSColor {
    NSColor(
      srgbRed: CGFloat((hex >> 16) & 255) / 255,
      green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
  }
  static func caption(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
    label.textColor = secondary
    return label
  }
  static func symbol(_ name: String, description: String) -> NSImageView {
    let view = NSImageView(
      image: NSImage(
        systemSymbolName: name,
        accessibilityDescription: description) ?? NSImage())
    view.contentTintColor = accent
    view.imageScaling = .scaleProportionallyUpOrDown
    return view
  }
}

/// Lightweight vector identity for unbundled CLI launches; no image loading or model work.
@MainActor final class SearchBrandMark: NSView {
  private let artwork = Bundle.main.url(forResource: "PXLmpeg", withExtension: "icns")
    .flatMap { NSImage(contentsOf: $0) }
  override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 44) }
  override func draw(_ dirtyRect: NSRect) {
    if let artwork {
      artwork.draw(in: bounds)
      return
    }
    SearchStyle.raised.setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    for (x, y, alpha) in [
      (10.0, 24.0, 1.0), (24.0, 24.0, 0.4),
      (10.0, 10.0, 0.7), (24.0, 10.0, 1.0),
    ] {
      SearchStyle.accent.withAlphaComponent(alpha).setFill()
      NSBezierPath(
        roundedRect: NSRect(x: x, y: y, width: 10, height: 10),
        xRadius: 2, yRadius: 2
      ).fill()
    }
  }
}
