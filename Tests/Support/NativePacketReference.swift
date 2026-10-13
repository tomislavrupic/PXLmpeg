import AVFoundation
import CryptoKit
import Foundation

public struct NativePacket: Equatable, Sendable {
  public let hash: String
  public let pts: CMTime, dts: CMTime, duration: CMTime
  public let notSync: Bool
  public static func == (a: Self, b: Self) -> Bool {
    a.hash == b.hash && a.pts == b.pts && (a.dts == b.dts || (!a.dts.isValid && !b.dts.isValid))
      && a.duration == b.duration && a.notSync == b.notSync
  }
}
public struct NativePacketTimeline: Equatable, Sendable {
  public var packets: [NativePacket] = []
  public var trimStart: [CMTime] = [], trimEnd: [CMTime] = []
  public var firstOutputPTS: CMTime?, outputEnd: CMTime?
}
// Independent compressed AVFoundation reads. Normalize AAC access units across
// container chunk regrouping; preserve video decode order and output edit timing.
public enum NativePacketReference {
  public static func read(_ url: URL, audio: Bool) async throws -> NativePacketTimeline {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: audio ? .audio : .video).first
    else { return NativePacketTimeline() }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    guard reader.startReading() else {
      throw reader.error ?? NSError(domain: "packet reference", code: 1)
    }
    defer { reader.cancelReading() }
    var result = NativePacketTimeline()
    while let group = output.copyNextSampleBuffer() {
      let count = CMSampleBufferGetNumSamples(group)
      if count == 0 { continue }
      guard let block = CMSampleBufferGetDataBuffer(group) else {
        throw NSError(domain: "packet reference payload", code: 1)
      }
      let pts = CMSampleBufferGetOutputPresentationTimeStamp(group)
      let duration = CMSampleBufferGetOutputDuration(group)
      if result.firstOutputPTS == nil { result.firstOutputPTS = pts }
      let end = CMTimeAdd(pts, duration)
      result.outputEnd = max(result.outputEnd ?? end, end)
      for (key, start) in [
        (kCMSampleBufferAttachmentKey_TrimDurationAtStart, true),
        (kCMSampleBufferAttachmentKey_TrimDurationAtEnd, false),
      ] {
        if let data = CMGetAttachment(group, key: key, attachmentModeOut: nil) as? NSDictionary {
          let time = CMTimeMakeFromDictionary(data as CFDictionary)
          if start { result.trimStart.append(time) } else { result.trimEnd.append(time) }
        }
      }
      let attachments =
        CMSampleBufferGetSampleAttachmentsArray(group, createIfNecessary: false) as? [NSDictionary]
      var offset = 0
      for i in 0..<count {
        let size = CMSampleBufferGetSampleSize(group, at: i)
        var bytes = Data(count: size)
        var timing = CMSampleTimingInfo()
        let status = bytes.withUnsafeMutableBytes {
          CMBlockBufferCopyDataBytes(
            block, atOffset: offset, dataLength: size, destination: $0.baseAddress!)
        }
        guard status == noErr,
          CMSampleBufferGetSampleTimingInfo(group, at: i, timingInfoOut: &timing) == noErr
        else { throw NSError(domain: "packet reference sample", code: 1) }
        result.packets.append(
          NativePacket(
            hash: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            pts: audio ? timing.presentationTimeStamp : pts,
            dts: audio ? timing.decodeTimeStamp : CMSampleBufferGetOutputDecodeTimeStamp(group),
            duration: audio ? timing.duration : duration,
            notSync: audio
              ? false : (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)))
        offset += size
      }
      guard offset == CMBlockBufferGetDataLength(block) else {
        throw NSError(domain: "packet reference size", code: 1)
      }
    }
    if reader.status == .failed { throw reader.error! }
    return result
  }
}
extension NativePacketTimeline {
  public func difference(from other: Self, allowConstantDTSOffset: Bool = false) -> String? {
    if packets.count != other.packets.count {
      return "Packet count \(packets.count) vs \(other.packets.count)"
    }
    let shift: CMTime? =
      allowConstantDTSOffset && packets.first?.dts.isValid == true
        && other.packets.first?.dts.isValid == true
      ? CMTimeSubtract(packets[0].dts, other.packets[0].dts) : nil
    for (i, pair) in zip(packets, other.packets).enumerated() where pair.0 != pair.1 {
      let a = pair.0
      let b = pair.1
      if let shift, a.hash == b.hash, a.pts == b.pts, a.duration == b.duration,
        a.notSync == b.notSync, a.dts.isValid, b.dts.isValid, CMTimeSubtract(a.dts, b.dts) == shift
      {
        continue
      }
      return
        "Packet \(i): hash equal=\(a.hash == b.hash), PTS \(a.pts.seconds)/\(b.pts.seconds), DTS \(a.dts.seconds)/\(b.dts.seconds), duration \(a.duration.seconds)/\(b.duration.seconds), sync \(a.notSync)/\(b.notSync)"
    }
    if trimStart != other.trimStart || trimEnd != other.trimEnd { return "Trim fields differ" }
    if firstOutputPTS != other.firstOutputPTS || outputEnd != other.outputEnd {
      return "Rendered span differs"
    }
    return nil
  }
}
