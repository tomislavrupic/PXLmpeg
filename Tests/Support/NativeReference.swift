import AVFoundation
import CoreVideo
import CryptoKit
import Foundation
import PXLMedia

public struct ReferenceFrame: Sendable, Equatable {
  public let pts: CMTime
  public let duration: CMTime
  public let planeDigests: [String]
  public let displayLumaDigest: String
  public let lumaProbes: [UInt16]
}
// Independent AVFoundation display-order decoding; never calls PXL's reader,
// decoder or reorder queue. Digests ignore stride padding and cover every pixel.
public enum NativeReference {
  public static func frames(at url: URL, rotation: DisplayRotation = .none, bitDepth: Int = 8)
    async throws
    -> [ReferenceFrame]
  {
    let asset = AVURLAsset(url: url)
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    let mediaIntervals = try await track.load(.segments).filter { !$0.isEmpty }.map {
      $0.timeMapping.target
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String:
          (bitDepth == 10
          ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
          : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
      ])
    reader.add(output)
    guard reader.startReading() else { throw reader.error! }
    defer { reader.cancelReading() }
    var result: [ReferenceFrame] = []
    while let sample = output.copyNextSampleBuffer() {
      try autoreleasepool {
        guard let pixel = CMSampleBufferGetImageBuffer(sample) else { return }
        // AVFoundation can synthesize a black image for an initial empty edit.
        // Compare actual media pictures; tests verify the gap itself separately.
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard mediaIntervals.contains(where: { CMTimeRangeContainsTime($0, time: pts) }) else {
          return
        }
        result.append(
          ReferenceFrame(
            pts: CMSampleBufferGetPresentationTimeStamp(sample),
            duration: CMSampleBufferGetDuration(sample), planeDigests: try digests(pixel),
            displayLumaDigest: try orientedLumaDigest(pixel, rotation: rotation),
            lumaProbes: try probes(pixel)))
      }
    }
    if reader.status == .failed { throw reader.error! }
    return result
  }
  public static func orientedLumaDigest(_ pixel: CVPixelBuffer, rotation: DisplayRotation) throws
    -> String
  {
    guard CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else {
      throw NSError(domain: "reference lock", code: 1)
    }
    defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
    let w = CVPixelBufferGetWidth(pixel)
    let h = CVPixelBufferGetHeight(pixel)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
    let data = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt8.self)
    let ow = rotation.swapsAxes ? h : w
    let oh = rotation.swapsAxes ? w : h
    let bytesPerSample =
      CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
      ? 2 : 1
    var row = [UInt8](repeating: 0, count: ow * bytesPerSample)
    var hash = SHA256()
    for y in 0..<oh {
      for x in 0..<ow {
        let sx: Int
        let sy: Int
        switch rotation {
        case .none:
          sx = x
          sy = y
        case .clockwise90:
          sx = y
          sy = h - x - 1
        case .upsideDown:
          sx = w - x - 1
          sy = h - y - 1
        case .clockwise270:
          sx = w - y - 1
          sy = x
        }
        for b in 0..<bytesPerSample {
          row[x * bytesPerSample + b] = data[sy * stride + sx * bytesPerSample + b]
        }
      }
      row.withUnsafeBytes { hash.update(bufferPointer: $0) }
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  private static func probes(_ pixel: CVPixelBuffer) throws -> [UInt16] {
    guard CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else {
      throw NSError(domain: "reference lock", code: 1)
    }
    defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
    let w = CVPixelBufferGetWidth(pixel)
    let h = CVPixelBufferGetHeight(pixel)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
    let data = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt8.self)
    return [(w / 4, h / 4), (3 * w / 4, h / 4), (w / 4, 3 * h / 4), (3 * w / 4, 3 * h / 4)].map {
      CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        ? CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt16.self)[
          $0.1 * stride / 2 + $0.0] >> 6 : UInt16(data[$0.1 * stride + $0.0])
    }
  }
  public static func digests(_ pixel: CVPixelBuffer) throws -> [String] {
    guard CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else {
      throw NSError(domain: "reference pixel lock", code: 1)
    }
    defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
    return (0..<CVPixelBufferGetPlaneCount(pixel)).map { plane in
      let pointer = CVPixelBufferGetBaseAddressOfPlane(pixel, plane)!
      let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, plane)
      let width =
        CVPixelBufferGetWidthOfPlane(pixel, plane) * (plane == 1 ? 2 : 1)
        * (CVPixelBufferGetPixelFormatType(pixel)
          == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ? 2 : 1)
      let height = CVPixelBufferGetHeightOfPlane(pixel, plane)
      var hash = SHA256()
      for y in 0..<height {
        hash.update(
          bufferPointer: UnsafeRawBufferPointer(
            start: pointer.advanced(by: y * stride), count: width))
      }
      return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
  }
}
