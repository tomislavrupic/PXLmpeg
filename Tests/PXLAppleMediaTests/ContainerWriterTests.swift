import CoreMedia
import PXLTestSupport
import XCTest

@testable import PXLAppleMedia

final class ContainerWriterTests: XCTestCase {
  func testNativeWriterRoundTrip() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("input.mov")
    let target = dir.appendingPathComponent("output.mov")
    try FixtureFactory.make(at: source, width: 160, height: 96, frames: 6)
    let input = try await AssetInput.open(source)
    let reader = try SampleReader(input: input, audioPolicy: .drop)
    let decoder = try VideoDecoder(format: input.videoFormat)
    let encoder = try VideoEncoder(width: 160, height: 96, bitrate: 1_000_000)
    let budget = MediaBudget(limit: 64 * 1024 * 1024)
    var writer: ContainerWriter?
    while let packet = try reader.nextVideo() {
      let encoded = try encoder.encode(decoder.decode(packet, budget: budget))
      if writer == nil {
        writer = try ContainerWriter(
          temporaryURL: target, videoFormat: CMSampleBufferGetFormatDescription(encoded.buffer)!,
          audioFormat: nil)
      }
      try writer!.appendVideo(encoded) {}
    }
    try writer!.finish {}
    let output = try await AssetInput.open(target)
    XCTAssertEqual(output.descriptor.width, 160)
    let check = try SampleReader(input: output, audioPolicy: .drop)
    var count = 0
    while let packet = try check.nextVideo() {
      XCTAssertEqual(packet.pts, CMTime(value: Int64(count), timescale: 24))
      XCTAssertEqual(packet.duration, CMTime(value: 1, timescale: 24))
      count += 1
    }
    XCTAssertEqual(count, 6)
  }
}
