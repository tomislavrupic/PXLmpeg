import CoreGraphics
import CoreMedia
import CoreVideo
import PXLAppleMedia
import PXLMedia
import XCTest

@testable import PXLMetal

final class TenBitOrientationTests: XCTestCase {
  func testTenBitPixelsAndChromaRemainPreciseAcrossRotations() throws {
    let orienter = try PlaneOrienter(context: MetalContext())
    for rotation in [DisplayRotation.none, .clockwise90, .upsideDown, .clockwise270] {
      let budget = MediaBudget(limit: 64 * 1024 * 1024)
      let sourcePool = try PixelBufferPool(width: 64, height: 32, budget: budget, bitDepth: 10)
      let destinationPool = try PixelBufferPool(
        width: rotation.swapsAxes ? 32 : 64, height: rotation.swapsAxes ? 64 : 32, budget: budget,
        bitDepth: 10)
      let input = try sourcePool.acquire(pts: .zero, duration: CMTime(value: 1, timescale: 24))
      let output = try destinationPool.acquire(pts: .zero, duration: input.duration)
      CVPixelBufferLockBaseAddress(input.pixel, [])
      for plane in 0..<2 {
        let w = CVPixelBufferGetWidthOfPlane(input.pixel, plane)
        let h = CVPixelBufferGetHeightOfPlane(input.pixel, plane)
        let stride = (CVPixelBufferGetBytesPerRowOfPlane(input.pixel, plane) / 2)
        let channels = plane == 0 ? 1 : 2
        let p = CVPixelBufferGetBaseAddressOfPlane(input.pixel, plane)!.assumingMemoryBound(
          to: UInt16.self)
        for y in 0..<h {
          for x in 0..<w {
            for c in 0..<channels {
              p[y * stride + x * channels + c] = UInt16((x * 13 + y * 7 + c * 53) % 936 + 64) << 6
            }
          }
        }
      }
      CVPixelBufferUnlockBaseAddress(input.pixel, [])
      try orienter.orient(input, into: output, rotation: rotation)
      CVPixelBufferLockBaseAddress(input.pixel, .readOnly)
      CVPixelBufferLockBaseAddress(output.pixel, .readOnly)
      defer {
        CVPixelBufferUnlockBaseAddress(input.pixel, .readOnly)
        CVPixelBufferUnlockBaseAddress(output.pixel, .readOnly)
      }
      let forward = CGAffineTransform(rotationAngle: Double(rotation.rawValue) * .pi / 180)
      let bounds = CGRect(x: 0, y: 0, width: 64, height: 32).applying(forward)
      let canonical = CGAffineTransform(
        a: forward.a, b: forward.b, c: forward.c, d: forward.d, tx: -bounds.minX, ty: -bounds.minY
      ).inverted()
      for plane in 0..<2 {
        let w = CVPixelBufferGetWidthOfPlane(input.pixel, plane)
        let h = CVPixelBufferGetHeightOfPlane(input.pixel, plane)
        let stride = (CVPixelBufferGetBytesPerRowOfPlane(input.pixel, plane) / 2)
        let channels = plane == 0 ? 1 : 2
        let dstStride = (CVPixelBufferGetBytesPerRowOfPlane(output.pixel, plane) / 2)
        let src = CVPixelBufferGetBaseAddressOfPlane(input.pixel, plane)!.assumingMemoryBound(
          to: UInt16.self)
        let dst = CVPixelBufferGetBaseAddressOfPlane(output.pixel, plane)!.assumingMemoryBound(
          to: UInt16.self)
        for y in 0..<CVPixelBufferGetHeightOfPlane(output.pixel, plane) {
          for x in 0..<CVPixelBufferGetWidthOfPlane(output.pixel, plane) {
            let physical =
              plane == 0
              ? CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
              : CGPoint(x: Double(x * 2) + 0.5, y: Double(y * 2) + 1)
            let mapped = physical.applying(canonical)
            let sx = plane == 0 ? mapped.x - 0.5 : (mapped.x - 0.5) / 2
            let sy = plane == 0 ? mapped.y - 0.5 : (mapped.y - 1) / 2
            let ix = Int(floor(sx))
            let iy = Int(floor(sy))
            let fx = sx - Double(ix)
            let fy = sy - Double(iy)
            for c in 0..<channels {
              var expected = 0.0
              for dy in 0...1 {
                for dx in 0...1 {
                  let xx = max(0, min(w - 1, ix + dx))
                  let yy = max(0, min(h - 1, iy + dy))
                  expected +=
                    Double(src[yy * stride + xx * channels + c] >> 6) * (dx == 0 ? 1 - fx : fx)
                    * (dy == 0 ? 1 - fy : fy)
                }
              }
              XCTAssertEqual(
                Double(dst[y * dstStride + x * channels + c] >> 6), expected, accuracy: 1,
                "Rotation \(rotation.rawValue), plane \(plane), pixel \(x),\(y)")
            }
          }
        }
      }
    }
  }
}
