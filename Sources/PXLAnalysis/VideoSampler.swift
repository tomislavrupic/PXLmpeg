import AVFoundation
import CoreGraphics
import PXLAppleMedia
import PXLMedia

struct TimedImage: Sendable {
  let image: CGImage
  let actualTime: MediaTime
}
actor VideoSampler {
  nonisolated let backend: String
  private let assumed: AssumedColourSampler?
  let descriptor: AssetDescriptor
  let videoStartSeconds: Double
  let videoEndSeconds: Double
  private let sourceAsset: AVAsset
  private var active = false
  init(source: URL, colourPolicy: InputColourPolicy) async throws {
    try Task.checkCancellation()
    let input = try await AssetInput.open(
      source, colourPolicy: colourPolicy, trackPolicy: .readOnly)
    let range = input.videoTimeRange
    if input.descriptor.effectiveColourSpace == .bt709 {
      assumed = AssumedColourSampler(input: input)
      backend =
        input.descriptor.colour.contains("explicitly assumed")
        ? "nativeVT-explicitBT709" : "nativeVT-BT709"
    } else {
      assumed = nil
      backend = "assetImageGenerator-forceSDR"
    }
    descriptor = input.descriptor
    videoStartSeconds = range.start.seconds
    videoEndSeconds = range.end.seconds
    sourceAsset = input.asset
  }
  func sample(seconds: Double) async throws -> TimedImage {
    try Task.checkCancellation()
    guard !active, seconds.isFinite, seconds >= videoStartSeconds, seconds < videoEndSeconds else {
      throw analysisError("Invalid or concurrent frame request")
    }
    active = true
    defer { active = false }
    if let assumed { return try await assumed.sample(seconds: seconds) }
    let requested = CMTime(seconds: seconds, preferredTimescale: 600_000)
    let generator = NativeImageGenerator(
      asset: sourceAsset, maximumSize: CGSize(width: 1024, height: 1024))
    let preview = try await generator.image(at: requested)
    let sample = TimedImage(image: preview.image, actualTime: preview.actualTime)
    try Task.checkCancellation()
    return sample
  }
}
