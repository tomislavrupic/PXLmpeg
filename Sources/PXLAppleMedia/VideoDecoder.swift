import CoreMedia
import CoreVideo
import Foundation
import PXLMedia
import VideoToolbox

package func checkVT(_ status: OSStatus, stage: String) throws {
  guard status == noErr else {
    throw MediaError(
      .codecFailure, stage: stage, "VideoToolbox returned \(status)", underlyingCode: Int(status))
  }
}
package func hardwareFlag(_ session: VTSession, key: CFString) throws -> Bool {
  guard let flag = try copyVTProperty(session, key: key) as? NSNumber, flag.boolValue else {
    throw MediaError(
      .hardwareUnavailable, stage: "hardware", "VideoToolbox did not select hardware acceleration")
  }
  return true
}
// VTSessionCopyProperty uses void* and explicitly transfers a retained CF value.
package func copyVTProperty(_ session: VTSession, key: CFString) throws -> CFTypeRef? {
  var value: Unmanaged<CFTypeRef>?
  try checkVT(
    VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: &value),
    stage: "property:\(key)")
  return value?.takeRetainedValue()
}
private final class DecodedResult {
  var pixel: CVPixelBuffer?
  var status: OSStatus = noErr
  var calls = 0
  var flags: VTDecodeInfoFlags = []
}
package final class VideoDecoder {
  private var session: VTDecompressionSession!
  package let hardware: Bool
  private let width: Int, height: Int
  private let contract: PixelContract
  package init(format: CMVideoFormatDescription, contract: PixelContract = PixelContract()) throws {
    self.contract = contract
    let d = CMVideoFormatDescriptionGetDimensions(format)
    width = Int(d.width)
    height = Int(d.height)
    let attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: contract.pixelFormat,
      kCVPixelBufferMetalCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    var callback = VTDecompressionOutputCallbackRecord(
      decompressionOutputCallback: { _, ref, status, flags, image, _, _ in
        guard let ref else { return }
        let box = Unmanaged<DecodedResult>.fromOpaque(ref).takeUnretainedValue()
        box.pixel = image
        box.status = status
        box.flags = flags
        box.calls += 1
      }, decompressionOutputRefCon: nil)
    var created: VTDecompressionSession?
    try checkVT(
      VTDecompressionSessionCreate(
        allocator: nil, formatDescription: format,
        decoderSpecification: [
          kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true
        ] as CFDictionary,
        imageBufferAttributes: attributes as CFDictionary, outputCallback: &callback,
        decompressionSessionOut: &created), stage: "decode-create")
    guard let created else {
      throw MediaError(.codecFailure, stage: "decode-create", "Missing session")
    }
    do {
      hardware = try hardwareFlag(
        created, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder)
    } catch {
      VTDecompressionSessionInvalidate(created)
      throw error
    }
    session = created
  }
  // flags=[] requires synchronous output callback completion per VideoToolbox's contract.
  // Called only on a dedicated blocking worker, never on Swift's cooperative executor.
  package func decode(_ sample: EncodedSample, budget: MediaBudget) throws -> MediaLease {
    let reserveBytes = PixelContract.storageBytes(
      width: width, height: height, bitDepth: contract.bitDepth)
    let reservation = try budget.reserve(bytes: reserveBytes, kind: .frame)
    let result = DecodedResult()
    try checkVT(
      VTDecompressionSessionDecodeFrame(
        session, sampleBuffer: sample.buffer, flags: [],
        frameRefcon: Unmanaged.passUnretained(result).toOpaque(), infoFlagsOut: nil),
      stage: "decode")
    try checkVT(result.status, stage: "decode-callback")
    guard result.calls == 1, !result.flags.contains(.frameDropped), let pixel = result.pixel,
      CVPixelBufferGetPixelFormatType(pixel) == contract.pixelFormat,
      CVPixelBufferGetWidth(pixel) == width, CVPixelBufferGetHeight(pixel) == height,
      MediaLease.byteCount(pixel) <= reserveBytes
    else {
      throw MediaError(
        .codecFailure, stage: "decode", "Missing/dropped frame or incompatible decoded surface")
    }
    contract.apply(to: pixel)
    return MediaLease(
      pixel: pixel, pts: sample.pts, duration: sample.duration, reservation: reservation)
  }
  deinit { if let session { VTDecompressionSessionInvalidate(session) } }
}
