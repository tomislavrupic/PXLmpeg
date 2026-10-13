import CoreMedia
import CoreVideo
import PXLTestSupport
import XCTest

@testable import PXLAppleMedia

final class VideoCodecTests: XCTestCase {
  func testActualHardwareRoundTrip() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("input.mov")
    try FixtureFactory.make(at: source, width: 160, height: 96, frames: 3)
    let input = try await AssetInput.open(source)
    let reader = try SampleReader(input: input, audioPolicy: .drop)
    let budget = MediaBudget(limit: 64 * 1024 * 1024)
    let decoder = try VideoDecoder(format: input.videoFormat)
    let encoder = try VideoEncoder(width: 160, height: 96, bitrate: 1_000_000)
    XCTAssertTrue(decoder.hardware)
    XCTAssertTrue(encoder.hardware)
    var count = 0
    while let packet = try reader.nextVideo() {
      let frame = try decoder.decode(packet, budget: budget)
      XCTAssertEqual(
        CVPixelBufferGetPixelFormatType(frame.pixel),
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
      let encoded = try encoder.encode(frame)
      XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(encoded.buffer), packet.pts)
      XCTAssertGreaterThan(encoded.bytes, 0)
      count += 1
    }
    XCTAssertEqual(count, 3)
  }
}
