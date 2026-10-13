import AVFoundation
import Foundation
import PXLTestSupport
import XCTest

@testable import PXLAppleMedia

final class AssetTests: XCTestCase {
  func testUnknownChromaAndUnsupportedSPSFail() throws {
    XCTAssertThrowsError(try AssetInput.validateChroma(nil))
    XCTAssertThrowsError(try AssetInput.validateChroma("Center"))
    XCTAssertNoThrow(try AssetInput.validateChroma("Left"))
    XCTAssertNoThrow(try H264Format.validateSPS([0x67, 66, 0, 30, 0x80]))
    XCTAssertThrowsError(try H264Format.validateSPS([0x67, 110, 0, 30, 0x80]))
    XCTAssertThrowsError(try H264Format.validateSPS([0x67, 100, 0, 30]))
    // High profile: SPS id 0, chroma_format_idc 1, luma depth +2 (10-bit).
    XCTAssertThrowsError(try H264Format.validateSPS([0x67, 100, 0, 30, 0xa7, 0x80]))
  }
  func testMissingColourRequiresRecordedExplicitPolicy() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("untagged.mov")
    try FixtureFactory.make(
      at: source, width: 160, height: 96, frames: 24, tagged: false, reorder: true)
    do {
      _ = try await AssetInput.open(source)
      XCTFail("unknown colour silently accepted")
    } catch {}
    let input = try await AssetInput.open(source, colourPolicy: .assumeBT709Limited)
    XCTAssertTrue(input.descriptor.colour.contains("assumed"))
  }
  func testNativeInspectionAndOriginalSamples() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("input.mov")
    try FixtureFactory.make(at: source)
    let info = try await AssetInput.open(source)
    XCTAssertEqual(info.descriptor.width, 1920)
    XCTAssertEqual(info.descriptor.height, 1080)
    XCTAssertFalse(info.descriptor.hasAudio)
    let reader = try SampleReader(input: info, audioPolicy: .copy)
    var count = 0
    while let packet = try reader.nextVideo() {
      XCTAssertGreaterThan(packet.bytes, 0)
      count += 1
    }
    XCTAssertEqual(count, 24)
  }
  func testUnsupportedAndBrokenInputs() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let rotated = dir.appendingPathComponent("rotated.mov")
    try FixtureFactory.make(at: rotated, frames: 1, rotationDegrees: 45)
    do {
      _ = try await AssetInput.open(rotated)
      XCTFail("rotation accepted")
    } catch {}
    let broken = dir.appendingPathComponent("broken.mov")
    try Data([1, 2, 3]).write(to: broken)
    do {
      _ = try await AssetInput.open(broken)
      XCTFail("broken media accepted")
    } catch {}
  }
}
