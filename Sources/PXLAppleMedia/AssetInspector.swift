import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import PXLMedia

// Immutable loaded metadata/handles. After open returns, reader use is transferred
// to one worker; no AVAssetReader or mutable codec state crosses that boundary.
package final class AssetInput: @unchecked Sendable {
  package let asset: AVURLAsset
  package let video: AVAssetTrack
  package let audio: AVAssetTrack?
  package let videoFormat: CMVideoFormatDescription
  package let audioFormat: CMAudioFormatDescription?
  package let contract: PixelContract
  package let videoTimeScale: CMTimeScale
  package let displayTransform: CGAffineTransform
  package let videoEnd: CMTime
  package let descriptor: AssetDescriptor
  private init(
    asset: AVURLAsset, video: AVAssetTrack, audio: AVAssetTrack?,
    videoFormat: CMVideoFormatDescription,
    audioFormat: CMAudioFormatDescription?, contract: PixelContract,
    displayTransform: CGAffineTransform, videoTimeScale: CMTimeScale, videoEnd: CMTime,
    descriptor: AssetDescriptor
  ) {
    self.asset = asset
    self.video = video
    self.audio = audio
    self.videoFormat = videoFormat
    self.audioFormat = audioFormat
    self.descriptor = descriptor
    self.videoEnd = videoEnd
    self.contract = contract
    self.displayTransform = displayTransform
    self.videoTimeScale = videoTimeScale
  }
  package static func open(_ url: URL, colourPolicy: InputColourPolicy = .requireTagged)
    async throws -> AssetInput
  {
    guard url.isFileURL, ["mov", "mp4"].contains(url.pathExtension.lowercased()) else {
      throw MediaError(
        .unsupportedMedia, stage: "inspect", "Only local MOV/MP4 inputs are supported")
    }
    let asset = AVURLAsset(url: url)
    do {
      guard try await !asset.load(.hasProtectedContent) else {
        throw failure("Protected content is unsupported")
      }
      let tracks = try await asset.load(.tracks)
      let videos = tracks.filter { $0.mediaType == .video }
      let audios = tracks.filter { $0.mediaType == .audio }
      guard videos.count == 1, audios.count <= 1,
        tracks.allSatisfy({ [.video, .audio, .metadata].contains($0.mediaType) })
      else {
        throw failure("Expected one video, at most one audio, and optional timed metadata tracks")
      }
      let video = videos[0]
      let transform = try await video.load(.preferredTransform)
      let formats = try await video.load(.formatDescriptions)
      guard formats.count == 1, let format = formats.first,
        [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC, kCMVideoCodecType_DolbyVisionHEVC]
          .contains(
            CMFormatDescriptionGetMediaSubType(format))
      else {
        throw failure("Expected one H.264 or HEVC format")
      }
      let dimensions = CMVideoFormatDescriptionGetDimensions(format)
      let rotation = try DisplayTransform.rotation(
        transform, width: Int(dimensions.width), height: Int(dimensions.height))
      _ = try OutputGeometry(
        sourceWidth: Int(dimensions.width), sourceHeight: Int(dimensions.height), width: nil)
      let ext = (CMFormatDescriptionGetExtensions(format) as NSDictionary?) ?? NSDictionary()
      var assumedColour = false
      let taggedPrimaries = ext[kCMFormatDescriptionExtension_ColorPrimaries] as? String
      let taggedTransfer = ext[kCMFormatDescriptionExtension_TransferFunction] as? String
      let taggedMatrix = ext[kCMFormatDescriptionExtension_YCbCrMatrix] as? String
      let colourSpace: VideoColourSpace
      if taggedPrimaries == "ITU_R_2020", taggedMatrix == "ITU_R_2020",
        ["ITU_R_2100_HLG", "SMPTE_ST_2084_PQ"].contains(taggedTransfer ?? "")
      {
        colourSpace = taggedTransfer == "ITU_R_2100_HLG" ? .hlg2020 : .pq2020
      } else {
        colourSpace = .bt709
        for key in [
          kCMFormatDescriptionExtension_ColorPrimaries,
          kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionExtension_YCbCrMatrix,
        ] {
          if ext[key] == nil && colourPolicy == .assumeBT709Limited {
            assumedColour = true
          } else if ext[key] as? String != "ITU_R_709_2" {
            throw failure("Missing or conflicting SDR/HDR colour metadata")
          }
        }
      }
      let range = ext[kCMFormatDescriptionExtension_FullRangeVideo] as? Bool
      if range == true { throw failure("Full-range video is unsupported") }
      if range == nil {
        guard !colourSpace.isHDR, colourPolicy == .assumeBT709Limited else {
          throw failure("Explicit limited-range video required")
        }
        assumedColour = true
      }
      guard ext[kCMFormatDescriptionExtension_FieldCount] as? Int == 1 else {
        throw failure("Interlaced media is unsupported")
      }
      let hevc = CMFormatDescriptionGetMediaSubType(format) != kCMVideoCodecType_H264
      let stream =
        try hevc ? HEVCFormat.streamInfo(format: format) : H264Format.streamInfo(format: format)
      guard stream.width == Int(dimensions.width), stream.height == Int(dimensions.height) else {
        throw failure("SPS and container dimensions disagree")
      }
      guard !colourSpace.isHDR || (hevc && stream.bitDepth == 10) else {
        throw failure("HDR requires ten-bit HEVC")
      }
      var metadata: [String: Data] = [:]
      for (key, size) in PixelContract.metadataKeys {
        if let value = ext[key] {
          guard let data = value as? Data, data.count == size else {
            throw failure("Invalid HDR metadata length")
          }
          metadata[key as String] = data
        }
      }
      let atoms =
        ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? NSDictionary
      let dynamicAtom = atoms?["dvvC"] ?? atoms?["dvcC"]
      var hasDynamicHDR = false
      if let dynamicAtom {
        guard let data = dynamicAtom as? Data else {
          throw failure("Invalid Dolby Vision configuration")
        }
        hasDynamicHDR = try DolbyVisionConfiguration.validate(data, colourSpace: colourSpace)
      } else if CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_DolbyVisionHEVC {
        throw failure("Dolby Vision sample entry requires a supported configuration")
      }
      let contract = PixelContract(
        bitDepth: stream.bitDepth, colourSpace: colourSpace, staticMetadata: metadata)
      try validateChroma(ext[kCMFormatDescriptionExtension_ChromaLocationTopField] as? String)
      if let aspect = ext[kCMFormatDescriptionExtension_PixelAspectRatio] as? NSDictionary,
        let h = aspect[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing] as? Int,
        let v = aspect[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing] as? Int, h != v
      {
        throw failure("Square pixels required")
      }
      let aperture = CMVideoFormatDescriptionGetCleanAperture(format, originIsAtTopLeft: true)
      guard aperture.origin == .zero, aperture.width == CGFloat(dimensions.width),
        aperture.height == CGFloat(dimensions.height)
      else {
        throw failure("Full-frame clean aperture required")
      }
      var audioFormat: CMAudioFormatDescription?
      var rate: Double?
      var channels: Int?
      if let audio = audios.first {
        let f = try await audio.load(.formatDescriptions)
        guard f.count == 1, let af = f.first,
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(af)?.pointee,
          asbd.mFormatID == kAudioFormatMPEG4AAC, [44100.0, 48000.0].contains(asbd.mSampleRate),
          [1, 2].contains(asbd.mChannelsPerFrame)
        else { throw failure("Only mono/stereo AAC-LC at 44.1/48 kHz is supported") }
        audioFormat = af
        rate = asbd.mSampleRate
        channels = Int(asbd.mChannelsPerFrame)
      }
      let videoEnd = try await video.load(.timeRange).end
      let duration = try await asset.load(.duration)
      guard duration.isNumeric, duration > .zero else { throw failure("Empty or invalid duration") }
      return AssetInput(
        asset: asset, video: video, audio: audios.first, videoFormat: format,
        audioFormat: audioFormat, contract: contract, displayTransform: transform,
        videoTimeScale: try await video.load(.naturalTimeScale), videoEnd: videoEnd,
        descriptor: AssetDescriptor(
          width: Int(dimensions.width), height: Int(dimensions.height),
          codec: hevc ? "hevc" : "h264",
          duration: try MediaTime(value: duration.value, timescale: duration.timescale),
          hasAudio: !audios.isEmpty,
          audioSampleRate: rate, audioChannels: channels,
          colour: assumedColour
            ? "BT.709 limited, left chroma (missing colour tags explicitly assumed)"
            : "\(colourSpace.rawValue) limited, left chroma",
          maxReorderFrames: stream.maxReorderFrames, rotation: rotation, bitDepth: stream.bitDepth,
          colourSpace: colourSpace, hasDynamicHDR: hasDynamicHDR,
          timedMetadataTracks: tracks.filter { $0.mediaType == .metadata }.count,
          staticHDRMetadata: metadata))
    } catch let e as MediaError { throw e } catch {
      throw MediaError(.ioFailure, stage: "inspect", "Cannot inspect source: \(error)")
    }
  }
  package static func validateChroma(_ chroma: String?) throws {
    guard chroma == "Left" else { throw failure("Explicit left-sited chroma required") }
  }
  private static func failure(_ message: String) -> MediaError {
    MediaError(.unsupportedMedia, stage: "inspect", message)
  }
}
