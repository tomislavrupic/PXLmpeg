import AVFoundation
import CryptoKit
import Foundation
import PXLAppleMedia
import PXLMedia
import PXLTestSupport
import PXLmpeg

private struct BFrameCase: Codable {
  let source: String
  var status = "failed"
  var error: String?
  var strictInspectionError: String?
  var sourceSHA256: String?
  var sourceUnchanged = false
  var compressedPTSReordered = false
  var reorderDepth: Int?
  var decodedFrames = 0
  var decodedPicturesMatchReference = false
  var presentationTimelineMatches = false
  var retainedFramesPeak = 0
  var ownedDecodePeak = 0
  var receipt: JobReceipt?
}
enum BFrameValidation {
  static func run(_ arguments: [String]) async throws {
    guard let path = arguments.first else {
      throw NSError(domain: "Usage: pxl-validation bframes OUTPUT_DIRECTORY [INPUT ...]", code: 2)
    }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let native = directory.appendingPathComponent("native-bframes-aac.mov")
    try FixtureFactory.make(
      at: native, width: 1280, height: 768, frames: 240, audio: true, reorder: true)
    let sources = [native] + arguments.dropFirst().map { URL(fileURLWithPath: $0) }
    var reports: [BFrameCase] = []
    for (index, source) in sources.enumerated() {
      var report = BFrameCase(source: source.path)
      do {
        let before = try fileHash(source)
        report.sourceSHA256 = before
        let engine = MediaEngine(configuration: try EngineConfiguration())
        do { _ = try await engine.inspect(source) } catch {
          report.strictInspectionError = String(describing: error)
        }
        let policy = InputColourPolicy.assumeBT709Limited
        let input = try await AssetInput.open(source, colourPolicy: policy)
        let depth = input.descriptor.maxReorderFrames!
        report.reorderDepth = depth
        let reference = try await NativeReference.frames(at: source)
        guard !reference.isEmpty else { throw NSError(domain: "Empty native reference", code: 3) }
        let budget = MediaBudget(limit: 268_435_456, frameLimit: depth + 1)
        let packets = try SampleReader(input: input, audioPolicy: .drop)
        defer { packets.cancel() }
        let decoder = try VideoDecoder(format: input.videoFormat)
        let ordered = try OrderedVideoReader(
          reader: packets, decoder: decoder, budget: budget, reorderDepth: depth)
        var position = 0
        while let frame = try ordered.next(check: {}) {
          guard position < reference.count, frame.pts == reference[position].pts,
            try NativeReference.digests(frame.pixel) == reference[position].planeDigests
          else {
            throw NSError(
              domain: "Decoded display picture/reference differs at \(position)", code: 3)
          }
          position += 1
        }
        guard position == reference.count, budget.current == 0 else {
          throw NSError(domain: "Decoded count or leases differ", code: 3)
        }
        report.decodedFrames = position
        report.decodedPicturesMatchReference = true
        report.retainedFramesPeak = ordered.retainedFramesPeak
        report.ownedDecodePeak = budget.peak
        let orderProbe = try SampleReader(input: input, audioPolicy: .drop)
        defer { orderProbe.cancel() }
        var previous: CMTime?
        while let sample = try orderProbe.nextVideo() {
          if let previous, sample.pts < previous { report.compressedPTSReordered = true }
          previous = sample.pts
        }
        guard report.compressedPTSReordered else {
          throw NSError(domain: "No actual reordered frames in fixture", code: 3)
        }
        let output = directory.appendingPathComponent("case-\(index)-output.mov")
        let request = try JobRequest(
          source: source, destination: output, resizeWidth: 640,
          videoBitrate: 4_000_000, inputColourPolicy: policy)
        try request.normalizedData().write(
          to: directory.appendingPathComponent("case-\(index)-job.json"))
        let receipt = try await engine.execute(engine.prepare(request))
        report.receipt = receipt
        let rendered = try SampleReader(input: await AssetInput.open(output), audioPolicy: .drop)
        var times: [CMTime] = []
        var durations: [CMTime] = []
        while let frame = try rendered.nextVideo() {
          times.append(frame.pts)
          durations.append(frame.duration)
        }
        guard times == reference.map(\.pts), receipt.frames == reference.count,
          receipt.decoderHardware, receipt.encoderHardware
        else { throw NSError(domain: "Rendered timeline/hardware differs", code: 3) }
        // Decoder references can omit durations; the encoded path must keep each original
        // compressed sample's mapped duration, including the final frame.
        let original = try SampleReader(input: input, audioPolicy: .drop)
        var originalTimes: [(CMTime, CMTime)] = []
        while let frame = try original.nextVideo() {
          originalTimes.append((frame.pts, frame.duration))
        }
        originalTimes.sort { $0.0 < $1.0 }
        guard durations == originalTimes.map(\.1) else {
          throw NSError(domain: "Rendered durations differ", code: 3)
        }
        report.presentationTimelineMatches = true
        report.sourceUnchanged = try fileHash(source) == before
        guard report.sourceUnchanged else { throw NSError(domain: "Source changed", code: 3) }
        report.status = "completed"
      } catch {
        report.error = String(describing: error)
      }
      reports.append(report)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(reports).write(to: directory.appendingPathComponent("bframes.json"))
      print(
        "B-frame case \(index): \(report.status), \(report.decodedFrames) frames, reorder \(report.reorderDepth ?? -1), \(report.error ?? "reference pictures/timeline matched")"
      )
    }
    let cliSource = sources.count > 1 ? sources[1] : sources[0]
    let cli = try JobRequest(
      source: cliSource, destination: directory.appendingPathComponent("cli-output.mov"),
      resizeWidth: 640, videoBitrate: 4_000_000, inputColourPolicy: .assumeBT709Limited)
    try cli.normalizedData().write(to: directory.appendingPathComponent("cli-job.json"))
    guard reports.allSatisfy({ $0.status == "completed" }) else {
      throw NSError(domain: "Some B-frame cases failed; inspect bframes.json", code: 3)
    }
  }
  private static func fileHash(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
      hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
