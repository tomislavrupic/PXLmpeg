import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import PXLAppleMedia
import PXLMedia

/// Immutable metadata/track handles; mutable readers are created on the session worker only.
final class ProfessionalSource: @unchecked Sendable {
  private let identity: ProfessionalSourceIdentity
  let url: URL
  let asset: AVURLAsset
  let video: AVAssetTrack
  let audio: AVAssetTrack?
  let format: CMVideoFormatDescription
  let videoRange: CMTimeRange
  let descriptor: ProfessionalAssetDescriptor

  init(
    url: URL, asset: AVURLAsset, video: AVAssetTrack, audio: AVAssetTrack?,
    format: CMVideoFormatDescription, videoRange: CMTimeRange,
    descriptor: ProfessionalAssetDescriptor, identity: ProfessionalSourceIdentity
  ) {
    self.identity = identity
    self.url = url
    self.asset = asset
    self.video = video
    self.audio = audio
    self.format = format
    self.videoRange = videoRange
    self.descriptor = descriptor
  }

  static func open(_ url: URL) async throws -> ProfessionalSource {
    guard url.isFileURL, url.pathExtension.lowercased() == "mov" else {
      throw unsupported("Professional ingest requires a local MOV")
    }
    let original = try ProfessionalSourceIdentity.read(url)
    let asset = AVURLAsset(url: url)
    do {
      guard try await !asset.load(.hasProtectedContent) else {
        throw unsupported("Protected content")
      }
      let tracks = try await asset.load(.tracks)
      let videos = tracks.filter { $0.mediaType == .video }
      let audios = tracks.filter { $0.mediaType == .audio }
      guard videos.count == 1, audios.count <= 1,
        tracks.allSatisfy({ [.video, .audio, .metadata, .timecode].contains($0.mediaType) })
      else {
        throw unsupported(
          "Requires one ProRes video and at most one PCM audio track; metadata/timecode may accompany them"
        )
      }
      let video = videos[0]
      let formats = try await video.load(.formatDescriptions)
      let codecs = [
        kCMVideoCodecType_AppleProRes422Proxy, kCMVideoCodecType_AppleProRes422LT,
        kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ,
      ]
      guard formats.count == 1, let format = formats.first,
        codecs.contains(CMFormatDescriptionGetMediaSubType(format))
      else {
        throw unsupported("Only ProRes Proxy/LT/422/HQ; 4444/XQ/RAW are separate work")
      }
      let d = CMVideoFormatDescriptionGetDimensions(format)
      let width = Int(d.width)
      let height = Int(d.height)
      guard (16...4096).contains(width), (16...4096).contains(height),
        width % 2 == 0, height % 2 == 0
      else { throw unsupported("Requires even 16–4096 dimensions") }
      let ext = (CMFormatDescriptionGetExtensions(format) as NSDictionary?) ?? NSDictionary()
      guard ext[kCMFormatDescriptionExtension_FieldCount] as? Int == 1 else {
        throw unsupported("Explicit progressive field metadata required")
      }
      guard ext[kCMFormatDescriptionExtension_FullRangeVideo] as? Bool != true else {
        throw unsupported("Full-range ProRes is outside this contract")
      }
      if let aspect = ext[kCMFormatDescriptionExtension_PixelAspectRatio] as? NSDictionary {
        guard let h = aspect[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing] as? Int,
          let v = aspect[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing] as? Int,
          h > 0, h == v
        else { throw unsupported("Square pixels required") }
      }
      let aperture = CMVideoFormatDescriptionGetCleanAperture(format, originIsAtTopLeft: true)
      guard aperture.origin == .zero, aperture.width == CGFloat(width),
        aperture.height == CGFloat(height)
      else {
        throw unsupported("Full clean aperture required")
      }
      let primaries = ext[kCMFormatDescriptionExtension_ColorPrimaries] as? String
      let matrix = ext[kCMFormatDescriptionExtension_YCbCrMatrix] as? String
      let transfer = ext[kCMFormatDescriptionExtension_TransferFunction] as? String
      let colour: VideoColourSpace
      if primaries == "ITU_R_709_2", matrix == "ITU_R_709_2", transfer == "ITU_R_709_2" {
        colour = .bt709
      } else if primaries == "ITU_R_2020", matrix == "ITU_R_2020", transfer == "ITU_R_2100_HLG" {
        colour = .hlg2020
      } else if primaries == "ITU_R_2020", matrix == "ITU_R_2020", transfer == "SMPTE_ST_2084_PQ" {
        colour = .pq2020
      } else {
        throw unsupported("Tagged BT.709 or BT.2020 HLG/PQ required; no implicit colour assumption")
      }
      let range = try await video.load(.timeRange)
      try AssetInput.validateReadOnlyVideoRange(range)
      let rotation = try DisplayTransform.rotation(
        try await video.load(.preferredTransform), width: width, height: height)
      var rate: Double?
      var channels: Int?
      var depth: Int?
      var audioStart: MediaTime?
      var audioDuration: MediaTime?
      var layout: Data?
      if let audio = audios.first {
        let formats = try await audio.load(.formatDescriptions)
        guard formats.count == 1, let af = formats.first,
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(af)?.pointee,
          asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate == 48000,
          [1, 2].contains(asbd.mChannelsPerFrame),
          [16, 24, 32].contains(asbd.mBitsPerChannel),
          asbd.mFormatFlags & kAudioFormatFlagIsFloat == 0 || asbd.mBitsPerChannel == 32
        else {
          throw unsupported(
            "Only mono/stereo 48 kHz integer 16/24/32-bit or float32 PCM is admitted")
        }
        rate = asbd.mSampleRate
        channels = Int(asbd.mChannelsPerFrame)
        depth = Int(asbd.mBitsPerChannel)
        let ar = try await audio.load(.timeRange)
        try AssetInput.validateReadOnlyVideoRange(ar)
        audioStart = try mediaTime(ar.start)
        audioDuration = try mediaTime(ar.duration)
        var size = 0
        if let pointer = CMAudioFormatDescriptionGetChannelLayout(af, sizeOut: &size), size > 0 {
          let tag = pointer.pointee.mChannelLayoutTag
          guard tag == (channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo)
          else {
            throw unsupported(
              "Only standard mono/stereo channel layouts; custom layouts need explicit mapping")
          }
          layout = Data(bytes: pointer, count: size)
        }
      }
      let subtype = CMFormatDescriptionGetMediaSubType(format)
      let codec = String(
        bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: subtype >> $0) }, encoding: .ascii)!
      guard try ProfessionalSourceIdentity.read(url) == original else {
        throw MediaError(
          .sourceChanged, stage: "professional-inspect", "Source changed during metadata load")
      }
      return ProfessionalSource(
        url: url, asset: asset, video: video, audio: audios.first,
        format: format, videoRange: range,
        descriptor: ProfessionalAssetDescriptor(
          width: width, height: height, codec: codec, bitDepth: 10, chromaSubsampling: "4:2:2",
          colourSpace: colour,
          sourceChromaLocation: ext[kCMFormatDescriptionExtension_ChromaLocationTopField]
            as? String,
          rotation: rotation, videoStart: try mediaTime(range.start),
          videoDuration: try mediaTime(range.duration),
          audioSampleRate: rate, audioChannels: channels, audioBitDepth: depth,
          audioStart: audioStart, audioDuration: audioDuration, audioChannelLayout: layout,
          timecodeTracks: tracks.filter { $0.mediaType == .timecode }.count), identity: original)
    } catch let error as MediaError { throw error } catch {
      throw MediaError(
        .ioFailure, stage: "professional-inspect", "Cannot read MOV metadata: \(error)")
    }
  }
  func checkIdentity() throws {
    guard try ProfessionalSourceIdentity.read(url) == identity else {
      throw MediaError(
        .sourceChanged, stage: "professional-read", "Source identity/size/mtime changed")
    }
  }
  private static func unsupported(_ message: String) -> MediaError {
    MediaError(.unsupportedMedia, stage: "professional-inspect", message)
  }
}

struct ProfessionalSourceIdentity: Equatable, Sendable {
  let size: UInt64, inode: UInt64, device: UInt64
  let modified: Date
  static func read(_ url: URL) throws -> Self {
    let a = try FileManager.default.attributesOfItem(atPath: url.path)
    guard a[.type] as? FileAttributeType == .typeRegular,
      let size = a[.size] as? NSNumber, let inode = a[.systemFileNumber] as? NSNumber,
      let device = a[.systemNumber] as? NSNumber, let modified = a[.modificationDate] as? Date
    else {
      throw MediaError(
        .ioFailure, stage: "professional-source", "Requires a regular local media file")
    }
    return Self(
      size: size.uint64Value, inode: inode.uint64Value, device: device.uint64Value,
      modified: modified)
  }
}
