import AVFoundation
import CoreVideo
import Foundation
import PXLAppleMedia
import PXLMedia
import PXLTestSupport
import XCTest

@testable import PXLmpeg

final class HDRPipelineTests: XCTestCase {
  func testMain10HLGAndPQRemainTenBitHDRThroughRotationAndResize() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    for colour in [VideoColourSpace.hlg2020, .pq2020, .bt709] {
      let source = dir.appendingPathComponent("\(colour.rawValue).mov")
      let output = dir.appendingPathComponent("\(colour.rawValue)-out.mov")
      try FixtureFactory.make(
        at: source, width: 320, height: 192, frames: 48, audio: true, reorder: true, codec: .hevc,
        rotationDegrees: 90, bitDepth: 10, colourSpace: colour)
      let engine = MediaEngine(configuration: try EngineConfiguration())
      let info = try await engine.inspect(source)
      XCTAssertEqual(info.bitDepth, 10)
      XCTAssertEqual(info.colourSpace, colour)
      let job = try await engine.prepare(
        JobRequest(
          source: source, destination: output, resizeWidth: 160, videoBitrate: 2_000_000,
          outputCodec: .hevc))
      let receipt = try await engine.execute(job)
      XCTAssertEqual(receipt.output?.bitDepth, 10)
      XCTAssertEqual(receipt.output?.colourSpace, colour)
      XCTAssertTrue(receipt.decoderHardware)
      XCTAssertTrue(receipt.encoderHardware)
      XCTAssertEqual(receipt.frames, 48)
      let a = try await AssetInput.open(source)
      let b = try await AssetInput.open(output)
      let sourceExt = try XCTUnwrap(CMFormatDescriptionGetExtensions(a.videoFormat)) as NSDictionary
      let outputExt = try XCTUnwrap(CMFormatDescriptionGetExtensions(b.videoFormat)) as NSDictionary
      XCTAssertTrue(b.contract.retainsMetadata(from: a.contract))
      if colour == .hlg2020 {
        XCTAssertEqual(
          outputExt[kCMFormatDescriptionExtension_AmbientViewingEnvironment] as? Data,
          sourceExt[kCMFormatDescriptionExtension_AmbientViewingEnvironment] as? Data)
      }
      let wrong = try JobRequest(
        source: source, destination: dir.appendingPathComponent("wrong.mov"),
        videoBitrate: 1_000_000)
      do {
        _ = try await engine.prepare(wrong)
        XCTFail("Silent ten-to-eight-bit conversion accepted")
      } catch let error as MediaError { XCTAssertEqual(error.code, .unsupportedMedia) }
    }
  }
  func testCancellingRotatedMain10HDRJobLeavesNoOutputOrPartialFile() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("cancel-hevc.mov")
    let output = dir.appendingPathComponent("cancel-out.mov")
    try FixtureFactory.make(
      at: source, width: 640, height: 384, frames: 240, reorder: true, codec: .hevc,
      rotationDegrees: 90, bitDepth: 10, colourSpace: .hlg2020)
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
}
