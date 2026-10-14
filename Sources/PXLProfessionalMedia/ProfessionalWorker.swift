import AVFoundation
import CoreMedia
import Foundation
import PXLAppleMedia
import PXLMedia

/// Mutable members are accessed only by ProfessionalMediaSession.queue, including teardown.
final class ProfessionalWorker: @unchecked Sendable {
  let source: ProfessionalSource
  let options: ProfessionalMediaOptions
  let budget: MediaBudget
  private var decoder: ProResDecoder?
  private var reader: AVAssetReader?
  private var output: AVAssetReaderTrackOutput?
  private var audio: PCMReader?
  private var target: CMTime = .zero
  private var previousPTS: CMTime?
  private var failed: Error?
  private var hardware = false
  private var videoCount = 0, audioCount = 0
  private let packetLimit = ProfessionalLimits.packetBytes

  init(source: ProfessionalSource, options: ProfessionalMediaOptions) {
    self.source = source
    self.options = options
    budget = MediaBudget(
      limit: options.memoryBudgetBytes, frameLimit: options.maximumRetainedVideoFrames)
  }
  func start(at target: CMTime) throws {
    try source.checkIdentity()
    closeReaders()
    self.target = target
    previousPTS = nil
    // ProRes is intra-frame; no delayed/temporal decoding flags or queued frame history.
    if decoder == nil {
      decoder = try ProResDecoder(source: source, policy: options.hardwarePolicy)
      hardware = decoder!.hardware
    }
    if target < source.videoRange.end {
      let reader = try AVAssetReader(asset: source.asset)
      let output = AVAssetReaderTrackOutput(track: source.video, outputSettings: nil)
      output.alwaysCopiesSampleData = false
      guard reader.canAdd(output) else {
        throw MediaError(.unsupportedMedia, stage: "prores-read", "Compressed output unavailable")
      }
      reader.add(output)
      let start = max(target, source.videoRange.start)
      reader.timeRange = CMTimeRange(start: start, end: source.videoRange.end)
      guard reader.startReading() else { throw readFailure(reader) }
      self.reader = reader
      self.output = output
    }
    if let end = source.descriptor.audioStart, let duration = source.descriptor.audioDuration,
      target
        < CMTimeAdd(
          CMTime(value: end.value, timescale: end.timescale),
          CMTime(value: duration.value, timescale: duration.timescale))
    {
      audio = try PCMReader(source: source, budget: budget, target: target)
    }
  }
  func nextVideo(generation: UInt64, check: () throws -> Void) throws -> ProfessionalVideoFrame? {
    try requireHealthy()
    try source.checkIdentity()
    try check()
    guard let output, let reader, let decoder else { return nil }
    let frameHold = try budget.reserve(bytes: decoder.reservedFrameBytes, kind: .frame)
    let packetHold = try budget.reserve(bytes: packetLimit, kind: .bytes)
    defer { packetHold.release() }
    var markers = 0
    while true {
      try check()
      guard let sample = output.copyNextSampleBuffer() else {
        if reader.status == .failed { throw readFailure(reader) }
        return nil
      }
      if CMSampleBufferGetNumSamples(sample) == 0 {
        guard CMSampleBufferGetTotalSampleSize(sample) == 0,
          CMSampleBufferGetDuration(sample) == .zero, markers < 32
        else {
          throw MediaError(
            .unsupportedMedia, stage: "prores-read", "Invalid/excessive empty media markers")
        }
        markers += 1
        continue
      }
      let pts = CMSampleBufferGetOutputPresentationTimeStamp(sample)
      let duration = CMSampleBufferGetOutputDuration(sample)
      guard CMSampleBufferGetNumSamples(sample) == 1,
        CMSampleBufferGetTotalSampleSize(sample) > 0,
        CMSampleBufferGetTotalSampleSize(sample) <= packetLimit,
        let format = CMSampleBufferGetFormatDescription(sample),
        CMFormatDescriptionEqual(format, otherFormatDescription: source.format),
        pts.isNumeric, pts >= .zero, duration.isNumeric, duration > .zero,
        previousPTS.map({ pts > $0 }) ?? true
      else {
        throw MediaError(
          .timingViolation, stage: "prores-read",
          "Invalid ProRes sample: count=\(CMSampleBufferGetNumSamples(sample)), bytes=\(CMSampleBufferGetTotalSampleSize(sample)), pts=\(pts), duration=\(duration), matchingFormat=\(CMSampleBufferGetFormatDescription(sample).map { CMFormatDescriptionEqual($0, otherFormatDescription: source.format) } ?? false)"
        )
      }
      previousPTS = pts
      if pts < target { continue }
      let pixel = try decoder.decode(sample)
      try source.checkIdentity()
      try check()
      videoCount += 1
      return try ProfessionalVideoFrame(
        pixel: pixel, pts: pts, duration: duration,
        generation: generation, reservation: frameHold)
    }
  }
  func nextAudio(maximumFrames: Int, generation: UInt64, check: () throws -> Void) throws
    -> ProfessionalAudioChunk?
  {
    try requireHealthy()
    try source.checkIdentity()
    try check()
    let chunk = try audio?.next(maximumFrames: maximumFrames, generation: generation, check: check)
    try source.checkIdentity()
    try check()
    audioCount += chunk?.frameCount ?? 0
    return chunk
  }
  func metrics() -> ProfessionalMediaMetrics {
    ProfessionalMediaMetrics(
      decoderHardware: hardware, ownedMemoryBytes: budget.current,
      ownedMemoryPeakBytes: budget.peak, retainedVideoFrames: budget.frameCount,
      deliveredVideoFrames: videoCount, deliveredAudioFrames: audioCount)
  }
  func fail(_ error: Error) {
    failed = error
    close()
  }
  func requireHealthy() throws { if let failed { throw failed } }
  private func closeReaders() {
    reader?.cancelReading()
    reader = nil
    output = nil
    audio?.close()
    audio = nil
  }
  func close() {
    closeReaders()
    decoder = nil
  }
  private func readFailure(_ reader: AVAssetReader) -> MediaError {
    MediaError(.ioFailure, stage: "prores-read", "\(String(describing: reader.error))")
  }
}
