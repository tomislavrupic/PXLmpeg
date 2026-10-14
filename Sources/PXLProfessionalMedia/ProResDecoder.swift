import CoreMedia
import CoreVideo
import Foundation
import PXLAppleMedia
import PXLMedia
import VideoToolbox

private final class ProResResult {
  var pixel: CVPixelBuffer?
  var status: OSStatus = noErr
  var calls = 0
  var flags: VTDecodeInfoFlags = []
}

/// All use and teardown confined to the professional session's serial worker.
final class ProResDecoder {
  private let session: VTDecompressionSession
  let hardware: Bool
  let reservedFrameBytes: Int
  private let width: Int, height: Int

  init(source: ProfessionalSource, policy: ProfessionalHardwarePolicy) throws {
    width = source.descriptor.width
    height = source.descriptor.height
    // Conservative aligned storage allowance for two full-height 16-bit planes.
    reservedFrameBytes = Self.frameReservationBytes(width: width, height: height)
    var callback = VTDecompressionOutputCallbackRecord(
      decompressionOutputCallback: {
        _, ref, status, flags, image, _, _ in
        guard let ref else { return }
        let result = Unmanaged<ProResResult>.fromOpaque(ref).takeUnretainedValue()
        result.pixel = image
        result.status = status
        result.calls += 1
        result.flags = flags
      }, decompressionOutputRefCon: nil)
    var created: VTDecompressionSession?
    let specification: [String: Any] =
      policy == .requireHardware
      ? [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true]
      : [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true]
    let status = VTDecompressionSessionCreate(
      allocator: nil, formatDescription: source.format,
      decoderSpecification: specification as CFDictionary,
      imageBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String:
          kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      ] as CFDictionary, outputCallback: &callback, decompressionSessionOut: &created)
    try Self.checkCreationStatus(status)
    guard let created else {
      throw MediaError(.codecFailure, stage: "prores-decode", "Missing decoder")
    }
    do {
      let flag =
        try copyVTProperty(
          created, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder)
        as? NSNumber
      guard let flag else {
        throw MediaError(
          .hardwareUnavailable, stage: "prores-decode",
          "Decoder hardware participation is unavailable")
      }
      hardware = flag.boolValue
      if policy == .requireHardware, !hardware {
        throw MediaError(
          .hardwareUnavailable, stage: "prores-decode",
          "Hardware decode was required but not selected")
      }
    } catch {
      VTDecompressionSessionInvalidate(created)
      throw error
    }
    session = created
  }
  static func checkCreationStatus(_ status: OSStatus) throws {
    if status == kVTCouldNotFindVideoDecoderErr || status == kVTVideoDecoderNotAvailableNowErr {
      throw MediaError(.hardwareUnavailable, stage: "prores-decode-create",
                       "ProRes decoder unavailable (VideoToolbox status \(status))")
    }
    try checkVT(status, stage: "prores-decode-create")
  }
  static func frameReservationBytes(width: Int, height: Int) -> Int {
    ((width * 2 + 255) / 256 * 256) * height * 2 + 65536
  }
  func decode(_ sample: CMSampleBuffer) throws -> CVPixelBuffer {
    let result = ProResResult()
    // No async/temporal flags: VT's synchronous callback lifetime contract.
    try checkVT(
      VTDecompressionSessionDecodeFrame(
        session, sampleBuffer: sample, flags: [],
        frameRefcon: Unmanaged.passUnretained(result).toOpaque(), infoFlagsOut: nil),
      stage: "prores-decode")
    try checkVT(result.status, stage: "prores-callback")
    guard result.calls == 1, !result.flags.contains(.frameDropped), let pixel = result.pixel,
      CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      CVPixelBufferGetWidth(pixel) == width, CVPixelBufferGetHeight(pixel) == height,
      CVPixelBufferGetPlaneCount(pixel) == 2, CVPixelBufferGetHeightOfPlane(pixel, 1) == height,
      MediaLease.byteCount(pixel) <= reservedFrameBytes
    else {
      throw MediaError(
        .codecFailure, stage: "prores-decode", "Missing frame or incompatible ten-bit 4:2:2 surface"
      )
    }
    return pixel
  }
  deinit { VTDecompressionSessionInvalidate(session) }
}
