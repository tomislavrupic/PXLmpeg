import AVFoundation
import CoreMedia
import PXLMedia

package struct EncodedSample {
  package let buffer: CMSampleBuffer
  package let sequence: Int
  package var bytes: Int { CMSampleBufferGetTotalSampleSize(buffer) }
  package var pts: CMTime { CMSampleBufferGetOutputPresentationTimeStamp(buffer) }
  package var duration: CMTime { CMSampleBufferGetOutputDuration(buffer) }
  package init(buffer: CMSampleBuffer, sequence: Int) {
    self.buffer = buffer
    self.sequence = sequence
  }
}
package final class SampleReader {
  private let reader: AVAssetReader
  private let video: AVAssetReaderTrackOutput
  private let audio: AVAssetReaderTrackOutput?
  private let videoFormat: CMVideoFormatDescription
  private let audioFormat: CMAudioFormatDescription?
  private var previousPTS: CMTime?
  private var previousDTS: CMTime?
  private var hasDTS: Bool?
  private var videoCount = 0
  private var audioCount = 0
  package init(input: AssetInput, audioPolicy: AudioPolicy) throws {
    reader = try AVAssetReader(asset: input.asset)
    video = AVAssetReaderTrackOutput(track: input.video, outputSettings: nil)
    video.alwaysCopiesSampleData = false
    videoFormat = input.videoFormat
    audioFormat = input.audioFormat
    reader.add(video)
    if audioPolicy == .copy, let track = input.audio {
      let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
      output.alwaysCopiesSampleData = false
      reader.add(output)
      audio = output
    } else {
      audio = nil
    }
    guard reader.startReading() else {
      throw MediaError(.ioFailure, stage: "read", "\(String(describing: reader.error))")
    }
  }
  package func nextVideo() throws -> EncodedSample? {
    guard let sample = try next(video) else { return nil }
    let pts = CMSampleBufferGetOutputPresentationTimeStamp(sample)
    let dts = CMSampleBufferGetOutputDecodeTimeStamp(sample)
    let duration = CMSampleBufferGetOutputDuration(sample)
    guard CMSampleBufferGetNumSamples(sample) == 1, pts.isNumeric, pts >= .zero,
      duration.isNumeric, duration > .zero,
      hasDTS.map({ $0 == dts.isValid }) ?? true,
      dts.isValid
        ? (dts.isNumeric && (previousDTS.map({ dts > $0 }) ?? true))
        : (previousPTS.map({ pts > $0 }) ?? true)
    else {
      throw MediaError(
        .timingViolation, stage: "read",
        "Invalid/discontinuous decode timing at sample \(videoCount)")
    }
    hasDTS = dts.isValid
    previousDTS = dts.isValid ? dts : nil
    guard let format = CMSampleBufferGetFormatDescription(sample),
      CMFormatDescriptionEqual(format, otherFormatDescription: videoFormat)
    else {
      throw MediaError(.unsupportedMedia, stage: "read", "Midstream video format change")
    }
    previousPTS = pts
    defer { videoCount += 1 }
    return EncodedSample(buffer: sample, sequence: videoCount)
  }
  package func nextAudio() throws -> EncodedSample? {
    guard let audio, let sample = try next(audio) else { return nil }
    guard let format = CMSampleBufferGetFormatDescription(sample), let audioFormat,
      CMFormatDescriptionEqual(format, otherFormatDescription: audioFormat)
    else {
      throw MediaError(.unsupportedMedia, stage: "read", "Midstream audio format change")
    }
    defer { audioCount += 1 }
    return EncodedSample(buffer: sample, sequence: audioCount)
  }
  private func next(_ output: AVAssetReaderTrackOutput) throws -> CMSampleBuffer? {
    var sample = output.copyNextSampleBuffer()
    var markers = 0
    while let s = sample, CMSampleBufferGetNumSamples(s) == 0 {
      guard CMSampleBufferGetTotalSampleSize(s) == 0, CMSampleBufferGetDuration(s) == .zero,
        markers < 32
      else {
        throw MediaError(
          .unsupportedMedia, stage: "read", "Invalid or excessive empty sample markers")
      }
      markers += 1
      sample = output.copyNextSampleBuffer()
    }
    if sample == nil, reader.status == .failed {
      throw MediaError(.ioFailure, stage: "read", "\(String(describing: reader.error))")
    }
    if let sample, CMSampleBufferGetTotalSampleSize(sample) > 8 * 1024 * 1024 {
      throw MediaError(.resourceLimit, stage: "read", "Compressed packet exceeds 8 MiB")
    }
    return sample
  }
  package func cancel() { reader.cancelReading() }
}
