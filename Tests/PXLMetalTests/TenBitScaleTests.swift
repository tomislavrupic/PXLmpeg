import CoreMedia
import CoreVideo
import PXLAppleMedia
import XCTest

@testable import PXLMetal

final class TenBitScaleTests: XCTestCase {
  func testSubEightBitCodePrecisionAndPackingSurviveAllScalePaths() throws {
    let scaler = try PlaneScaler(context: MetalContext())
    for size in [16, 32, 48] {
      let budget = MediaBudget(limit: 64 * 1024 * 1024)
      let a = try PixelBufferPool(width: 32, height: 32, budget: budget, bitDepth: 10)
      let b = try PixelBufferPool(width: size, height: size, budget: budget, bitDepth: 10)
      let input = try a.acquire(pts: .zero, duration: CMTime(value: 1, timescale: 24))
      let output = try b.acquire(pts: .zero, duration: input.duration)
      CVPixelBufferLockBaseAddress(input.pixel, [])
      for p in 0..<2 {
        let data = CVPixelBufferGetBaseAddressOfPlane(input.pixel, p)!.assumingMemoryBound(
          to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(input.pixel, p) / 2
        for y in 0..<CVPixelBufferGetHeightOfPlane(input.pixel, p) {
          for x in 0..<(CVPixelBufferGetWidthOfPlane(input.pixel, p) * (p == 0 ? 1 : 2)) {
            data[y * stride + x] = UInt16(p == 0 ? 321 : (x % 2 == 0 ? 341 : 999)) << 6
          }
        }
      }
      CVPixelBufferUnlockBaseAddress(input.pixel, [])
      try scaler.scale(input, into: output, budget: budget)
      CVPixelBufferLockBaseAddress(output.pixel, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(output.pixel, .readOnly) }
      for p in 0..<2 {
        let data = CVPixelBufferGetBaseAddressOfPlane(output.pixel, p)!.assumingMemoryBound(
          to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(output.pixel, p) / 2
        for y in 0..<CVPixelBufferGetHeightOfPlane(output.pixel, p) {
          for x in 0..<(CVPixelBufferGetWidthOfPlane(output.pixel, p) * (p == 0 ? 1 : 2)) {
            XCTAssertEqual(
              data[y * stride + x] >> 6, UInt16(p == 0 ? 321 : (x % 2 == 0 ? 341 : 999)))
            XCTAssertEqual(data[y * stride + x] & 63, 0)
          }
        }
      }
    }
  }
}
