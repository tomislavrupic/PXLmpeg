import AVFoundation
import Foundation
import PXLMedia
import PXLTestSupport
import XCTest

@testable import PXLmpeg

final class ContainerOutputTests: XCTestCase {
  func testMP4TranscodePreservesNativeH264AndMain10HLGWithFastStart() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    for ten in [false, true] {
      let source = dir.appendingPathComponent("source-\(ten).mov")
      let output = dir.appendingPathComponent("output-\(ten).mp4")
      try FixtureFactory.make(
        at: source, width: 160, height: 96, frames: 24, audio: true, reorder: true,
        codec: ten ? .hevc : .h264, bitDepth: ten ? 10 : 8, colourSpace: ten ? .hlg2020 : .bt709)
      let engine = MediaEngine(configuration: try EngineConfiguration())
      let request = try JobRequest(
        source: source, destination: output, videoBitrate: 1_000_000,
        outputCodec: ten ? .hevc : .h264, outputContainer: .mp4)
      let receipt = try await engine.execute(engine.prepare(request))
      XCTAssertEqual(receipt.frames, 24)
      XCTAssertEqual(receipt.output?.bitDepth, ten ? 10 : 8)
      XCTAssertEqual(receipt.output?.colourSpace, ten ? .hlg2020 : .bt709)
      let boxes = try topLevelBoxes(output)
      XCTAssertNotNil(boxes.first { $0.0 == "ftyp" })
      XCTAssertLessThan(
        try XCTUnwrap(boxes.first { $0.0 == "moov" }?.1),
        try XCTUnwrap(boxes.first { $0.0 == "mdat" }?.1))
      let bytes = try Data(contentsOf: output)
      XCTAssertNotEqual(String(data: bytes[8..<12], encoding: .ascii), "qt  ")
    }
  }
  func testContainerMustMatchDestinationAndLegacyRequestsDefaultMOV() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("source.mov")
    try FixtureFactory.make(at: source, width: 96, height: 64, frames: 1)
    let request = try JobRequest(
      source: source, destination: dir.appendingPathComponent("wrong.mov"), videoBitrate: 1_000_000,
      outputContainer: .mp4)
    let engine = MediaEngine(configuration: try EngineConfiguration())
    do {
      _ = try await engine.prepare(request)
      XCTFail("Mismatched container accepted")
    } catch let error as MediaError { XCTAssertEqual(error.code, .invalidRequest) }
    var fields = try JSONSerialization.jsonObject(with: request.normalizedData()) as! [String: Any]
    fields.removeValue(forKey: "outputContainer")
    XCTAssertEqual(
      try JobRequest.decodeStrict(JSONSerialization.data(withJSONObject: fields)).outputContainer,
      .mov)
  }
  private func topLevelBoxes(_ url: URL) throws -> [(String, Int)] {
    let bytes = [UInt8](try Data(contentsOf: url))
    var offset = 0
    var result: [(String, Int)] = []
    while offset + 8 <= bytes.count {
      var size = bytes[offset..<offset + 4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
      let kind = String(bytes: bytes[offset + 4..<offset + 8], encoding: .ascii)!
      if size == 1 {
        size = bytes[offset + 8..<offset + 16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
      }
      if size == 0 { size = UInt64(bytes.count - offset) }
      guard size >= 8, size <= UInt64(bytes.count - offset) else {
        throw NSError(domain: "Invalid box", code: 1)
      }
      result.append((kind, offset))
      offset += Int(size)
    }
    return result
  }
}
