import AVFoundation
import AppKit

/// Direct AppKit presentation. The host owns controls and calls session.close() on teardown.
@MainActor public final class PlaybackView: NSView {
  private let presentation: AVPlayerLayer
  public init(session: PlaybackSession) {
    presentation = AVPlayerLayer(player: session.player)
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    presentation.videoGravity = .resizeAspect
    layer?.addSublayer(presentation)
    setAccessibilityLabel("Video preview")
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(session:)") }
  public override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    presentation.frame = bounds
    CATransaction.commit()
  }
}
