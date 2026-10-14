import AVFoundation
import CoreImage
import ImageIO
import PXLAppleMedia
import PXLMedia

private final class SampleCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  func cancel() { lock.withLock { cancelled = true } }
  func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}

/// All mutable reader/decoder/lease state is confined to queue. Native synchronous
/// VideoToolbox calls must not occupy Swift's cooperative executor. AssetInput is
/// immutable loaded metadata; results cross the queue only as immutable CGImages.
final class AssumedColourSampler: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "studio.pixelrecords.pxlmpeg.semantic-decode", qos: .utility)
  private let input: AssetInput
  private var reader: SampleReader?
  private var decoder: VideoDecoder?
  private var ordered: OrderedVideoReader?
  private let cursor = DecodedFrameCursor()
  private var context: CIContext?
  init(input: AssetInput) { self.input = input }

  func sample(seconds: Double) async throws -> TimedImage {
    try Task.checkCancellation()
    let cancellation = SampleCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async { [self] in
          do {
            continuation.resume(returning: try read(seconds: seconds, cancellation: cancellation))
          } catch {
            reset()
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
  }
  private func read(seconds: Double, cancellation: SampleCancellation) throws -> TimedImage {
    try cancellation.check()
    if ordered == nil {
      let depth = input.descriptor.maxReorderFrames ?? 16
      let budget = MediaBudget(limit: 256 * 1024 * 1024, frameLimit: depth + 1)
      let reader = try SampleReader(input: input, audioPolicy: .drop)
      self.reader = reader
      let decoder = try VideoDecoder(format: input.videoFormat, contract: input.contract)
      self.reader = reader
      self.decoder = decoder
      ordered = try OrderedVideoReader(
        reader: reader, decoder: decoder, budget: budget, reorderDepth: depth)
      context = CIContext(options: [.cacheIntermediates: false])
    }
    let requested = CMTime(seconds: seconds, preferredTimescale: 600_000)
    let frame = try cursor.select(at: requested) {
      try cancellation.check()
      return try ordered!.next(check: cancellation.check)
    }
    // VideoDecoder applies input.contract to the decoded NV12 surface, including
    // the explicit matrix/primaries/transfer assumption, before any RGB conversion.
    let orientation: CGImagePropertyOrientation
    switch input.descriptor.rotation ?? .none {
    case .none: orientation = .up
    case .clockwise90: orientation = .right
    case .upsideDown: orientation = .down
    case .clockwise270: orientation = .left
    }
    let image = CIImage(
      cvPixelBuffer: frame.pixel, options: [.colorSpace: CGColorSpace(name: CGColorSpace.itur_709)!]
    ).oriented(orientation)
    let scale = min(1, 1024 / max(image.extent.width, image.extent.height))
    let resized = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    try cancellation.check()
    guard
      let rgb = context!.createCGImage(
        resized, from: resized.extent, format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    else {
      throw analysisError("Cannot convert explicitly tagged decoded frame")
    }
    try cancellation.check()
    return TimedImage(
      image: rgb, actualTime: try MediaTime(value: frame.pts.value, timescale: frame.pts.timescale))
  }
  private func reset() {
    cursor.reset()
    ordered?.cancel()
    reader?.cancel()
    ordered = nil
    reader = nil
    decoder = nil
    context = nil
  }
  deinit {
    ordered?.cancel()
    reader?.cancel()
  }
}
