import AVFoundation
import CryptoKit
import Foundation
import PXLAppleMedia
import PXLMedia
import PXLMetal
import PXLTestSupport
import PXLmpeg

private struct HDRCase: Codable {
  let source: String, kind: String
  var status = "failed", error: String?
  var input: AssetDescriptor?, receipt: JobReceipt?
  var frames = 0, decodedPicturesMatch = false, orientedLumaMatches = false, timelineMatches = false
  var sourceSHA256: String?, sourceUnchanged = false
  var audioMatches = false, suppliedHDRMetadataPreserved = false
}
enum HDRValidation {
  static func run(_ arguments: [String]) async throws {
    guard let path = arguments.first else {
      throw NSError(domain: "Usage: pxl-validation hdr OUTPUT_DIRECTORY [SOURCE ...]", code: 2)
    }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var sources: [(URL, String)] = []
    for colour in [VideoColourSpace.hlg2020, .pq2020, .bt709] {
      for rotation in [0, 90, 180, 270] {
        let url = directory.appendingPathComponent("native-\(colour.rawValue)-\(rotation).mov")
        try FixtureFactory.make(
          at: url, width: 320, height: 192, frames: 48, audio: true, reorder: true, codec: .hevc,
          rotationDegrees: rotation, bitDepth: 10, colourSpace: colour)
        sources.append((url, "generated native Main10"))
      }
    }
    sources += arguments.dropFirst().map { (URL(fileURLWithPath: $0), "read-only iPhone original") }
    var reports: [HDRCase] = []
    for (index, item) in sources.enumerated() {
      let (source, kind) = item
      var report = HDRCase(source: source.path, kind: kind)
      do {
        let before = try hash(source)
        report.sourceSHA256 = before
        let input = try await AssetInput.open(source, colourPolicy: .assumeBT709Limited)
        report.input = input.descriptor
        let rotation = input.descriptor.rotation ?? .none
        let reference = try await NativeReference.frames(
          at: source, rotation: rotation, bitDepth: 10)
        let depth = input.descriptor.maxReorderFrames!
        let budget = MediaBudget(limit: 1_073_741_824, frameLimit: depth + 1)
        let reader = try SampleReader(input: input, audioPolicy: .drop)
        defer { reader.cancel() }
        let ordered = try OrderedVideoReader(
          reader: reader,
          decoder: VideoDecoder(format: input.videoFormat, contract: input.contract),
          budget: budget,
          reorderDepth: depth)
        let orienter = try PlaneOrienter(context: MetalContext())
        let pool = try PixelBufferPool(
          width: input.descriptor.displayWidth, height: input.descriptor.displayHeight,
          budget: budget, bitDepth: 10)
        var position = 0
        while let frame = try ordered.next(check: {}) {
          try autoreleasepool {
            guard position < reference.count, frame.pts == reference[position].pts,
              try NativeReference.digests(frame.pixel) == reference[position].planeDigests
            else {
              throw NSError(domain: "Decoded picture differs at \(position)", code: 3)
            }
            let upright = try pool.acquire(pts: frame.pts, duration: frame.duration)
            try orienter.orient(frame, into: upright, rotation: rotation)
            guard
              try NativeReference.digests(upright.pixel)[0] == reference[position].displayLumaDigest
            else {
              throw NSError(domain: "Oriented luma differs at \(position)", code: 3)
            }
            position += 1
          }
        }
        guard position == reference.count else {
          throw NSError(domain: "Decoded count differs", code: 3)
        }
        report.frames = position
        report.decodedPicturesMatch = true
        report.orientedLumaMatches = true
        let output = directory.appendingPathComponent("case-\(index)-output.mov")
        let request = try JobRequest(
          source: source, destination: output,
          resizeWidth: kind == "read-only iPhone original" ? 960 : 160, videoBitrate: 8_000_000,
          memoryBudgetBytes: 1_073_741_824,
          inputColourPolicy: .assumeBT709Limited, outputCodec: .hevc, timedMetadataPolicy: .discard)
        try request.normalizedData().write(
          to: directory.appendingPathComponent("case-\(index)-job.json"))
        let engine = MediaEngine(configuration: try EngineConfiguration())
        let receipt = try await engine.execute(engine.prepare(request))
        report.receipt = receipt
        let result = try SampleReader(input: await AssetInput.open(output), audioPolicy: .drop)
        var times: [CMTime] = []
        var durations: [CMTime] = []
        while let packet = try result.nextVideo() {
          times.append(packet.pts)
          durations.append(packet.duration)
        }
        let sourceReader = try SampleReader(input: input, audioPolicy: .drop)
        var originalTimes: [(CMTime, CMTime)] = []
        while let packet = try sourceReader.nextVideo() {
          originalTimes.append((packet.pts, packet.duration))
        }
        originalTimes.sort { $0.0 < $1.0 }
        guard times == reference.map(\.pts), durations == originalTimes.map(\.1),
          receipt.frames == reference.count, receipt.decoderHardware, receipt.encoderHardware,
          receipt.output?.rotation == DisplayRotation.none,
          receipt.output?.codec == request.outputCodec.rawValue,
          receipt.output?.bitDepth == 10,
          receipt.output?.colourSpace == input.descriptor.colourSpace
        else { throw NSError(domain: "Output timeline/codec/hardware differs", code: 3) }
        let outputInput = try await AssetInput.open(output)
        guard outputInput.contract.retainsMetadata(from: input.contract) else {
          throw NSError(domain: "Static HDR/ambient metadata changed", code: 3)
        }
        report.suppliedHDRMetadataPreserved = true
        guard try audioPackets(input) == audioPackets(outputInput),
          (input.audioFormat == nil && outputInput.audioFormat == nil)
            || (input.audioFormat != nil && outputInput.audioFormat != nil
              && CMFormatDescriptionEqual(
                input.audioFormat!, otherFormatDescription: outputInput.audioFormat!))
        else { throw NSError(domain: "AAC payload/timing changed", code: 3) }
        report.audioMatches = true
        report.timelineMatches = true
        report.sourceUnchanged = try hash(source) == before
        guard report.sourceUnchanged else { throw NSError(domain: "Source changed", code: 3) }
        report.status = "completed"
      } catch { report.error = String(describing: error) }
      reports.append(report)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(reports).write(to: directory.appendingPathComponent("hdr.json"))
      print(
        "HDR case \(index): \(report.status), \(report.input?.codec ?? "unknown") rotation \(report.input?.rotation?.rawValue ?? -1), \(report.frames) frames: \(report.error ?? "pictures/orientation/timeline matched")"
      )
    }
    let cli = try JobRequest(
      source: sources.last!.0, destination: directory.appendingPathComponent("cli-output.mov"),
      resizeWidth: 960, videoBitrate: 8_000_000, memoryBudgetBytes: 1_073_741_824,
      inputColourPolicy: .assumeBT709Limited,
      outputCodec: .hevc, timedMetadataPolicy: .discard)
    try cli.normalizedData().write(to: directory.appendingPathComponent("cli-job.json"))
    guard reports.allSatisfy({ $0.status == "completed" }) else {
      throw NSError(domain: "HDR acceptance failed; inspect hdr.json", code: 3)
    }
  }
  private struct AudioPacket: Equatable {
    let hash: String, pts: CMTime, duration: CMTime
  }
  private struct AudioSnapshot: Equatable {
    var packets: [AudioPacket] = []
    var trimStart: [CMTime] = [], trimEnd: [CMTime] = []
    var firstOutputPTS: CMTime?, lastOutputEnd: CMTime?
  }
  private static func audioPackets(_ input: AssetInput) throws -> AudioSnapshot {
    let reader = try SampleReader(input: input, audioPolicy: .copy)
    defer { reader.cancel() }
    var result = AudioSnapshot()
    while let group = try reader.nextAudio() {
      guard let block = CMSampleBufferGetDataBuffer(group.buffer) else {
        throw NSError(domain: "No AAC payload", code: 3)
      }
      if result.firstOutputPTS == nil { result.firstOutputPTS = group.pts }
      result.lastOutputEnd = CMTimeAdd(group.pts, group.duration)
      for (key, isStart) in [
        (kCMSampleBufferAttachmentKey_TrimDurationAtStart, true),
        (kCMSampleBufferAttachmentKey_TrimDurationAtEnd, false),
      ] {
        if let value = CMGetAttachment(group.buffer, key: key, attachmentModeOut: nil)
          as? NSDictionary
        {
          let time = CMTimeMakeFromDictionary(value as CFDictionary)
          if isStart { result.trimStart.append(time) } else { result.trimEnd.append(time) }
        }
      }
      // AVFoundation can regroup multiple AAC access units per sample buffer when
      // remuxing. Compare individual compressed samples, raw timing, trim fields
      // and the rendered span rather than incidental buffer/chunk boundaries.
      var offset = 0
      for index in 0..<CMSampleBufferGetNumSamples(group.buffer) {
        let size = CMSampleBufferGetSampleSize(group.buffer, at: index)
        var data = Data(count: size)
        var timing = CMSampleTimingInfo()
        let status = data.withUnsafeMutableBytes {
          CMBlockBufferCopyDataBytes(
            block, atOffset: offset, dataLength: $0.count, destination: $0.baseAddress!)
        }
        guard status == noErr,
          CMSampleBufferGetSampleTimingInfo(group.buffer, at: index, timingInfoOut: &timing)
            == noErr
        else { throw NSError(domain: "Cannot inspect AAC packet", code: 3) }
        result.packets.append(
          AudioPacket(
            hash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            pts: timing.presentationTimeStamp, duration: timing.duration))
        offset += size
      }
      guard offset == CMBlockBufferGetDataLength(block) else {
        throw NSError(domain: "AAC sample sizes do not cover payload", code: 3)
      }
    }
    return result
  }
  private static func hash(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
      hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
