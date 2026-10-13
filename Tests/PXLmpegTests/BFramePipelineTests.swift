import AVFoundation
import CryptoKit
import Foundation
import PXLAppleMedia
import PXLMedia
import PXLTestSupport
import XCTest

@testable import PXLmpeg

final class BFramePipelineTests: XCTestCase {
  func testNativeBFramesRetainEveryPresentationTimestampAndAACPacket() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("bframes.mov")
    let output = dir.appendingPathComponent("out.mov")
    try FixtureFactory.make(
      at: source, width: 320, height: 192, frames: 96, audio: true, reorder: true)
    let asset = AVURLAsset(url: source)
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    let reader = try AVAssetReader(asset: asset)
    let stream = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(stream)
    XCTAssertTrue(reader.startReading())
    var timestamps: [CMTime] = []
    while let s = stream.copyNextSampleBuffer() {
      if CMSampleBufferGetNumSamples(s) > 0 {
        timestamps.append(CMSampleBufferGetOutputPresentationTimeStamp(s))
      }
    }
    XCTAssertEqual(timestamps.count, 96)
    XCTAssertTrue(
      zip(timestamps, timestamps.dropFirst()).contains { $0 > $1 },
      "Fixture must actually contain reordered frames")
    let engine = MediaEngine(configuration: try EngineConfiguration())
    let job = try await engine.prepare(
      JobRequest(
        source: source, destination: output,
        resizeWidth: 160, videoBitrate: 1_000_000))
    let receipt = try await engine.execute(job)
    XCTAssertTrue(receipt.decoderHardware)
    XCTAssertTrue(receipt.encoderHardware)
    XCTAssertEqual(receipt.frames, 96)
    let result = try SampleReader(input: await AssetInput.open(output), audioPolicy: .copy)
    var actual: [CMTime] = []
    while let packet = try result.nextVideo() { actual.append(packet.pts) }
    XCTAssertEqual(actual, timestamps.sorted())
    let original = try SampleReader(input: await AssetInput.open(source), audioPolicy: .copy)
    var audioCount = 0
    while let before = try original.nextAudio() {
      let after = try XCTUnwrap(result.nextAudio())
      XCTAssertEqual(before.pts, after.pts)
      XCTAssertEqual(before.duration, after.duration)
      XCTAssertEqual(try bytes(before.buffer), try bytes(after.buffer))
      audioCount += 1
    }
    XCTAssertNil(try result.nextAudio())
    XCTAssertEqual(receipt.audioPackets, audioCount)
  }
  func testDecodedBFramePicturesMatchIndependentDisplayOrderReference() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("reordered.mov")
    try FixtureFactory.make(at: source, width: 320, height: 192, frames: 96, reorder: true)
    let expected = try await NativeReference.frames(at: source)
    XCTAssertEqual(expected.count, 96)
    let input = try await AssetInput.open(source)
    let depth = try XCTUnwrap(input.descriptor.maxReorderFrames)
    let budget = MediaBudget(limit: 64 * 1024 * 1024, frameLimit: depth + 1)
    let compressed = try SampleReader(input: input, audioPolicy: .drop)
    let decoder = try VideoDecoder(format: input.videoFormat)
    let ordered = try OrderedVideoReader(
      reader: compressed, decoder: decoder, budget: budget, reorderDepth: depth)
    var index = 0
    while let frame = try ordered.next(check: {}) {
      XCTAssertLessThan(index, expected.count)
      guard index < expected.count else { return }
      XCTAssertEqual(frame.pts, expected[index].pts)
      if expected[index].duration.isNumeric {
        XCTAssertEqual(frame.duration, expected[index].duration)
      }
      XCTAssertEqual(
        try NativeReference.digests(frame.pixel), expected[index].planeDigests,
        "Wrong displayed picture at frame \(index)")
      index += 1
    }
    XCTAssertEqual(index, expected.count)
    XCTAssertLessThanOrEqual(ordered.retainedFramesPeak, depth + 1)
    XCTAssertEqual(budget.current, 0)
    XCTAssertEqual(budget.frameCount, 0)
  }
  func testCancellationReleasesNativeReorderWindow() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("cancel-b.mov")
    try FixtureFactory.make(at: source, width: 320, height: 192, frames: 48, reorder: true)
    let input = try await AssetInput.open(source)
    let depth = input.descriptor.maxReorderFrames!
    let budget = MediaBudget(limit: 64 * 1024 * 1024, frameLimit: depth + 1)
    let compressed = try SampleReader(input: input, audioPolicy: .drop)
    let decoder = try VideoDecoder(format: input.videoFormat)
    let ordered = try OrderedVideoReader(
      reader: compressed, decoder: decoder, budget: budget, reorderDepth: depth)
    _ = try ordered.next(check: {})
    XCTAssertGreaterThan(budget.frameCount, 0)
    ordered.cancel()
    compressed.cancel()
    XCTAssertEqual(budget.current, 0)
    XCTAssertEqual(budget.frameCount, 0)
  }
  func testHundredNativeCancellationSchedulesReleaseAllQueuedFrames() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("cancel-schedules.mov")
    try FixtureFactory.make(at: source, width: 160, height: 96, frames: 48, reorder: true)
    let input = try await AssetInput.open(source)
    let depth = input.descriptor.maxReorderFrames!
    for schedule in 0..<100 {
      let budget = MediaBudget(limit: 64 * 1024 * 1024, frameLimit: depth + 1)
      let packets = try SampleReader(input: input, audioPolicy: .drop)
      let decoder = try VideoDecoder(format: input.videoFormat)
      let ordered = try OrderedVideoReader(
        reader: packets, decoder: decoder, budget: budget, reorderDepth: depth)
      var checks = 0
      let cancelAt = 1 + (schedule * 13 % 40)
      do {
        while try ordered.next(check: {
          checks += 1
          if checks == cancelAt {
            throw MediaError(.cancelled, stage: "test", "Scheduled cancellation")
          }
        }) != nil {}
        XCTFail("Cancellation was not reached")
      } catch let error as MediaError { XCTAssertEqual(error.code, .cancelled) }
      ordered.cancel()
      packets.cancel()
      XCTAssertEqual(budget.current, 0, "Schedule \(schedule)")
      XCTAssertEqual(budget.frameCount, 0)
    }
  }
  func testNonzeroStartAndVariableDurationBFrames() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    for start in [0, 12] {
      let source = dir.appendingPathComponent("vfr-\(start).mov")
      let output = dir.appendingPathComponent("vfr-out-\(start).mov")
      try FixtureFactory.make(
        at: source, width: 160, height: 96, frames: 48,
        reorder: true, startFrame: start, frameDurations: [1, 2, 1, 3, 1])
      let expected = try await NativeReference.frames(at: source)
      let engine = MediaEngine(configuration: try EngineConfiguration())
      let job = try await engine.prepare(
        JobRequest(source: source, destination: output, videoBitrate: 1_000_000))
      let receipt = try await engine.execute(job)
      XCTAssertEqual(receipt.frames, expected.count)
      let reader = try SampleReader(input: await AssetInput.open(output), audioPolicy: .drop)
      var actual: [CMTime] = []
      var durations: [CMTime] = []
      while let s = try reader.nextVideo() {
        actual.append(s.pts)
        durations.append(s.duration)
      }
      XCTAssertEqual(actual, expected.map(\.pts))
      XCTAssertEqual(actual.first?.seconds, Double(start) / 24)
      XCTAssertGreaterThan(Set(durations.map(\.seconds)).count, 1)
      let video = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)[0]
      let gaps = try await video.load(.segments).filter { $0.isEmpty }
      if start > 0 {
        XCTAssertEqual(gaps.first?.timeMapping.target.duration.seconds, Double(start) / 24)
      }
      let original = try SampleReader(input: await AssetInput.open(source), audioPolicy: .drop)
      var expectedDurations: [(CMTime, CMTime)] = []
      while let s = try original.nextVideo() { expectedDurations.append((s.pts, s.duration)) }
      expectedDurations.sort { $0.0 < $1.0 }
      XCTAssertEqual(durations, expectedDurations.map(\.1))
    }
  }
  func testPlannerIncludesReorderWindow() throws {
    let asset = AssetDescriptor(
      width: 3840, height: 2160, codec: "h264",
      duration: try MediaTime(value: 1, timescale: 1), hasAudio: false, maxReorderFrames: 16)
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID()).mov")
    defer { try? FileManager.default.removeItem(at: source) }
    try Data([0]).write(to: source)
    let request = try JobRequest(
      source: source,
      destination: source.deletingPathExtension().appendingPathExtension("out.mov"),
      videoBitrate: 1_000_000, memoryBudgetBytes: 67_108_864)
    XCTAssertThrowsError(try MediaPlanner.prepare(request, asset: asset, engineID: UUID())) {
      XCTAssertEqual(($0 as? MediaError)?.code, .resourceLimit)
    }
  }
  private func bytes(_ s: CMSampleBuffer) throws -> Data {
    let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(s))
    var data = Data(count: CMBlockBufferGetDataLength(block))
    XCTAssertEqual(
      data.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(
          block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
      }, noErr)
    return data
  }
}
