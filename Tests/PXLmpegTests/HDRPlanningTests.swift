import Foundation
import PXLMedia
import PXLTestSupport
import XCTest

@testable import PXLmpeg

final class HDRPlanningTests: XCTestCase {
  func testTimedMetadataDiscardIsExplicitAndLegacyDefaultsReject() throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("source.mov")
    try FixtureFactory.make(at: source, width: 96, height: 64, frames: 1)
    let asset = AssetDescriptor(
      width: 96, height: 64, codec: "hevc", duration: try MediaTime(value: 1, timescale: 24),
      hasAudio: false, maxReorderFrames: 2, bitDepth: 10, colourSpace: .hlg2020,
      timedMetadataTracks: 5)
    let reject = try JobRequest(
      source: source, destination: dir.appendingPathComponent("out.mov"), videoBitrate: 1_000_000,
      outputCodec: .hevc)
    XCTAssertThrowsError(try MediaPlanner.prepare(reject, asset: asset, engineID: UUID())) {
      XCTAssertEqual(($0 as? MediaError)?.code, .unsupportedMedia)
    }
    let discard = try JobRequest(
      source: source, destination: dir.appendingPathComponent("out.mov"), videoBitrate: 1_000_000,
      outputCodec: .hevc, timedMetadataPolicy: .discard)
    XCTAssertEqual(
      try JobRequest.decodeStrict(discard.normalizedData()).timedMetadataPolicy, .discard)
    XCTAssertNoThrow(try MediaPlanner.prepare(discard, asset: asset, engineID: UUID()))
    var fields = try JSONSerialization.jsonObject(with: reject.normalizedData()) as! [String: Any]
    fields.removeValue(forKey: "timedMetadataPolicy")
    XCTAssertEqual(
      try JobRequest.decodeStrict(JSONSerialization.data(withJSONObject: fields))
        .timedMetadataPolicy, .reject)
  }
}
