import CoreMedia
import CoreVideo
import Foundation
import PXLAppleMedia
import PXLMedia
import PXLTestSupport
import XCTest

@testable import PXLmpeg

final class HDRStaticMetadataTests: XCTestCase {
  func testSuppliedStaticPQMetadataSurvivesNewEncodeAndProcessing() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("source.mov")
    let output = dir.appendingPathComponent("output.mov")
    let metadata = [
      kCVImageBufferMasteringDisplayColorVolumeKey as String: Data([
        0x33, 0xc2, 0x86, 0xc4, 0x1d, 0x4c, 0x0b, 0xb8, 0x84, 0xd0, 0x3e, 0x80, 0x3d, 0x13, 0x40,
        0x42, 0x00, 0x98, 0x96, 0x80, 0x00, 0x00, 0x00, 0x32,
      ]), kCVImageBufferContentLightLevelInfoKey as String: Data([0x03, 0xe8, 0x01, 0x90]),
      kCVImageBufferAmbientViewingEnvironmentKey as String: Data([
        0x00, 0x2f, 0xe9, 0xa0, 0x3d, 0x13, 0x40, 0x42,
      ]),
    ]
    let contract = PixelContract(bitDepth: 10, colourSpace: .pq2020, staticMetadata: metadata)
    do {
      let budget = MediaBudget(limit: 67_108_864)
      let pool = try PixelBufferPool(width: 96, height: 64, budget: budget, bitDepth: 10)
      let frame = try pool.acquire(pts: .zero, duration: CMTime(value: 1, timescale: 24))
      CVPixelBufferLockBaseAddress(frame.pixel, [])
      for p in 0..<2 {
        let base = CVPixelBufferGetBaseAddressOfPlane(frame.pixel, p)!.assumingMemoryBound(
          to: UInt16.self)
        let count =
          CVPixelBufferGetBytesPerRowOfPlane(frame.pixel, p) / 2
          * CVPixelBufferGetHeightOfPlane(frame.pixel, p)
        for i in 0..<count { base[i] = UInt16(p == 0 ? 321 : 512) << 6 }
      }
      CVPixelBufferUnlockBaseAddress(frame.pixel, [])
      contract.apply(to: frame.pixel)
      let encoder = try VideoEncoder(
        width: 96, height: 64, bitrate: 1_000_000, codec: .hevc, contract: contract)
      let packet = try encoder.encode(frame)
      let writer = try ContainerWriter(
        temporaryURL: source,
        videoFormat: XCTUnwrap(CMSampleBufferGetFormatDescription(packet.buffer)), audioFormat: nil)
      try writer.appendVideo(packet, check: {})
      try writer.finish(check: {})
    }
    let input = try await AssetInput.open(source)
    XCTAssertTrue(input.contract.retainsMetadata(from: contract))
    let engine = MediaEngine(configuration: try EngineConfiguration())
    let receipt = try await engine.execute(
      engine.prepare(
        JobRequest(
          source: source, destination: output, resizeWidth: 48, videoBitrate: 1_000_000,
          outputCodec: .hevc)))
    XCTAssertEqual(receipt.output?.bitDepth, 10)
    let result = try await AssetInput.open(output)
    XCTAssertTrue(result.contract.retainsMetadata(from: contract))
  }
}
