import CoreMedia
import CoreVideo
import Foundation
import PXLAppleMedia
import PXLMedia

public struct ProfessionalAssetDescriptor: Codable, Sendable {
  public let width: Int
  public let height: Int
  public let codec: String
  public let bitDepth: Int
  public let chromaSubsampling: String
  /// Nil when the coded primaries/matrix/transfer triplet is not fully declared.
  /// Camera acquisition metadata remains separate from coded color declarations.
  public let colourSpace: VideoColourSpace?
  public let sourceChromaLocation: String?
  public let rotation: DisplayRotation
  public let videoStart: MediaTime
  public let videoDuration: MediaTime
  public let audioSampleRate: Double?
  public let audioChannels: Int?
  public let audioBitDepth: Int?
  public let audioStart: MediaTime?
  public let audioDuration: MediaTime?
  public let audioChannelLayout: Data?
  public let timecodeTracks: Int
}

public enum ProfessionalMedia {
  /// Metadata only. Does not create a decoder or change any source track.
  public static func inspect(_ url: URL) async throws -> ProfessionalAssetDescriptor {
    if url.isFileURL, url.pathExtension.lowercased() == "mxf" { return try MXFSource(url).descriptor }
    return try await ProfessionalSource.open(url).descriptor
  }
}

func mediaTime(_ time: CMTime) throws -> MediaTime {
  guard time.isNumeric else {
    throw MediaError(.timingViolation, stage: "professional-time", "Non-numeric media time")
  }
  return try MediaTime(value: time.value, timescale: time.timescale)
}

public enum ProfessionalHardwarePolicy: String, Codable, Sendable {
  case requireHardware, allowSoftware
}
public struct ProfessionalMediaOptions: Sendable {
  public var memoryBudgetBytes: Int
  public var maximumRetainedVideoFrames: Int
  public var hardwarePolicy: ProfessionalHardwarePolicy
  public init(
    memoryBudgetBytes: Int = 128 * 1024 * 1024,
    maximumRetainedVideoFrames: Int = 2,
    hardwarePolicy: ProfessionalHardwarePolicy = .requireHardware
  ) {
    self.memoryBudgetBytes = memoryBudgetBytes
    self.maximumRetainedVideoFrames = maximumRetainedVideoFrames
    self.hardwarePolicy = hardwarePolicy
  }
  func validate() throws {
    guard (4 * 1024 * 1024...512 * 1024 * 1024).contains(memoryBudgetBytes),
      (1...4).contains(maximumRetainedVideoFrames)
    else {
      throw MediaError(
        .invalidRequest, stage: "professional-options",
        "Budget must be 4–512 MiB; retained frame limit 1–4")
    }
  }
}

/// Retain this entire immutable lease until GPU/consumer completion, not just pixelBuffer.
/// The CVPixelBuffer is read-only by contract; consumer mutation/copies are not accounted here.
public final class ProfessionalVideoFrame: @unchecked Sendable {
  public let pixelBuffer: CVPixelBuffer
  public let presentationTime: MediaTime
  public let duration: MediaTime
  public let generation: UInt64
  private let reservation: Reservation
  init(
    pixel: CVPixelBuffer, pts: CMTime, duration: CMTime, generation: UInt64,
    reservation: Reservation
  ) throws {
    pixelBuffer = pixel
    presentationTime = try mediaTime(pts)
    self.duration = try mediaTime(duration)
    self.generation = generation
    self.reservation = reservation
  }
}
/// Interleaved little-endian Float32 at 48 kHz, with no channel remix.
/// Retain the chunk while using samples. Copies kept after releasing it belong to the consumer.
public final class ProfessionalAudioChunk: @unchecked Sendable {
  public let samples: Data
  public let frameCount: Int
  public let channels: Int
  public let sampleRate: Double = 48000
  public let presentationTime: MediaTime
  public let duration: MediaTime
  public let generation: UInt64
  private let reservation: Reservation
  init(
    samples: Data, frames: Int, channels: Int, pts: CMTime, generation: UInt64,
    reservation: Reservation
  ) throws {
    self.samples = samples
    frameCount = frames
    self.channels = channels
    presentationTime = try mediaTime(pts)
    duration = try MediaTime(value: Int64(frames), timescale: 48000)
    self.generation = generation
    self.reservation = reservation
  }
}
public struct ProfessionalMediaMetrics: Codable, Sendable {
  public let decoderHardware: Bool
  public let ownedMemoryBytes: Int
  public let ownedMemoryPeakBytes: Int
  public let retainedVideoFrames: Int
  public let deliveredVideoFrames: Int
  public let deliveredAudioFrames: Int
}

// Shared admission limits, used both before native setup and by worker reservations.
enum ProfessionalLimits {
  static let packetBytes = 32 * 1024 * 1024
  static let pendingPCMBytes = 1024 * 1024
  static let maximumAudioFrames = 8192
}
