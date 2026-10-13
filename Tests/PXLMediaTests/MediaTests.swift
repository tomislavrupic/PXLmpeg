import Foundation
import XCTest

@testable import PXLMedia

final class MediaTests: XCTestCase {
  func testRationalComparisonAndValidation() throws {
    XCTAssertEqual(
      try MediaTime(value: 1, timescale: 24), try MediaTime(value: 1000, timescale: 24000))
    XCTAssertLessThan(
      try MediaTime(value: Int64.max, timescale: 2), try MediaTime(value: Int64.max, timescale: 1))
    XCTAssertLessThan(
      try MediaTime(value: Int64.min, timescale: 1), try MediaTime(value: -1, timescale: 2))
    XCTAssertThrowsError(try MediaTime(value: 1, timescale: 0))
    XCTAssertThrowsError(
      try JSONDecoder().decode(MediaTime.self, from: Data(#"{"value":1,"timescale":-1}"#.utf8)))
  }
  func testStrictRequestAndNormalization() throws {
    let json =
      #"{"schemaVersion":1,"id":"11111111-1111-1111-1111-111111111111","source":"file:///tmp/in.mov","destination":"file:///tmp/out.mov","videoBitrate":4000000,"audioPolicy":"copy"}"#
    let r = try JobRequest.decodeStrict(Data(json.utf8))
    XCTAssertEqual(r.memoryBudgetBytes, 268_435_456)
    XCTAssertEqual(try JobRequest.decodeStrict(r.normalizedData()), r)
    XCTAssertThrowsError(
      try JobRequest.decodeStrict(
        Data(json.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8)
      ))
    XCTAssertThrowsError(
      try JobRequest.decodeStrict(
        Data(
          json.replacingOccurrences(
            of: "\"schemaVersion\":1", with: "\"surprise\":true,\"schemaVersion\":1"
          ).utf8)))
    XCTAssertThrowsError(
      try JobRequest.decodeStrict(
        Data(
          json.replacingOccurrences(of: "file:///tmp/in.mov", with: "https://example.com/in.mov")
            .utf8)))
    for width in [14, 17, 4098] {
      XCTAssertThrowsError(
        try JobRequest(
          source: r.source, destination: r.destination, resizeWidth: width, videoBitrate: 1))
    }
    for budget in [0, 67_108_863, 2_147_483_649] {
      XCTAssertThrowsError(
        try JobRequest(
          source: r.source, destination: r.destination, videoBitrate: 1, memoryBudgetBytes: budget))
    }
    XCTAssertThrowsError(
      try JobRequest(source: r.source, destination: r.destination, videoBitrate: 0))
  }
  func testExplicitColourPolicyRoundTripsAndDefaultRemainsStrict() throws {
    let request = try JobRequest(
      source: URL(fileURLWithPath: "/tmp/in.mov"),
      destination: URL(fileURLWithPath: "/tmp/out.mov"), videoBitrate: 1_000_000,
      inputColourPolicy: .assumeBT709Limited)
    XCTAssertEqual(
      try JobRequest.decodeStrict(request.normalizedData()).inputColourPolicy, .assumeBT709Limited)
    var json = try JSONSerialization.jsonObject(with: request.normalizedData()) as! [String: Any]
    json.removeValue(forKey: "inputColourPolicy")
    XCTAssertEqual(
      try JobRequest.decodeStrict(JSONSerialization.data(withJSONObject: json)).inputColourPolicy,
      .requireTagged)
  }
  func testResizeGeometry() throws {
    XCTAssertEqual(
      try OutputGeometry(sourceWidth: 1920, sourceHeight: 1080, width: 1280).height, 720)
    XCTAssertThrowsError(try OutputGeometry(sourceWidth: 32, sourceHeight: 18, width: 16))
  }
}
