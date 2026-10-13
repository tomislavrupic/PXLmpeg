import AVFoundation
import CryptoKit
import Foundation
import PXLAppleMedia
import PXLMedia
import PXLMetal
import PXLTestSupport
import PXLmpeg

private struct WideCase: Codable {
  let source: String, kind: String
  var status = "failed", error: String?
  var input: AssetDescriptor?, receipt: JobReceipt?
  var frames = 0, decodedPicturesMatch = false, orientedLumaMatches = false, timelineMatches = false
  var sourceSHA256: String?, sourceUnchanged = false
}
enum WideFootageValidation {
  static func run(_ arguments: [String]) async throws {
    guard let path = arguments.first else {
      throw NSError(domain: "Usage: pxl-validation wide OUTPUT_DIRECTORY [SOURCE ...]", code: 2)
    }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var sources: [(URL, String)] = []
    for codec in [AVVideoCodecType.h264, .hevc] {
      for rotation in [0, 90, 180, 270] {
        let url = directory.appendingPathComponent("native-\(codec.rawValue)-\(rotation).mov")
        try FixtureFactory.make(
          at: url, width: 320, height: 192, frames: 48, audio: true, reorder: true, codec: codec,
          rotationDegrees: rotation)
        sources.append((url, "generated native"))
      }
    }
    let originals = arguments.dropFirst().map { URL(fileURLWithPath: $0) }
    sources += originals.map { ($0, "read-only original") }
    if let first = originals.first {
      let rotated = directory.appendingPathComponent("real-passthrough-rotated90.mov")
      try await remuxRotated(first, to: rotated)
      sources.append((rotated, "controlled passthrough rotation of real source"))
    }
    var reports: [WideCase] = []
    for (index, item) in sources.enumerated() {
      let (source, kind) = item
      var report = WideCase(source: source.path, kind: kind)
      do {
        let before = try hash(source)
        report.sourceSHA256 = before
        let input = try await AssetInput.open(source, colourPolicy: .assumeBT709Limited)
        report.input = input.descriptor
        let rotation = input.descriptor.rotation ?? .none
        let reference = try await NativeReference.frames(at: source, rotation: rotation)
        let depth = input.descriptor.maxReorderFrames!
        let budget = MediaBudget(limit: 268_435_456, frameLimit: depth + 1)
        let reader = try SampleReader(input: input, audioPolicy: .drop)
        defer { reader.cancel() }
        let ordered = try OrderedVideoReader(
          reader: reader, decoder: VideoDecoder(format: input.videoFormat), budget: budget,
          reorderDepth: depth)
        let orienter = try PlaneOrienter(context: MetalContext())
        let pool = try PixelBufferPool(
          width: input.descriptor.displayWidth, height: input.descriptor.displayHeight,
          budget: budget)
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
          source: source, destination: output, resizeWidth: 160, videoBitrate: 1_000_000,
          inputColourPolicy: .assumeBT709Limited, outputCodec: index % 2 == 0 ? .hevc : .h264)
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
          receipt.output?.codec == request.outputCodec.rawValue
        else { throw NSError(domain: "Output timeline/codec/hardware differs", code: 3) }
        report.timelineMatches = true
        report.sourceUnchanged = try hash(source) == before
        guard report.sourceUnchanged else { throw NSError(domain: "Source changed", code: 3) }
        report.status = "completed"
      } catch { report.error = String(describing: error) }
      reports.append(report)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(reports).write(to: directory.appendingPathComponent("wide.json"))
      print(
        "Wide case \(index): \(report.status), \(report.input?.codec ?? "unknown") rotation \(report.input?.rotation?.rawValue ?? -1), \(report.frames) frames: \(report.error ?? "pictures/orientation/timeline matched")"
      )
    }
    let cli = try JobRequest(
      source: sources.last!.0, destination: directory.appendingPathComponent("cli-output.mov"),
      resizeWidth: 160, videoBitrate: 1_000_000, inputColourPolicy: .assumeBT709Limited,
      outputCodec: .hevc)
    try cli.normalizedData().write(to: directory.appendingPathComponent("cli-job.json"))
    guard reports.allSatisfy({ $0.status == "completed" }) else {
      throw NSError(domain: "Wide acceptance failed; inspect wide.json", code: 3)
    }
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
  private static func remuxRotated(_ source: URL, to output: URL) async throws {
    let asset = AVURLAsset(url: source)
    let composition = AVMutableComposition()
    let tracks = try await asset.load(.tracks)
    for track in tracks where [.video, .audio].contains(track.mediaType) {
      guard
        let destination = composition.addMutableTrack(
          withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)
      else { throw NSError(domain: "Cannot compose rotation fixture", code: 3) }
      let range = try await track.load(.timeRange)
      try destination.insertTimeRange(range, of: track, at: range.start)
      if track.mediaType == .video {
        let format = try await track.load(.formatDescriptions)[0]
        let d = CMVideoFormatDescriptionGetDimensions(format)
        destination.preferredTransform = CGAffineTransform(
          a: 0, b: 1, c: -1, d: 0, tx: CGFloat(d.height), ty: 0)
      }
    }
    guard
      let export = AVAssetExportSession(
        asset: composition, presetName: AVAssetExportPresetPassthrough)
    else { throw NSError(domain: "Cannot remux fixture", code: 3) }
    try await export.export(to: output, as: .mov)
  }
}
