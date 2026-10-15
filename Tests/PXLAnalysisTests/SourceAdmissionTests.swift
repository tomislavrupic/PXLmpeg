import CoreMedia
import Foundation
import PXLAppleMedia
import PXLMedia
import XCTest

@testable import PXLAnalysis

final class SourceAdmissionTests: XCTestCase {
  func testEditorTimecodeSourcePassesSamplingMetadataAdmission() async throws {
    guard let path = ProcessInfo.processInfo.environment["PXL_TIMECODE_SOURCE"] else {
      throw XCTSkip(
        "Supply a real editor export with a timecode track for metadata-only validation")
    }
    let sampler = try await VideoSampler(
      source: URL(fileURLWithPath: path), colourPolicy: .requireTagged)
    let descriptor = await sampler.descriptor
    let first = await sampler.videoStartSeconds
    let end = await sampler.videoEndSeconds
    XCTAssertEqual(descriptor.timecodeTracks, 1)
    XCTAssertGreaterThan(descriptor.width, 0)
    XCTAssertGreaterThan(end, first)
    // Metadata admission only: no samples, decoding, models or predictions.
  }

  func testReadOnlyMetadataAdmissionRejectsInvalidVideoRanges() throws {
    for range in [
      CMTimeRange.invalid, .zero,
      CMTimeRange(start: CMTime(value: -1, timescale: 1), duration: CMTime(value: 2, timescale: 1)),
      CMTimeRange(start: .zero, duration: .indefinite),
    ] {
      XCTAssertThrowsError(try AssetInput.validateReadOnlyVideoRange(range))
    }
    XCTAssertNoThrow(
      try AssetInput.validateReadOnlyVideoRange(
        CMTimeRange(start: CMTime(value: 3, timescale: 1), duration: CMTime(value: 1, timescale: 1))
      ))
  }

  func testLegacySidecarAssetWithoutTimecodeFieldRemainsReadable() throws {
    let oldAsset = Data(
      #"{"width":1920,"height":1080,"codec":"h264","duration":{"value":24,"timescale":24},"hasAudio":true,"colour":"BT.709 limited, left chroma"}"#
        .utf8)
    let descriptor = try JSONDecoder().decode(AssetDescriptor.self, from: oldAsset)
    XCTAssertNil(descriptor.timecodeTracks)
    XCTAssertEqual(descriptor.duration.seconds, 1)
    XCTAssertEqual(descriptor.displayWidth, 1920)
  }

  func testTimecodeStillRejectedForProcessing() async throws {
    guard let path = ProcessInfo.processInfo.environment["PXL_TIMECODE_SOURCE"] else {
      throw XCTSkip("Supply a real editor export for metadata-only validation")
    }
    let source = URL(fileURLWithPath: path)
    do {
      _ = try await AssetInput.open(source)
      XCTFail("Timecode must not be silently discarded by export/remux admission")
    } catch let error as MediaError {
      XCTAssertEqual(error.code, .unsupportedMedia)
      XCTAssertTrue(error.message.contains(source.lastPathComponent))
      XCTAssertTrue(error.message.contains("tmcd"))
    }
  }

  func testInvalidFootageFailsWithFilenameBeforeModelLoading() async throws {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("broken-editor-export.mov")
    try Data([1, 2, 3]).write(to: source)
    let analyzer = try SemanticAnalyzer(models: directory.appendingPathComponent("missing-models"))
    do {
      let sources =
        ProcessInfo.processInfo.environment["PXL_TIMECODE_SOURCE"].map {
          [URL(fileURLWithPath: $0), source]
        } ?? [source]
      _ = try await analyzer.index(sources: sources)
      XCTFail("Invalid footage admitted")
    } catch let error as MediaError {
      XCTAssertEqual(error.stage, "inspect")
      XCTAssertTrue(error.message.contains(source.lastPathComponent), error.message)
    } catch {
      XCTFail(
        "Expected a named footage error before touching the missing model directory: \(error)")
    }
  }
}
