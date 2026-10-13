import CoreMedia
import CryptoKit
import Foundation
import PXLAppleMedia
import PXLMedia
import PXLTestSupport
import XCTest

@testable import PXLmpeg

final class NativePipelineTests: XCTestCase {
  func testTenSecondNativePipeline() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("in.mov")
    let target = dir.appendingPathComponent("out.mov")
    try FixtureFactory.make(at: source, width: 320, height: 192, frames: 240)
    let engine = MediaEngine(configuration: try EngineConfiguration())
    let job = try await engine.prepare(
      JobRequest(source: source, destination: target, resizeWidth: 160, videoBitrate: 1_000_000))
    let receipt = try await engine.execute(job)
    XCTAssertEqual(receipt.state, "completed")
    XCTAssertEqual(receipt.frames, 240)
    XCTAssertTrue(receipt.decoderHardware)
    XCTAssertTrue(receipt.encoderHardware)
    XCTAssertGreaterThan(receipt.processFootprintPeakBytes ?? 0, 0)
    XCTAssertGreaterThan(receipt.ownedMemoryPeak, 0)
    XCTAssertLessThanOrEqual(receipt.ownedMemoryPeak, 268_435_456)
    let input = try await AssetInput.open(target)
    let reader = try SampleReader(input: input, audioPolicy: .drop)
    XCTAssertEqual(input.descriptor.width, 160)
    XCTAssertEqual(input.descriptor.height, 96)
    var frames = 0
    while let sample = try reader.nextVideo() {
      XCTAssertEqual(sample.pts, CMTime(value: Int64(frames), timescale: 24))
      frames += 1
    }
    XCTAssertEqual(frames, 240)
  }
  func testAACPacketsAndTimingSurviveNativePipeline() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("audio in.mov")
    let target = dir.appendingPathComponent("audio out.mov")
    try FixtureFactory.make(at: source, width: 320, height: 192, frames: 48, audio: true)
    let engine = MediaEngine(configuration: try EngineConfiguration())
    let plan = try await engine.prepare(
      JobRequest(source: source, destination: target, resizeWidth: 160, videoBitrate: 1_000_000))
    let receipt = try await engine.execute(plan)
    XCTAssertGreaterThan(receipt.audioPackets, 0)
    let a = try SampleReader(input: await AssetInput.open(source), audioPolicy: .copy)
    let b = try SampleReader(input: await AssetInput.open(target), audioPolicy: .copy)
    var count = 0
    while let x = try a.nextAudio() {
      let y = try XCTUnwrap(b.nextAudio())
      XCTAssertEqual(x.pts, y.pts)
      XCTAssertEqual(x.duration, y.duration)
      XCTAssertEqual(try audioBytes(x.buffer), try audioBytes(y.buffer))
      count += 1
    }
    XCTAssertNil(try b.nextAudio())
    XCTAssertEqual(count, receipt.audioPackets)
  }
  func testUnequalTrackDurationsCopyAndDrop() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    for audioFrames in [12, 96] {
      let source = dir.appendingPathComponent("in-\(audioFrames).mov")
      try FixtureFactory.make(
        at: source, width: 160, height: 96, frames: 48,
        audio: true, audioFrames: audioFrames)
      for policy in [AudioPolicy.copy, .drop] {
        let engine = MediaEngine(configuration: try EngineConfiguration(noProgressTimeout: 10))
        let plan = try await engine.prepare(
          JobRequest(
            source: source,
            destination: dir.appendingPathComponent("out-\(audioFrames)-\(policy.rawValue).mov"),
            videoBitrate: 1_000_000, audioPolicy: policy))
        let receipt = try await engine.execute(plan)
        XCTAssertEqual(receipt.frames, 48)
        XCTAssertEqual(
          receipt.output!.duration.seconds,
          policy == .copy ? Double(max(48, audioFrames)) / 24 : 2, accuracy: 0.002)
      }
    }
  }
  func testWatchdogDiagnosesWithoutWorkerCheck() async throws {
    let control = JobControl(id: UUID(), timeout: 0.02)
    defer { control.stopWatchdog() }
    control.setState("running")
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(control.snapshot.state, "stalled-native-teardown-pending")
    XCTAssertThrowsError(try control.check()) {
      XCTAssertEqual(($0 as? MediaError)?.code, .noProgress)
    }
    control.heartbeat()
    XCTAssertThrowsError(try control.check())
  }
  private func audioBytes(_ sample: CMSampleBuffer) throws -> Data {
    let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
    var data = Data(count: CMBlockBufferGetDataLength(block))
    let status = data.withUnsafeMutableBytes {
      CMBlockBufferCopyDataBytes(
        block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
    }
    XCTAssertEqual(status, noErr)
    return data
  }
  func testChangedSourceDoesNotPublish() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("in.mov")
    let target = dir.appendingPathComponent("out.mov")
    try FixtureFactory.make(at: source, width: 160, height: 96, frames: 2)
    let engine = MediaEngine(configuration: try EngineConfiguration())
    let plan = try await engine.prepare(
      JobRequest(source: source, destination: target, videoBitrate: 1_000_000))
    let file = try FileHandle(forWritingTo: source)
    try file.seekToEnd()
    try file.write(contentsOf: Data([0]))
    try file.close()
    do {
      _ = try await engine.execute(plan)
      XCTFail("changed source accepted")
    } catch let error as MediaError { XCTAssertEqual(error.code, .sourceChanged) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
  }
  func testCancelAndBusyAreSafe() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("in.mov")
    let target = dir.appendingPathComponent("out.mov")
    try FixtureFactory.make(at: source, width: 320, height: 192, frames: 240)
    let engine = MediaEngine(configuration: try EngineConfiguration())
    let plan = try await engine.prepare(
      JobRequest(source: source, destination: target, videoBitrate: 1_000_000))
    let task = Task { try await engine.execute(plan) }
    for _ in 0..<1000 {
      if await engine.progress(for: plan.id) != nil { break }
      await Task.yield()
    }
    do {
      _ = try await engine.execute(plan)
      XCTFail("concurrent job accepted")
    } catch let error as MediaError { XCTAssertEqual(error.code, .engineBusy) }
    await engine.cancel(plan.id)
    do {
      _ = try await task.value
      XCTFail("cancel ignored")
    } catch let error as MediaError {
      XCTAssertEqual(error.code, .cancelled)
      XCTAssertEqual(error.receipt?.state, "cancelled")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: dir.path).contains {
        $0.hasPrefix(".pxlmpeg-")
      })
  }
}
