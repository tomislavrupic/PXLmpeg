import AVFoundation
import AudioToolbox
import CoreVideo
import Foundation
import PXLMedia
import VideoToolbox

public enum FixtureFactory {
  public static func make(
    at url: URL, width: Int = 1920, height: Int = 1080, frames: Int = 24,
    tagged: Bool = true, rotate: Bool = false, audio: Bool = false, audioFrames: Int? = nil,
    reorder: Bool = false, startFrame: Int = 0, frameDurations: [Int]? = nil,
    codec: AVVideoCodecType = .h264, rotationDegrees: Int = 0, bitDepth: Int = 8,
    colourSpace: VideoColourSpace = .bt709, audioPCM: Bool = false,
    audioStartSample: Int = 0, audioChannelLayoutTag: AudioChannelLayoutTag? = nil
  ) throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    var settings: [String: Any] = [
      AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: [
        AVVideoExpectedSourceFrameRateKey: 24, AVVideoAllowFrameReorderingKey: reorder,
        AVVideoAverageBitRateKey: 8_000_000,
        AVVideoProfileLevelKey: codec == .hevc
          ? (bitDepth == 10
            ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String
          : AVVideoProfileLevelH264HighAutoLevel,
      ],
    ]
    let prores = [.proRes422Proxy, .proRes422LT, .proRes422, .proRes422HQ, .proRes4444].contains(
      codec)
    if prores { settings.removeValue(forKey: AVVideoCompressionPropertiesKey) }
    if tagged {
      settings[AVVideoColorPropertiesKey] = [
        AVVideoColorPrimariesKey: colourSpace == .bt709
          ? AVVideoColorPrimaries_ITU_R_709_2 : AVVideoColorPrimaries_ITU_R_2020,
        AVVideoTransferFunctionKey: colourSpace == .bt709
          ? AVVideoTransferFunction_ITU_R_709_2
          : (colourSpace == .hlg2020
            ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_SMPTE_ST_2084_PQ),
        AVVideoYCbCrMatrixKey: colourSpace == .bt709
          ? AVVideoYCbCrMatrix_ITU_R_709_2 : AVVideoYCbCrMatrix_ITU_R_2020,
      ]
    }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    if rotate || rotationDegrees != 0 {
      input.transform = CGAffineTransform(
        rotationAngle: Double(rotate ? 90 : rotationDegrees) * .pi / 180)
    }
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: bitDepth == 10
          ? (prores
            ? kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
          : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      ])
    writer.add(input)
    var audioInput: AVAssetWriterInput?
    if audio {
      var audioSettings: [String: Any] =
        audioPCM
        ? [
          AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
          AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        : [
          AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
          AVEncoderBitRateKey: 128000,
        ]
      if let tag = audioChannelLayoutTag {
        var layout = AudioChannelLayout(
          mChannelLayoutTag: tag, mChannelBitmap: AudioChannelBitmap(rawValue: 0),
          mNumberChannelDescriptions: 0, mChannelDescriptions: AudioChannelDescription())
        audioSettings[AVChannelLayoutKey] = withUnsafeBytes(of: &layout) { Data($0) }
      }
      let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      writer.add(a)
      audioInput = a
    }
    guard writer.startWriting() else { throw writer.error! }
    writer.startSession(atSourceTime: .zero)
    let audioPump = audioInput.map {
      FixtureAudioPump(
        input: $0, writer: writer, totalSamples: (audioFrames ?? frames) * 2000,
        distinctChannels: audioPCM, startSample: audioStartSample)
    }
    audioPump?.start()
    defer { if writer.status != .completed { writer.cancelWriting() } }
    var framePosition = startFrame
    for i in 0..<frames {
      let units = frameDurations.map { $0[i % $0.count] } ?? 1
      let deadline = Date().addingTimeInterval(20)
      while !input.isReadyForMoreMediaData {
        if writer.status == .failed { throw writer.error! }
        guard Date() < deadline else {
          throw NSError(domain: "fixture timeout at frame \(i)", code: 1)
        }
        Thread.sleep(forTimeInterval: 0.001)
      }
      var pixel: CVPixelBuffer?
      guard
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixel)
          == kCVReturnSuccess, let pixel
      else {
        throw NSError(domain: "fixture buffer", code: 1)
      }
      CVPixelBufferLockBaseAddress(pixel, [])
      if bitDepth == 10 {
        let y = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) / 2
        for row in 0..<height {
          for x in 0..<width { y[row * stride + x] = UInt16(64 + (row * 7 + x + i * 3) % 936) << 6 }
        }
        let uv = CVPixelBufferGetBaseAddressOfPlane(pixel, 1)!.assumingMemoryBound(to: UInt16.self)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 1) / 2
        for row in 0..<(prores ? height : height / 2) {
          for x in 0..<width {
            uv[row * uvStride + x] =
              UInt16(prores ? (256 + (row % 2) * 512 + (x % 2) * 40) : 512 + x % 7) << 6
          }
        }
      } else {
        let y = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
        for row in 0..<height {
          memset(y.advanced(by: row * stride), Int32(16 + ((row / 8 + i * 3) % 220)), width)
        }
        memset(
          CVPixelBufferGetBaseAddressOfPlane(pixel, 1)!, 128,
          CVPixelBufferGetBytesPerRowOfPlane(pixel, 1) * (height / 2))
      }
      CVPixelBufferUnlockBaseAddress(pixel, [])
      if tagged {
        CVBufferSetAttachment(
          pixel, kCVImageBufferColorPrimariesKey,
          colourSpace == .bt709
            ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_ITU_R_2020,
          .shouldPropagate)
        CVBufferSetAttachment(
          pixel, kCVImageBufferTransferFunctionKey,
          colourSpace == .bt709
            ? kCVImageBufferTransferFunction_ITU_R_709_2
            : (colourSpace == .hlg2020
              ? kCVImageBufferTransferFunction_ITU_R_2100_HLG
              : kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ),
          .shouldPropagate)
        CVBufferSetAttachment(
          pixel, kCVImageBufferYCbCrMatrixKey,
          colourSpace == .bt709
            ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_2020,
          .shouldPropagate)
      }
      CVBufferSetAttachment(
        pixel, kCVImageBufferChromaLocationTopFieldKey,
        kCVImageBufferChromaLocation_Left, .shouldPropagate)
      if colourSpace != .bt709 {
        CVBufferSetAttachment(
          pixel, kCVImageBufferAmbientViewingEnvironmentKey,
          Data([0x00, 0x2f, 0xe9, 0xa0, 0x3d, 0x13, 0x40, 0x42]) as CFData, .shouldPropagate)
      }
      var format: CMVideoFormatDescription?
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format)
      var timing = CMSampleTimingInfo(
        duration: CMTime(value: Int64(units), timescale: 24),
        presentationTimeStamp: CMTime(value: Int64(framePosition), timescale: 24),
        decodeTimeStamp: .invalid)
      var sample: CMSampleBuffer?
      guard
        CMSampleBufferCreateReadyWithImageBuffer(
          allocator: nil, imageBuffer: pixel, formatDescription: format!, sampleTiming: &timing,
          sampleBufferOut: &sample) == noErr,
        input.append(sample!)
      else { throw writer.error ?? NSError(domain: "fixture sample", code: 1) }
      framePosition += units
    }
    input.markAsFinished()
    try audioPump?.wait()
    let videoEnd = CMTime(value: Int64(framePosition), timescale: 24)
    let audioEnd = CMTime(
      value: Int64(audioStartSample + (audioFrames ?? frames) * 2000), timescale: 48000)
    writer.endSession(atSourceTime: audio ? max(videoEnd, audioEnd) : videoEnd)
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
    guard writer.status == .completed else { throw writer.error! }
  }
  fileprivate static func pcm(position: Int, count: Int, distinctChannels: Bool = false) throws
    -> CMSampleBuffer
  {
    var asbd = AudioStreamBasicDescription(
      mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
      mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32,
      mReserved: 0)
    var format: CMAudioFormatDescription?
    guard
      CMAudioFormatDescriptionCreate(
        allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
        magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr
    else { throw NSError(domain: "fixture audio format", code: 1) }
    var values = [Float](repeating: 0, count: count * 2)
    for i in 0..<count {
      let v = Float(sin(Double(position + i) * 2 * Double.pi * 440 / 48000) * 0.2)
      values[i * 2] = v
      values[i * 2 + 1] = distinctChannels ? -v : v
    }
    var block: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: values.count * 4, blockAllocator: nil,
        customBlockSource: nil, offsetToData: 0, dataLength: values.count * 4, flags: 0,
        blockBufferOut: &block) == noErr
    else { throw NSError(domain: "fixture audio buffer", code: 1) }
    _ = values.withUnsafeBytes {
      CMBlockBufferReplaceDataBytes(
        with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: $0.count)
    }
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 48000),
      presentationTimeStamp: CMTime(value: Int64(position), timescale: 48000),
      decodeTimeStamp: .invalid)
    var size = 8
    var sample: CMSampleBuffer?
    guard
      CMSampleBufferCreateReady(
        allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample
    else { throw NSError(domain: "fixture audio sample", code: 1) }
    return sample
  }
  public static func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PXL-test-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }
}

// Test-only producer: input belongs exclusively to its queue. Group completion
// publishes error back to the waiting test thread; writer supports separate input queues.
private final class FixtureAudioPump: @unchecked Sendable {
  let input: AVAssetWriterInput, writer: AVAssetWriter, totalSamples: Int
  let group = DispatchGroup()
  private var error: Error?
  let distinctChannels: Bool
  let startSample: Int
  init(
    input: AVAssetWriterInput, writer: AVAssetWriter, totalSamples: Int,
    distinctChannels: Bool = false, startSample: Int = 0
  ) {
    self.input = input
    self.writer = writer
    self.totalSamples = totalSamples
    self.distinctChannels = distinctChannels
    self.startSample = startSample
  }
  func start() {
    group.enter()
    DispatchQueue(label: "PXL.audio-fixture").async { [self] in
      defer {
        input.markAsFinished()
        group.leave()
      }
      do {
        var position = 0
        while position < totalSamples {
          let deadline = Date().addingTimeInterval(20)
          while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else {
              throw writer.error ?? NSError(domain: "fixture writer", code: 1)
            }
            guard Date() < deadline else { throw NSError(domain: "fixture audio timeout", code: 1) }
            Thread.sleep(forTimeInterval: 0.001)
          }
          let count = min(1024, totalSamples - position)
          guard
            input.append(
              try FixtureFactory.pcm(
                position: position + startSample, count: count, distinctChannels: distinctChannels))
          else {
            throw writer.error ?? NSError(domain: "fixture audio append", code: 1)
          }
          position += count
        }
      } catch { self.error = error }
    }
  }
  func wait() throws {
    group.wait()
    if let error { throw error }
  }
}
