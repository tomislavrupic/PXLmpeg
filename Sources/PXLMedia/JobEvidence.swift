import Foundation

public enum ErrorCode: String, Codable, Sendable {
  case invalidRequest, unsupportedMedia, unsupportedHardware, hardwareUnavailable, resourceLimit,
    engineBusy,
    sourceChanged, destinationExists, cancelled, ioFailure, codecFailure, gpuFailure,
    timingViolation, noProgress
}
public struct MediaError: Error, LocalizedError, Sendable {
  public let code: ErrorCode
  public let stage: String
  public let message: String
  public let underlyingCode: Int?
  public var receipt: JobReceipt?
  public init(_ code: ErrorCode, stage: String, _ message: String, underlyingCode: Int? = nil) {
    self.code = code
    self.stage = stage
    self.message = message
    self.underlyingCode = underlyingCode
  }
  public var errorDescription: String? { "\(stage): \(message)" }
}
public struct JobProgress: Codable, Sendable {
  public let jobID: UUID
  public let state: String
  public let frames: Int
  public let presentationSeconds: Double
  public init(jobID: UUID, state: String, frames: Int, presentationSeconds: Double) {
    self.jobID = jobID
    self.state = state
    self.frames = frames
    self.presentationSeconds = presentationSeconds
  }
}
public struct JobReceipt: Codable, Sendable {
  public var operation: MediaOperation?
  public var outputContainer: OutputContainer?
  public var firstVideoDecodeTimeOffset: MediaTime?
  public var schemaVersion = 1
  public var engineVersion = PXLVersion.current
  public let jobID: UUID
  public let requestDigest: String
  public var state: String
  public var frames = 0
  public var audioPackets = 0
  public var decoderHardware = false
  public var encoderHardware = false
  public var metalDevice = ""
  public var ownedMemoryPeak = 0
  public var elapsedSeconds = 0.0
  public var processFootprintPeakBytes: UInt64?
  public var output: AssetDescriptor?
  public var errorCode: ErrorCode?
  public var errorMessage: String?
  public var acceptedBitrate: Int?
  public var sourceFingerprintKind = "file identity + size + mtime; not content hash"
  public var notes: [String] = []
  public init(jobID: UUID, requestDigest: String, state: String) {
    self.jobID = jobID
    self.requestDigest = requestDigest
    self.state = state
  }
}
