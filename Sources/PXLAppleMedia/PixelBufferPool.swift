import CoreMedia
import CoreVideo
import Foundation
import PXLMedia

// One preallocated output buffer in the initial single-flight executor. Pool storage
// remains charged between frames. The acquired lease retains this pool until release.
package final class PixelBufferPool {
  private let pool: CVPixelBufferPool
  private let pixel: CVPixelBuffer
  private let storage: Reservation
  private var acquired = false
  package init(width: Int, height: Int, budget: MediaBudget, bitDepth: Int = 8) throws {
    let conservative = PixelContract.storageBytes(width: width, height: height, bitDepth: bitDepth)
    let provisional = try budget.reserve(bytes: conservative, kind: .bytes)
    var p: CVPixelBufferPool?
    let attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: PixelContract(bitDepth: bitDepth).pixelFormat,
      kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    var status = CVPixelBufferPoolCreate(
      nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 1] as CFDictionary,
      attributes as CFDictionary, &p)
    guard status == kCVReturnSuccess, let p else {
      throw MediaError(
        .resourceLimit, stage: "pool", "Cannot create pool", underlyingCode: Int(status))
    }
    var b: CVPixelBuffer?
    status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
      nil, p, [kCVPixelBufferPoolAllocationThresholdKey as String: 1] as CFDictionary, &b)
    guard status == kCVReturnSuccess, let b else {
      throw MediaError(
        .resourceLimit, stage: "pool", "Cannot allocate pool surface", underlyingCode: Int(status))
    }
    guard MediaLease.byteCount(b) <= conservative else {
      throw MediaError(.resourceLimit, stage: "pool", "Surface stride exceeds reserved allocation")
    }
    pool = p
    pixel = b
    storage = provisional
  }
  package func acquire(pts: CMTime, duration: CMTime) throws -> MediaLease {
    guard !acquired else {
      throw MediaError(.resourceLimit, stage: "pool", "Output surface is still in use")
    }
    acquired = true
    return MediaLease(
      pixel: pixel, pts: pts, duration: duration,
      reservation: Reservation { [self] in acquired = false })
  }
}
