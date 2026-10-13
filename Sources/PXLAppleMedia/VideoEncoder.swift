import CoreMedia
import CoreVideo
import Foundation
import PXLMedia
import VideoToolbox

// Callback and worker share only this locked single-result mailbox. CompleteFrames
// drains all callback work before the worker reads or clears it and before teardown.
private final class EncodedResult {
  private let lock = NSLock()
  private var sample: CMSampleBuffer?
  private var status: OSStatus = noErr
  private var calls = 0
  func reset() {
    lock.withLock {
      sample = nil
      status = noErr
      calls = 0
    }
  }
  func set(_ s: CMSampleBuffer?, _ e: OSStatus) {
    lock.withLock {
      sample = s
      status = e
      calls += 1
    }
  }
  func get() throws -> CMSampleBuffer {
    try lock.withLock {
      try checkVT(status, stage: "encode-callback")
      guard calls == 1, let sample, CMSampleBufferDataIsReady(sample) else {
        throw MediaError(.codecFailure, stage: "encode", "Expected exactly one encoded frame")
      }
      defer { self.sample = nil }
      return sample
    }
  }
}
package final class VideoEncoder {
  private var session: VTCompressionSession!
  private let result = EncodedResult()
  package let hardware: Bool
  package let acceptedBitrate: Int
  private var sequence = 0
  private let pixelFormat: OSType
  package init(
    width: Int, height: Int, bitrate: Int, codec: OutputVideoCodec = .h264,
    contract: PixelContract = PixelContract()
  ) throws {
    self.pixelFormat = contract.pixelFormat
    var created: VTCompressionSession?
    let status = VTCompressionSessionCreate(
      allocator: nil, width: Int32(width), height: Int32(height),
      codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
      encoderSpecification: [
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
      ] as CFDictionary,
      imageBufferAttributes: nil, compressedDataAllocator: nil,
      outputCallback: { ref, _, status, flags, sample in
        guard let ref else { return }
        let box = Unmanaged<EncodedResult>.fromOpaque(ref).takeUnretainedValue()
        box.set(sample, flags.contains(.frameDropped) ? kVTVideoEncoderMalfunctionErr : status)
      }, refcon: Unmanaged.passUnretained(result).toOpaque(), compressionSessionOut: &created)
    try checkVT(status, stage: "encode-create")
    guard let created else {
      throw MediaError(.codecFailure, stage: "encode-create", "Missing session")
    }
    do {
      var settings: [(CFString, CFTypeRef)] = [
        (
          kVTCompressionPropertyKey_ProfileLevel,
          codec == .hevc
            ? (contract.bitDepth == 10
              ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel)
            : kVTProfileLevel_H264_High_AutoLevel
        ),
        (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
        (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate)),
        (kVTCompressionPropertyKey_ColorPrimaries, contract.primaries),
        (kVTCompressionPropertyKey_TransferFunction, contract.transfer),
        (kVTCompressionPropertyKey_YCbCrMatrix, contract.matrix),
      ]
      if contract.bitDepth == 10 {
        settings.append((kVTCompressionPropertyKey_OutputBitDepth, NSNumber(value: 10)))
      }
      if contract.colourSpace.isHDR {
        settings.append(
          (kVTCompressionPropertyKey_HDRMetadataInsertionMode, kVTHDRMetadataInsertionMode_Auto))
        settings.append((kVTCompressionPropertyKey_PreserveDynamicHDRMetadata, kCFBooleanFalse))
      }
      for (cvKey, vtKey) in [
        (
          kCVImageBufferMasteringDisplayColorVolumeKey,
          kVTCompressionPropertyKey_MasteringDisplayColorVolume
        ),
        (kCVImageBufferContentLightLevelInfoKey, kVTCompressionPropertyKey_ContentLightLevelInfo),
      ] {
        if let data = contract.staticMetadata[cvKey as String] {
          settings.append((vtKey, data as CFData))
        }
      }
      for (key, value) in settings {
        try checkVT(
          VTSessionSetProperty(created, key: key, value: value), stage: "encode-settings:\(key)")
      }
      try checkVT(VTCompressionSessionPrepareToEncodeFrames(created), stage: "encode-prepare")
      hardware = try hardwareFlag(
        created, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder)
      let accepted = try copyVTProperty(created, key: kVTCompressionPropertyKey_AverageBitRate)
      guard let actual = accepted as? NSNumber, actual.intValue == bitrate else {
        throw MediaError(
          .unsupportedHardware, stage: "encode-settings", "Requested bitrate was not accepted")
      }
      acceptedBitrate = actual.intValue
    } catch {
      VTCompressionSessionInvalidate(created)
      throw error
    }
    session = created
  }
  package func encode(_ frame: MediaLease) throws -> EncodedSample {
    guard CVPixelBufferGetPixelFormatType(frame.pixel) == pixelFormat else {
      throw MediaError(
        .codecFailure, stage: "encode", "Frame bit depth differs from encoder contract")
    }
    result.reset()
    try checkVT(
      VTCompressionSessionEncodeFrame(
        session, imageBuffer: frame.pixel, presentationTimeStamp: frame.pts,
        duration: frame.duration, frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil),
      stage: "encode")
    try checkVT(
      VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid),
      stage: "encode-drain")
    let sample = try result.get()
    defer { sequence += 1 }
    return EncodedSample(buffer: sample, sequence: sequence)
  }
  deinit { if let session { VTCompressionSessionInvalidate(session) } }
}
