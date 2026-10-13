import AVFoundation
import Foundation
import PXLMedia

// All methods are confined to the dedicated worker; readiness waits do not occupy
// Swift's cooperative executor. check() services cancellation and watchdog policy.
package final class ContainerWriter {
  private let writer: AVAssetWriter
  private let video: AVAssetWriterInput
  private let audio: AVAssetWriterInput?
  private var finished = false
  private var videoFinished = false
  private var audioFinished = false
  package private(set) var videoEnd = CMTime.zero
  package private(set) var audioEnd = CMTime.zero
  package init(
    temporaryURL: URL, videoFormat: CMVideoFormatDescription,
    audioFormat: CMAudioFormatDescription?, container: OutputContainer = .mov,
    transform: CGAffineTransform = .identity, videoTimeScale: CMTimeScale = 0
  ) throws {
    writer = try AVAssetWriter(outputURL: temporaryURL, fileType: container == .mp4 ? .mp4 : .mov)
    writer.shouldOptimizeForNetworkUse = container == .mp4
    video = AVAssetWriterInput(
      mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
    video.transform = transform
    video.mediaTimeScale = videoTimeScale
    guard writer.canAdd(video) else {
      throw MediaError(.unsupportedMedia, stage: "write", "Cannot mux encoded video")
    }
    writer.add(video)
    if let audioFormat {
      let a = AVAssetWriterInput(
        mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
      guard writer.canAdd(a) else {
        throw MediaError(.unsupportedMedia, stage: "write", "Cannot mux audio")
      }
      writer.add(a)
      audio = a
    } else {
      audio = nil
    }
    guard writer.startWriting() else { throw failure() }
    writer.startSession(atSourceTime: .zero)
  }
  package func appendVideo(_ sample: EncodedSample, check: () throws -> Void) throws {
    try append(sample, to: video, check: check)
    videoEnd = max(videoEnd, CMTimeAdd(sample.pts, sample.duration))
  }
  package func appendAudio(_ sample: EncodedSample, check: () throws -> Void) throws {
    guard let audio else {
      throw MediaError(.invalidRequest, stage: "write", "Audio input is absent")
    }
    try append(sample, to: audio, check: check)
    audioEnd = max(audioEnd, CMTimeAdd(sample.pts, sample.duration))
  }
  package func tryAppendAudio(_ sample: EncodedSample) throws -> Bool {
    guard let audio else { return false }
    guard writer.status == .writing else { throw failure() }
    guard audio.isReadyForMoreMediaData else { return false }
    guard audio.append(sample.buffer) else { throw failure() }
    audioEnd = max(audioEnd, CMTimeAdd(sample.pts, sample.duration))
    return true
  }
  package func finishAudio() {
    if !audioFinished {
      audio?.markAsFinished()
      audioFinished = true
    }
  }
  private func append(
    _ sample: EncodedSample, to input: AVAssetWriterInput, check: () throws -> Void
  ) throws {
    while !input.isReadyForMoreMediaData {
      try check()
      guard writer.status == .writing else { throw failure() }
      Thread.sleep(forTimeInterval: 0.001)
    }
    try check()
    guard input.append(sample.buffer) else { throw failure() }
  }
  package func finishVideo() {
    if !videoFinished {
      video.markAsFinished()
      videoFinished = true
    }
  }
  package func finish(check: () throws -> Void) throws {
    finishVideo()
    finishAudio()
    let signal = DispatchSemaphore(value: 0)
    writer.finishWriting { signal.signal() }
    while signal.wait(timeout: .now() + 0.05) == .timedOut {
      do { try check() } catch {
        writer.cancelWriting()
        throw error
      }
    }
    guard writer.status == .completed else { throw failure() }
    finished = true
  }
  package func cancel() { if !finished { writer.cancelWriting() } }
  private func failure() -> MediaError {
    MediaError(
      .ioFailure, stage: "write", "Writer failed: \(String(describing: writer.error))",
      underlyingCode: (writer.error as NSError?)?.code)
  }
  deinit { cancel() }
}
