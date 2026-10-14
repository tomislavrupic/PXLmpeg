import AVFoundation
import CoreGraphics
import PXLAnalysis
import PXLMedia

struct PreviewImage: Sendable {
  let image: CGImage
  let actualTime: MediaTime
}

/// Native preview derivatives, distinct from model-input pixels; one request per actor.
actor ThumbnailRenderer {
  private var active = false
  func image(source: URL, at time: MediaTime) async throws -> PreviewImage {
    try Task.checkCancellation()
    guard !active else {
      throw MediaError(.engineBusy, stage: "thumbnail", "Thumbnail request already active")
    }
    active = true
    defer { active = false }
    let generator = NativeImageGenerator(
      asset: AVURLAsset(url: source), maximumSize: CGSize(width: 320, height: 180))
    let preview = try await generator.image(
      at: CMTime(value: time.value, timescale: time.timescale))
    try Task.checkCancellation()
    return PreviewImage(image: preview.image, actualTime: preview.actualTime)
  }
}
