import Foundation

public struct AssetDescriptor: Codable, Sendable {
  public let width: Int
  public let height: Int
  public let codec: String
  public let duration: MediaTime
  public let hasAudio: Bool
  public let audioSampleRate: Double?
  public let audioChannels: Int?
  public let colour: String
  public let maxReorderFrames: Int?
  public let rotation: DisplayRotation?
  public let bitDepth: Int?
  public let colourSpace: VideoColourSpace?
  public let hasDynamicHDR: Bool?
  public let timedMetadataTracks: Int?
  /// Editor timecode tracks retained in a read-only source, not converted to source PTS.
  public let timecodeTracks: Int?
  public let staticHDRMetadata: [String: Data]?
  public var effectiveBitDepth: Int { bitDepth ?? 8 }
  public var effectiveColourSpace: VideoColourSpace { colourSpace ?? .bt709 }
  public var displayWidth: Int { rotation?.swapsAxes == true ? height : width }
  public var displayHeight: Int { rotation?.swapsAxes == true ? width : height }
  public init(
    width: Int, height: Int, codec: String, duration: MediaTime, hasAudio: Bool,
    audioSampleRate: Double? = nil, audioChannels: Int? = nil,
    colour: String = "BT.709 limited, left chroma", maxReorderFrames: Int? = nil,
    rotation: DisplayRotation? = nil, bitDepth: Int? = nil, colourSpace: VideoColourSpace? = nil,
    hasDynamicHDR: Bool? = nil, timedMetadataTracks: Int? = nil, timecodeTracks: Int? = nil,
    staticHDRMetadata: [String: Data]? = nil
  ) {
    self.width = width
    self.height = height
    self.codec = codec
    self.duration = duration
    self.hasAudio = hasAudio
    self.audioSampleRate = audioSampleRate
    self.audioChannels = audioChannels
    self.colour = colour
    self.maxReorderFrames = maxReorderFrames
    self.rotation = rotation
    self.bitDepth = bitDepth
    self.colourSpace = colourSpace
    self.hasDynamicHDR = hasDynamicHDR
    self.timedMetadataTracks = timedMetadataTracks
    self.timecodeTracks = timecodeTracks
    self.staticHDRMetadata = staticHDRMetadata
  }
}
public struct CapabilityReport: Codable, Sendable {
  public let engineVersion: String
  public let metalDevice: String
  public let supportedRecipe: String
  public let hardwarePolicy: String
  public init(metalDevice: String) {
    engineVersion = PXLVersion.current
    self.metalDevice = metalDevice
    supportedRecipe =
      "H.264/HEVC Main/Main10 bounded B-frames; BT.709 SDR or 10-bit BT.2020 HLG/PQ → Metal rotation/scale → H.264/HEVC MOV; Main10 requires HEVC; MOV/MP4; native compressed remux; optional AAC copy"
    hardwarePolicy =
      "required for transcoding, actual codec sessions verified; remux bypasses codecs and GPU"
  }
}
