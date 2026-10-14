import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import PXLAppleMedia
import PXLMedia

final class PCMReader {
  private let reader: AVAssetReader
  private let output: AVAssetReaderTrackOutput
  private let channels: Int
  private let budget: MediaBudget
  private let target: CMTime
  private var pending: CMSampleBuffer?
  private var pendingReservation: Reservation?
  private var offset = 0
  private var previousEnd: CMTime?
  private let pendingLimit = 1024 * 1024

  init(source: ProfessionalSource, budget: MediaBudget, target: CMTime) throws {
    guard let track = source.audio, let count = source.descriptor.audioChannels else {
      throw MediaError(.invalidRequest, stage: "pcm-read", "No PCM track")
    }
    channels = count
    self.budget = budget
    self.target = target
    reader = try AVAssetReader(asset: source.asset)
    output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
      ])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      throw MediaError(.unsupportedMedia, stage: "pcm-read", "PCM conversion unavailable")
    }
    reader.add(output)
    // Narrow native reads to the requested audio range, then round/trim explicitly.
    if let start = source.descriptor.audioStart, let duration = source.descriptor.audioDuration {
      let end = CMTimeAdd(
        CMTime(value: start.value, timescale: start.timescale),
        CMTime(value: duration.value, timescale: duration.timescale))
      reader.timeRange = CMTimeRange(
        start: max(target, CMTime(value: start.value, timescale: start.timescale)), end: end)
    }
    guard reader.startReading() else { throw failure() }
  }
  func next(maximumFrames: Int, generation: UInt64, check: () throws -> Void) throws
    -> ProfessionalAudioChunk?
  {
    // Reserve the delivery allocation before advancing the native source.
    let reservation = try budget.reserve(bytes: maximumFrames * channels * 4, kind: .bytes)
    var markers = 0
    while true {
      try check()
      if pending == nil {
        let hold = try budget.reserve(bytes: pendingLimit, kind: .bytes)
        guard let sample = output.copyNextSampleBuffer() else {
          if reader.status == .failed { throw failure() }
          return nil
        }
        if CMSampleBufferGetNumSamples(sample) == 0 {
          guard CMSampleBufferGetTotalSampleSize(sample) == 0,
            CMSampleBufferGetDuration(sample) == .zero, markers < 32
          else {
            throw MediaError(
              .unsupportedMedia, stage: "pcm-read", "Invalid/excessive empty media markers")
          }
          markers += 1
          continue
        }
        let pts = CMSampleBufferGetOutputPresentationTimeStamp(sample)
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, frames <= pendingLimit / (channels * 4), pts.isNumeric, pts >= .zero,
          let format = CMSampleBufferGetFormatDescription(sample),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
          asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate == 48000,
          Int(asbd.mChannelsPerFrame) == channels, asbd.mBitsPerChannel == 32,
          asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
          asbd.mFormatFlags & (kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsBigEndian) == 0,
          asbd.mBytesPerFrame == channels * 4,
          CMSampleBufferGetTotalSampleSize(sample) == frames * channels * 4
        else {
          throw MediaError(
            .unsupportedMedia, stage: "pcm-read", "Invalid/unbounded PCM output buffer")
        }
        if let previousEnd, pts < previousEnd {
          throw MediaError(.timingViolation, stage: "pcm-read", "Overlapping PCM timestamps")
        }
        previousEnd = CMTimeAdd(pts, CMTime(value: Int64(frames), timescale: 48000))
        let skipped = CMTimeConvertScale(
          CMTimeSubtract(target, pts), timescale: 48000, method: .roundTowardPositiveInfinity)
        offset = skipped.value > 0 ? Int(min(Int64(frames), skipped.value)) : 0
        if offset == frames { continue }
        pending = sample
        pendingReservation = hold
      }
      guard let sample = pending, let block = CMSampleBufferGetDataBuffer(sample) else {
        throw failure()
      }
      let count = min(maximumFrames, CMSampleBufferGetNumSamples(sample) - offset)
      let pts = CMTimeAdd(
        CMSampleBufferGetOutputPresentationTimeStamp(sample),
        CMTime(value: Int64(offset), timescale: 48000))
      var data = Data(count: count * channels * 4)
      let status = data.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(
          block, atOffset: offset * channels * 4,
          dataLength: $0.count, destination: $0.baseAddress!)
      }
      try checkVT(status, stage: "pcm-copy")
      offset += count
      if offset == CMSampleBufferGetNumSamples(sample) {
        pending = nil
        pendingReservation = nil
      }
      try check()
      return try ProfessionalAudioChunk(
        samples: data, frames: count, channels: channels,
        pts: pts, generation: generation, reservation: reservation)
    }
  }
  private func failure() -> MediaError {
    MediaError(.ioFailure, stage: "pcm-read", "\(String(describing: reader.error))")
  }
  func close() {
    reader.cancelReading()
    pending = nil
    pendingReservation = nil
  }
  deinit { reader.cancelReading() }
}
