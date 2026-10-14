import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import PXLAppleMedia
import PXLMedia
import PXLTestSupport
import XCTest

@testable import PXLAnalysis

final class NativeAnalysisTests: XCTestCase {
  func testSamplerUsesActualTimesRotationAndSDR() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("hdr.mov")
    try FixtureFactory.make(
      at: url, width: 320, height: 192, frames: 48, reorder: true,
      codec: .hevc, rotationDegrees: 90, bitDepth: 10, colourSpace: .hlg2020)
    let sampler = try await VideoSampler(source: url, colourPolicy: .requireTagged)
    let a = try await sampler.sample(seconds: 0.25)
    let b = try await sampler.sample(seconds: 1.25)
    XCTAssertGreaterThan(b.actualTime, a.actualTime)
    XCTAssertEqual(b.actualTime.seconds, 1.25, accuracy: 1.0 / 24)
    XCTAssertLessThan(a.image.width, a.image.height)
    XCTAssertFalse(CGColorSpaceUsesITUR_2100TF(try XCTUnwrap(a.image.colorSpace)))
    let cancelled = Task { try await sampler.sample(seconds: 0.5) }
    cancelled.cancel()
    do {
      _ = try await cancelled.value
      XCTFail("Cancelled sample succeeded")
    } catch is CancellationError {}
  }

  func testRealModelsIndexQueryIdentityAndNoOverwrite() async throws {
    guard let root = ProcessInfo.processInfo.environment["PXL_SEMANTIC_MODELS"] else {
      throw XCTSkip("Set PXL_SEMANTIC_MODELS for local Core ML models")
    }
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("source.mov")
    try FixtureFactory.make(
      at: url, width: 320, height: 192, frames: 48, audio: true, reorder: true)
    let analyzer = try SemanticAnalyzer(
      models: URL(fileURLWithPath: root), variant: "s2", computePolicy: .cpuAndNeuralEngine)
    let index = try await analyzer.index(
      sources: [url], options: SamplingOptions(intervalSeconds: 0.5, maximumSamplesPerSource: 2))
    XCTAssertEqual(index.frames.count, 2)
    XCTAssertTrue(index.sources[0].truncated)
    try index.validate()
    let hits = try await analyzer.query("a video", index: index, limit: 2)
    XCTAssertEqual(hits.count, 2)
    let dest = dir.appendingPathComponent("sidecar.json")
    try index.write(to: dest)
    let data = try Data(contentsOf: dest)
    XCTAssertThrowsError(try index.write(to: dest))
    XCTAssertEqual(try Data(contentsOf: dest), data)
    XCTAssertEqual(try SemanticIndex.read(from: dest).frames.count, 2)
    let other = try SemanticAnalyzer(
      models: URL(fileURLWithPath: root), variant: "s0", computePolicy: .cpuAndNeuralEngine)
    do {
      _ = try await other.query("a video", index: index)
      XCTFail("Mismatched model accepted")
    } catch let error as MediaError { XCTAssertEqual(error.code, .invalidRequest) }
    let cancelled = Task { try await analyzer.index(sources: [url]) }
    cancelled.cancel()
    do {
      _ = try await cancelled.value
      XCTFail("Cancelled index succeeded")
    } catch is CancellationError {}
    let benchmark = try await analyzer.benchmark(source: url, repetitions: 2)
    XCTAssertEqual(benchmark.imagePredictionMilliseconds.count, 2)
    XCTAssertEqual(benchmark.textPredictionMilliseconds.count, 2)
    XCTAssertTrue(benchmark.imagePredictionMilliseconds.allSatisfy { $0.isFinite && $0 > 0 })
    let plan = try await analyzer.computePlan()
    XCTAssertGreaterThan(plan.image.preferredOperations["ane"] ?? 0, 0)
  }

  func testActiveCancellationAndBusyAdmission() async throws {
    guard let root = ProcessInfo.processInfo.environment["PXL_SEMANTIC_MODELS"] else {
      throw XCTSkip("Set PXL_SEMANTIC_MODELS for local model validation")
    }
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("cancel.mov")
    try FixtureFactory.make(at: source, width: 320, height: 192, frames: 240, reorder: true)
    let analyzer = try SemanticAnalyzer(models: URL(fileURLWithPath: root))
    _ = try await analyzer.computePlan()
    let work = Task {
      try await analyzer.index(sources: [source], options: SamplingOptions(intervalSeconds: 0.1))
    }
    let deadline = ContinuousClock.now + .seconds(5)
    while await !analyzer.active {
      guard ContinuousClock.now < deadline else { return XCTFail("Index never became active") }
      await Task.yield()
    }
    do {
      _ = try await analyzer.computePlan()
      XCTFail("Concurrent operation admitted")
    } catch let error as MediaError { XCTAssertEqual(error.code, .engineBusy) }
    work.cancel()
    do {
      _ = try await work.value
      XCTFail("Active cancellation ignored")
    } catch is CancellationError {}
    let busy = await analyzer.active
    XCTAssertFalse(busy)
  }

  func testExplicitColourAssumptionMatchesTaggedFrames() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let tagged = dir.appendingPathComponent("tagged.mov")
    let untagged = dir.appendingPathComponent("untagged.mov")
    try FixtureFactory.make(at: tagged, width: 320, height: 192, frames: 24, rotate: true)
    try FixtureFactory.make(
      at: untagged, width: 320, height: 192, frames: 24, tagged: false, rotate: true)
    let a = try await VideoSampler(source: tagged, colourPolicy: .requireTagged)
    let b = try await VideoSampler(source: untagged, colourPolicy: .assumeBT709Limited)
    let backend = b.backend
    XCTAssertEqual(backend, "nativeVT-explicitBT709")
    let x = try await a.sample(seconds: 0.25)
    let y = try await b.sample(seconds: 0.25)
    XCTAssertEqual(x.actualTime, y.actualTime)
    XCTAssertEqual(x.image.width, y.image.width)
    let context = CIContext()
    func pixels(_ image: CGImage) -> [UInt8] {
      var bytes = Array(repeating: UInt8(0), count: image.width * image.height * 4)
      context.render(
        CIImage(cgImage: image), toBitmap: &bytes, rowBytes: image.width * 4,
        bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
      return bytes
    }
    let left = pixels(x.image)
    let right = pixels(y.image)
    let mean =
      zip(left, right).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(left.count)
    XCTAssertLessThan(mean, 3, "Colour assumption changed identical source pixels")
  }

  func testUntrustedCompiledCacheCannotOverrideSourceIdentity() async throws {
    guard let root = ProcessInfo.processInfo.environment["PXL_SEMANTIC_MODELS"] else {
      throw XCTSkip("Set PXL_SEMANTIC_MODELS for local models")
    }
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let original = URL(fileURLWithPath: root)
    for name in [
      "download-manifest.json", "clip-vocab.json", "clip-merges.txt",
      "mobileclip_s2_image.mlpackage", "mobileclip_s2_text.mlpackage",
    ] {
      try FileManager.default.createSymbolicLink(
        at: dir.appendingPathComponent(name),
        withDestinationURL: original.appendingPathComponent(name))
    }
    let first = try SemanticAnalyzer(models: dir)
    let plan = try await first.computePlan()
    let fake = dir.appendingPathComponent("compiled-\(plan.modelID)")
    for kind in ["image", "text"] {
      try FileManager.default.createDirectory(
        at: fake.appendingPathComponent("mobileclip_s2_\(kind).mlmodelc"),
        withIntermediateDirectories: true)
    }
    let second = try SemanticAnalyzer(models: dir)
    let independent = try await second.computePlan()
    XCTAssertEqual(independent.modelID, plan.modelID)
    XCTAssertGreaterThan(independent.image.preferredOperations["ane"] ?? 0, 0)
  }

  func testForwardRequestsCanShareAFutureFrameAcrossPresentationGap() throws {
    let budget = MediaBudget(limit: 1_048_576, frameLimit: 2)
    func lease(_ pts: Int64) throws -> MediaLease {
      var pixel: CVPixelBuffer?
      XCTAssertEqual(
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
      return MediaLease(
        pixel: try XCTUnwrap(pixel), pts: CMTime(value: pts, timescale: 1),
        duration: CMTime(value: 1, timescale: 1),
        reservation: try budget.reserve(bytes: 4096, kind: .frame))
    }
    let frames = try [lease(0), lease(5)]
    let cursor = DecodedFrameCursor()
    var count = 0
    func next() -> MediaLease? {
      defer { count += 1 }
      return count < frames.count ? frames[count] : nil
    }
    let first = try cursor.select(at: CMTime(value: 2, timescale: 1), next: next)
    let second = try cursor.select(at: CMTime(value: 3, timescale: 1), next: next)
    XCTAssertEqual(first.pts, CMTime(value: 5, timescale: 1))
    XCTAssertEqual(second.pts, first.pts)
    XCTAssertEqual(count, 2)
    XCTAssertThrowsError(try cursor.select(at: CMTime(value: 1, timescale: 1), next: next))
  }

  func testMalformedRecordsAndDeterministicRanking() throws {
    let d = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: d) }
    let source = IndexedSource(
      url: d.appendingPathComponent("a.mov"), sha256: String(repeating: "b", count: 64),
      asset: AssetDescriptor(
        width: 320, height: 192, codec: "h264", duration: try MediaTime(value: 48, timescale: 24),
        hasAudio: false),
      videoStartSeconds: 0, videoEndSeconds: 2, truncated: false,
      samplingBackend: "assetImageGenerator-forceSDR")
    var vector = Array(repeating: Float(0), count: 512)
    vector[0] = 1
    let f = FrameEmbedding(
      sourceIndex: 0, requestedTime: try MediaTime(value: 0, timescale: 24),
      actualTime: try MediaTime(value: 0, timescale: 24), vector: vector, inferenceMilliseconds: 1)
    let index = SemanticIndex(
      schemaVersion: 1, modelID: String(repeating: "a", count: 64), modelName: "s2",
      preprocessing: SemanticIndex.preprocessing, computePolicy: .cpuOnly,
      sampling: try SamplingOptions(), inputColourPolicy: .requireTagged, sources: [source],
      frames: [f], elapsedMilliseconds: 1)
    XCTAssertEqual(
      try SemanticSearch.rank(index: index, query: vector, modelID: index.modelID).first?.score, 1)
    XCTAssertThrowsError(try SemanticSearch.rank(index: index, query: vector, modelID: "wrong"))
    var object =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(index)) as! [String: Any]
    object["schemaVersion"] = 99
    let path = d.appendingPathComponent("bad.json")
    try JSONSerialization.data(withJSONObject: object).write(to: path)
    XCTAssertThrowsError(try SemanticIndex.read(from: path))
  }
}
