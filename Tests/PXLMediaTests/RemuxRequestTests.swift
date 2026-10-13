import Foundation
import PXLMedia
import XCTest

final class RemuxRequestTests: XCTestCase {
  func testStrictCopySchemaDoesNotAcceptTranscodeOptions() throws {
    let request = try RemuxRequest(
      source: URL(fileURLWithPath: "/media/source.mov"),
      destination: URL(fileURLWithPath: "/media/copy.mp4"), outputContainer: .mp4)
    XCTAssertEqual(try RemuxRequest.decodeStrict(request.normalizedData()), request)
    let base = try JSONSerialization.jsonObject(with: request.normalizedData()) as! [String: Any]
    for key in ["videoBitrate", "resizeWidth", "outputCodec", "inputColourPolicy"] {
      var fields = base
      fields[key] = 1
      XCTAssertThrowsError(
        try RemuxRequest.decodeStrict(JSONSerialization.data(withJSONObject: fields)))
    }
    var legacy = base
    for key in ["outputContainer", "audioPolicy", "timedMetadataPolicy", "memoryBudgetBytes"] {
      legacy.removeValue(forKey: key)
    }
    let decoded = try RemuxRequest.decodeStrict(JSONSerialization.data(withJSONObject: legacy))
    XCTAssertEqual(decoded.outputContainer, .mov)
    XCTAssertEqual(decoded.timedMetadataPolicy, .reject)
    XCTAssertEqual(decoded.audioPolicy, .copy)
    XCTAssertEqual(decoded.memoryBudgetBytes, 67_108_864)
  }
}
