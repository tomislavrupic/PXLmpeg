import AVFoundation
import Foundation
import PXLAppleMedia
import PXLMedia
import PXLTestSupport
import XCTest

@testable import PXLmpeg

final class HEVCPipelineTests: XCTestCase {
  func testExplicitHEVCOutputAndDefaultH264RemainCompatible() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("source.mov")
    try FixtureFactory.make(at: source, width: 160, height: 96, frames: 24)
    for codec in [OutputVideoCodec.h264, .hevc] {
      let request = try JobRequest(
        source: source,
        destination: dir.appendingPathComponent("\(codec.rawValue).mov"), videoBitrate: 1_000_000,
        outputCodec: codec)
      XCTAssertEqual(try JobRequest.decodeStrict(request.normalizedData()).outputCodec, codec)
      let engine = MediaEngine(configuration: try EngineConfiguration())
      let result = try await engine.execute(engine.prepare(request))
      XCTAssertEqual(result.output?.codec, codec.rawValue)
      XCTAssertTrue(result.encoderHardware)
    }
    let legacy = try JobRequest(
      source: source, destination: dir.appendingPathComponent("old.mov"), videoBitrate: 1_000_000)
    var fields = try JSONSerialization.jsonObject(with: legacy.normalizedData()) as! [String: Any]
    fields.removeValue(forKey: "outputCodec")
    XCTAssertEqual(
      try JobRequest.decodeStrict(JSONSerialization.data(withJSONObject: fields)).outputCodec, .h264
    )
  }
  func testRotatedH264AndHEVCBecomeUprightPortraitOrLandscape() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    for codec in [AVVideoCodecType.h264, .hevc] {
      for degrees in [90, 180, 270] {
        let source = dir.appendingPathComponent("\(codec.rawValue)-\(degrees).mov")
        let output = dir.appendingPathComponent("out-\(codec.rawValue)-\(degrees).mov")
        try FixtureFactory.make(
          at: source, width: 320, height: 192, frames: 24, audio: true, reorder: true, codec: codec,
          rotationDegrees: degrees)
        let engine = MediaEngine(configuration: try EngineConfiguration())
        let request = try JobRequest(
          source: source, destination: output, resizeWidth: 160, videoBitrate: 1_000_000,
          outputCodec: codec == .hevc ? .hevc : .h264)
        let job = try await engine.prepare(request)
        XCTAssertEqual(job.geometry.width, 160)
        XCTAssertEqual(job.geometry.height, degrees == 180 ? 96 : 266)
        let receipt = try await engine.execute(job)
        XCTAssertEqual(receipt.frames, 24)
        XCTAssertTrue(receipt.decoderHardware)
        XCTAssertTrue(receipt.encoderHardware)
        let info = try await AssetInput.open(output)
        XCTAssertEqual(info.descriptor.rotation, DisplayRotation.none)
        let track = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)[0]
        let transform = try await track.load(.preferredTransform)
        XCTAssertTrue(transform.isIdentity)
        let decodedOutput = try await NativeReference.frames(at: output)
        let samples = try XCTUnwrap(decodedOutput.first?.lumaProbes).map(Int.init)
        if degrees == 90 {
          XCTAssertGreaterThan(samples[0] - samples[1], 8)
          XCTAssertLessThan(abs(samples[0] - samples[2]), 3)
        }
        if degrees == 270 {
          XCTAssertGreaterThan(samples[1] - samples[0], 8)
          XCTAssertLessThan(abs(samples[0] - samples[2]), 3)
        }
        if degrees == 180 {
          XCTAssertGreaterThan(samples[0] - samples[2], 8)
          XCTAssertLessThan(abs(samples[0] - samples[1]), 3)
        }
      }
    }
  }
  func testRotationSurfaceIsIncludedInMinimumBudget() throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(
      "budget-\(UUID()).mov")
    try Data([0]).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let request = try JobRequest(
      source: source, destination: source.appendingPathExtension("out.mov"),
      videoBitrate: 1_000_000, memoryBudgetBytes: 67_108_864)
    let plain = AssetDescriptor(
      width: 3840, height: 2160, codec: "hevc", duration: try MediaTime(value: 1, timescale: 1),
      hasAudio: false, maxReorderFrames: 0, rotation: DisplayRotation.none)
    XCTAssertNoThrow(try MediaPlanner.prepare(request, asset: plain, engineID: UUID()))
    let rotated = AssetDescriptor(
      width: 3840, height: 2160, codec: "hevc", duration: plain.duration, hasAudio: false,
      maxReorderFrames: 0, rotation: .clockwise90)
    XCTAssertThrowsError(try MediaPlanner.prepare(request, asset: rotated, engineID: UUID())) {
      XCTAssertEqual(($0 as? MediaError)?.code, .resourceLimit)
    }
  }
  func testCancellingRotatedHEVCJobLeavesNoOutputOrPartialFile() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("cancel-hevc.mov")
    let output = dir.appendingPathComponent("cancel-out.mov")
    try FixtureFactory.make(
      at: source, width: 640, height: 384, frames: 240, reorder: true, codec: .hevc,
      rotationDegrees: 90)
    let engine = MediaEngine(configuration: try EngineConfiguration())
    let job = try await engine.prepare(
      JobRequest(source: source, destination: output, videoBitrate: 2_000_000, outputCodec: .hevc))
    let task = Task { try await engine.execute(job) }
    for _ in 0..<1000 {
      if let progress = await engine.progress(for: job.id), progress.frames > 0 { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    await engine.cancel(job.id)
    do {
      _ = try await task.value
      XCTFail("Cancellation ignored")
    } catch let error as MediaError { XCTAssertEqual(error.code, .cancelled) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: dir.path).contains {
        $0.hasPrefix(".pxlmpeg-")
      })
  }
  func testNativeHEVCInputMatchesDisplayReference() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("hevc.mov")
    let output = dir.appendingPathComponent("out.mov")
    try FixtureFactory.make(
      at: source, width: 320, height: 192, frames: 48, audio: true, reorder: true, codec: .hevc)
    let expected = try await NativeReference.frames(at: source)
    let engine = MediaEngine(configuration: try EngineConfiguration())
    let plan = try await engine.prepare(
      JobRequest(source: source, destination: output, videoBitrate: 1_000_000))
    XCTAssertEqual(plan.asset.codec, "hevc")
    let receipt = try await engine.execute(plan)
    XCTAssertTrue(receipt.decoderHardware)
    XCTAssertTrue(receipt.encoderHardware)
    XCTAssertEqual(receipt.frames, expected.count)
    let result = try SampleReader(input: await AssetInput.open(output), audioPolicy: .drop)
    var times: [CMTime] = []
    while let frame = try result.nextVideo() { times.append(frame.pts) }
    XCTAssertEqual(times, expected.map(\.pts))
  }
}
