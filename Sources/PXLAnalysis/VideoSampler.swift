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
  private let generator: AVAssetImageGenerator
  private var active = false
  init(source: URL, colourPolicy: InputColourPolicy) async throws {
    try Task.checkCancellation()
    let input = try await AssetInput.open(source, colourPolicy: colourPolicy)
    let range = try await input.video.load(.timeRange)
    guard range.start.isNumeric, range.end.isNumeric, range.start >= .zero, range.end > range.start
    else {
      throw analysisError("Invalid video time range")
    }
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
    generator = AVAssetImageGenerator(asset: input.asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    generator.dynamicRangePolicy = .forceSDR
    generator.maximumSize = CGSize(width: 1024, height: 1024)
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
    let sample: TimedImage = try await withCheckedThrowingContinuation { continuation in
      generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: requested)]) {
        _, image, time, result, error in
        do {
          guard result == .succeeded, let image, time.isNumeric else {
            throw error ?? analysisError("Native image extraction failed")
          }
          continuation.resume(
            returning: TimedImage(
              image: image, actualTime: try MediaTime(value: time.value, timescale: time.timescale))
          )
        } catch { continuation.resume(throwing: error) }
      }
    }
    try Task.checkCancellation()
    return sample
  }
}
