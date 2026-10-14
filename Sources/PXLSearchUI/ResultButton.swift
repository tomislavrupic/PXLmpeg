import AppKit

@MainActor final class ResultButton: NSButton {
  let resultID: UUID
  private let selected: Bool
  init(result: SearchResult, selected: Bool, target: AnyObject, action: Selector) {
    resultID = result.id
    self.selected = selected
    super.init(frame: .zero)
    self.target = target
    self.action = action
    title = ""
    isBordered = false
    wantsLayer = true
    layer?.cornerRadius = 8
    updateBackground()
    let image = NSImageView()
    image.imageScaling = .scaleProportionallyUpOrDown
    if let thumbnail = result.thumbnail {
      image.image = NSImage(
        cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
    } else {
      image.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "Thumbnail")
      image.contentTintColor = .tertiaryLabelColor
    }
    image.wantsLayer = true
    image.layer?.backgroundColor = NSColor.black.cgColor
    image.layer?.cornerRadius = 5
    image.layer?.masksToBounds = true
    let name = NSTextField(labelWithString: result.hit.source.lastPathComponent)
    name.font = .systemFont(ofSize: 13, weight: .medium)
    name.lineBreakMode = .byTruncatingMiddle
    let time = NSTextField(labelWithString: Self.time(result.hit.actualTime.seconds))
    time.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    let score = NSTextField(labelWithString: String(format: "Similarity %.3f", result.hit.score))
    score.font = .systemFont(ofSize: 11)
    score.textColor = .secondaryLabelColor
    let labels = NSStackView(views: [name, time, score])
    labels.orientation = .vertical
    labels.alignment = .leading
    labels.spacing = 5
    labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    for view in [image, labels] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 94),
      image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      image.centerYAnchor.constraint(equalTo: centerYAnchor),
      image.widthAnchor.constraint(equalToConstant: 128),
      image.heightAnchor.constraint(equalToConstant: 76),
      labels.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 12),
      labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      labels.centerYAnchor.constraint(equalTo: centerYAnchor),
      name.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor),
    ])
    toolTip =
      result.thumbnailError
      ?? "Play \(result.hit.source.lastPathComponent) at \(Self.time(result.hit.actualTime.seconds))"
    setAccessibilityLabel(
      "\(result.hit.source.lastPathComponent), \(Self.time(result.hit.actualTime.seconds)), similarity \(String(format: "%.3f", result.hit.score)). Play this moment."
    )
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(result:)") }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateBackground()
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateBackground()
  }
  private func updateBackground() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor =
        (selected
        ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3)
        : NSColor.controlBackgroundColor).cgColor
    }
  }
  override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
  static func time(_ seconds: Double) -> String {
    let milliseconds = Int64((max(0, seconds) * 1000).rounded())
    return String(
      format: "%02lld:%02lld.%03lld", milliseconds / 60_000, milliseconds / 1000 % 60,
      milliseconds % 1000)
  }
}
