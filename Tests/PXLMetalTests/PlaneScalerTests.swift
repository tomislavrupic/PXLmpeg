import CoreMedia
import CoreVideo
import PXLAppleMedia
import XCTest

@testable import PXLMetal

final class PlaneScalerTests: XCTestCase {
  func testRealGPUAgainstScalarAreaAndBilinear() throws {
    let context = try MetalContext()
    let scaler = try PlaneScaler(context: context)
    for (w, h) in [(32, 32), (16, 16), (48, 48)] {
      let budget = MediaBudget(limit: 64 * 1024 * 1024)
      let sourcePool = try PixelBufferPool(width: 32, height: 32, budget: budget)
      let outputPool = try PixelBufferPool(width: w, height: h, budget: budget)
      let input = try sourcePool.acquire(pts: .zero, duration: CMTime(value: 1, timescale: 24))
      let output = try outputPool.acquire(pts: .zero, duration: input.duration)
      CVPixelBufferLockBaseAddress(input.pixel, [])
      for plane in 0..<2 {
        let width = CVPixelBufferGetWidthOfPlane(input.pixel, plane)
        let height = CVPixelBufferGetHeightOfPlane(input.pixel, plane)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(input.pixel, plane)
        let channels = plane == 0 ? 1 : 2
        let ptr = CVPixelBufferGetBaseAddressOfPlane(input.pixel, plane)!.assumingMemoryBound(
          to: UInt8.self)
        for y in 0..<height {
          for x in 0..<width {
            for c in 0..<channels {
              ptr[y * stride + x * channels + c] = UInt8((x * 13 + y * 7 + c * 57) % 220 + 16)
            }
          }
        }
      }
      CVPixelBufferUnlockBaseAddress(input.pixel, [])
      try scaler.scale(input, into: output, budget: budget)
      CVPixelBufferLockBaseAddress(input.pixel, .readOnly)
      CVPixelBufferLockBaseAddress(output.pixel, .readOnly)
      defer {
        CVPixelBufferUnlockBaseAddress(input.pixel, .readOnly)
        CVPixelBufferUnlockBaseAddress(output.pixel, .readOnly)
      }
      for p in 0..<2 {
        let sw = CVPixelBufferGetWidthOfPlane(input.pixel, p)
        let sh = CVPixelBufferGetHeightOfPlane(input.pixel, p)
        let dw = CVPixelBufferGetWidthOfPlane(output.pixel, p)
        let dh = CVPixelBufferGetHeightOfPlane(output.pixel, p)
        let channels = p == 0 ? 1 : 2
        let sstride = CVPixelBufferGetBytesPerRowOfPlane(input.pixel, p)
        let dstride = CVPixelBufferGetBytesPerRowOfPlane(output.pixel, p)
        let s = CVPixelBufferGetBaseAddressOfPlane(input.pixel, p)!.assumingMemoryBound(
          to: UInt8.self)
        let d = CVPixelBufferGetBaseAddressOfPlane(output.pixel, p)!.assumingMemoryBound(
          to: UInt8.self)
        for y in 0..<dh {
          for x in 0..<dw {
            for c in 0..<channels {
              let expected = reference(
                x: x, y: y, sw: sw, sh: sh, dw: dw, dh: dh, offsetX: p == 0 ? 0.5 : 0.25
              ) { Double(s[$1 * sstride + $0 * channels + c]) }
              XCTAssertEqual(
                Double(d[y * dstride + x * channels + c]), expected, accuracy: w == 32 ? 1 : 2)
            }
          }
        }
      }
    }
  }
  // Scalar reference in code-value units; GPU uses normalized textures. Source cell
  // support is [i-0.5,i+0.5]. Chroma is left-sited horizontally and centered vertically.
  private func weights(_ position: Int, _ source: Int, _ dest: Int, _ offset: Double) -> [(
    Int, Double
  )] {
    let ratio = Double(source) / Double(dest)
    let center = (Double(position) + offset) * ratio - offset
    if ratio <= 1 {
      let i = Int(floor(center))
      let f = center - Double(i)
      return [(max(0, min(source - 1, i)), 1 - f), (max(0, min(source - 1, i + 1)), f)]
    }
    let left = center - ratio / 2
    let right = center + ratio / 2
    return (Int(floor(left + 0.5))..<Int(ceil(right + 0.5))).map { i in
      (
        max(0, min(source - 1, i)),
        max(0, min(right, Double(i) + 0.5) - max(left, Double(i) - 0.5)) / ratio
      )
    }
  }
  private func reference(
    x: Int, y: Int, sw: Int, sh: Int, dw: Int, dh: Int, offsetX: Double, at: (Int, Int) -> Double
  ) -> Double {
    var total = 0.0
    for (sy, wy) in weights(y, sh, dh, 0.5) {
      for (sx, wx) in weights(x, sw, dw, offsetX) { total += at(sx, sy) * wx * wy }
    }
    return total
  }
}
