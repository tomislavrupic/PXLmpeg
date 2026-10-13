import AVFoundation
import Foundation
import PXLAppleMedia
import PXLMedia
import PXLTestSupport
import XCTest

@testable import PXLmpeg

final class RemuxTests: XCTestCase {
  func testNativeCopyRoundTripPreservesBFramesVFRRotationHDRAndAAC() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    for kind in 0..<4 {
      let ten = kind >= 2
      let codec: AVVideoCodecType = kind == 0 ? .h264 : .hevc
      let colour: VideoColourSpace = kind == 2 ? .hlg2020 : (kind == 3 ? .pq2020 : .bt709)
      let source = dir.appendingPathComponent("source-\(kind).mov")
      try FixtureFactory.make(
        at: source, width: 160, height: 96, frames: 48, audio: true, reorder: true, startFrame: 3,
        frameDurations: [1, 2, 1], codec: codec, rotationDegrees: 90, bitDepth: ten ? 10 : 8,
        colourSpace: colour)
      let video = try await NativePacketReference.read(source, audio: false)
      let audio = try await NativePacketReference.read(source, audio: true)
      let pictures = try await NativeReference.frames(at: source, bitDepth: ten ? 10 : 8)
      let input = try await AssetInput.open(source)
      var current = source
      for container in [OutputContainer.mp4, .mov] {
        let destination = dir.appendingPathComponent("copy-\(kind).\(container.rawValue)")
        let engine = MediaEngine(configuration: try EngineConfiguration())
        let plan = try await engine.prepare(
          RemuxRequest(source: current, destination: destination, outputContainer: container))
        let receipt = try await engine.execute(plan)
        XCTAssertEqual(receipt.operation, .remux)
        XCTAssertFalse(receipt.decoderHardware)
        XCTAssertFalse(receipt.encoderHardware)
        XCTAssertNil(receipt.acceptedBitrate)
        XCTAssertEqual(receipt.metalDevice, "")
        XCTAssertEqual(receipt.frames, 48)
        XCTAssertLessThan(receipt.ownedMemoryPeak, 16 * 1024 * 1024)
        let output = try await AssetInput.open(destination)
        XCTAssertEqual(output.descriptor.width, 160)
        XCTAssertEqual(output.descriptor.height, 96)
        XCTAssertEqual(output.descriptor.rotation, .clockwise90)
        XCTAssertEqual(output.displayTransform, input.displayTransform)
        XCTAssertEqual(output.contract.staticMetadata, input.contract.staticMetadata)
        XCTAssertEqual(output.descriptor.hasDynamicHDR, input.descriptor.hasDynamicHDR)
        let copiedVideo = try await NativePacketReference.read(destination, audio: false)
        let copiedAudio = try await NativePacketReference.read(destination, audio: true)
        let copiedPictures = try await NativeReference.frames(
          at: destination, bitDepth: ten ? 10 : 8)
        XCTAssertNil(
          copiedVideo.difference(from: video, allowConstantDTSOffset: true),
          "Video kind=\(kind), container=\(container)")
        XCTAssertNil(
          copiedAudio.difference(from: audio), "Audio kind=\(kind), container=\(container)")
        XCTAssertEqual(copiedPictures, pictures)
        current = destination
      }
    }
  }
  func testAudioDropUsesVideoEndAndSourceChangeWrongEngineDoNotPublish() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("source.mov")
    try FixtureFactory.make(
      at: source, width: 160, height: 96, frames: 24, audio: true, audioFrames: 48, reorder: true)
    let engine = MediaEngine(configuration: try EngineConfiguration())
    let destination = dir.appendingPathComponent("drop.mp4")
    let plan = try await engine.prepare(
      RemuxRequest(
        source: source, destination: destination, outputContainer: .mp4, audioPolicy: .drop))
    let result = try await engine.execute(plan)
    XCTAssertEqual(result.output?.hasAudio, false)
    XCTAssertEqual(result.output!.duration.seconds, 1, accuracy: 0.002)
    let other = MediaEngine(configuration: try EngineConfiguration())
    do {
      _ = try await other.execute(plan)
      XCTFail("Foreign plan accepted")
    } catch let e as MediaError { XCTAssertEqual(e.code, .invalidRequest) }
    let changed = try await engine.prepare(
      RemuxRequest(
        source: source, destination: dir.appendingPathComponent("changed.mp4"),
        outputContainer: .mp4))
    let handle = try FileHandle(forWritingTo: source)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data([0]))
    try handle.close()
    do {
      _ = try await engine.execute(changed)
      XCTFail("Changed source accepted")
    } catch let e as MediaError { XCTAssertEqual(e.code, .sourceChanged) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: changed.request.destination.path))
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: dir.path).contains {
        $0.hasPrefix(".pxlmpeg-")
      })
  }
  func testCancellingActiveCopyRemovesPartialMP4() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("long.mov")
    let destination = dir.appendingPathComponent("cancel.mp4")
    try FixtureFactory.make(at: source, width: 160, height: 96, frames: 2000, reorder: true)
    let engine = MediaEngine(configuration: try EngineConfiguration())
    let plan = try await engine.prepare(
      RemuxRequest(source: source, destination: destination, outputContainer: .mp4))
    let task = Task { try await engine.execute(plan) }
    var observed = false
    for _ in 0..<5000 {
      if let progress = await engine.progress(for: plan.id), progress.state == "running",
        progress.frames > 0
      {
        observed = true
        break
      }
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertTrue(observed, "Did not observe active remux")
    await engine.cancel(plan.id)
    do {
      _ = try await task.value
      XCTFail("Active cancellation ignored")
    } catch let e as MediaError {
      XCTAssertEqual(e.code, .cancelled)
      XCTAssertGreaterThan(e.receipt?.frames ?? 0, 0)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter {
      $0.hasPrefix(".pxlmpeg-")
    }
    XCTAssertTrue(leftovers.isEmpty, "Private output directories retained")
  }
}
