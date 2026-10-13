import Foundation

public enum OutputVideoCodec: String, Codable, Sendable { case h264, hevc }
public enum InputColourPolicy: String, Codable, Sendable { case requireTagged, assumeBT709Limited }
public enum TimedMetadataPolicy: String, Codable, Sendable { case reject, discard }
public enum AudioPolicy: String, Codable, Sendable { case copy, drop }
public struct JobRequest: Codable, Sendable, Equatable {
  public let schemaVersion: Int
  public let id: UUID
  public let source: URL
  public let destination: URL
  public let resizeWidth: Int?
  public let outputContainer: OutputContainer
  public let outputCodec: OutputVideoCodec
  public let videoBitrate: Int
  public let audioPolicy: AudioPolicy
  public let timedMetadataPolicy: TimedMetadataPolicy
  public let inputColourPolicy: InputColourPolicy
  public let memoryBudgetBytes: Int
  public init(
    id: UUID = UUID(), source: URL, destination: URL, resizeWidth: Int? = nil,
    videoBitrate: Int, audioPolicy: AudioPolicy = .copy, memoryBudgetBytes: Int = 268_435_456,
    inputColourPolicy: InputColourPolicy = .requireTagged, outputCodec: OutputVideoCodec = .h264,
    timedMetadataPolicy: TimedMetadataPolicy = .reject, outputContainer: OutputContainer = .mov
  ) throws {
    guard source.isFileURL, destination.isFileURL,
      source.host == nil || source.host == "" || source.host == "localhost",
      destination.host == nil || destination.host == "" || destination.host == "localhost",
      !source.path.isEmpty, !destination.path.isEmpty, videoBitrate > 0,
      videoBitrate <= Int(Int32.max),
      (67_108_864...2_147_483_648).contains(memoryBudgetBytes),
      resizeWidth.map({ (16...4096).contains($0) && $0 % 2 == 0 }) ?? true
    else {
      throw MediaError(
        .invalidRequest, stage: "request", "Invalid local path, width, bitrate, or memory budget")
    }
    self.schemaVersion = 1
    self.id = id
    self.source = source.standardizedFileURL
    self.destination = destination.standardizedFileURL
    self.resizeWidth = resizeWidth
    self.videoBitrate = videoBitrate
    self.outputCodec = outputCodec
    self.outputContainer = outputContainer
    self.audioPolicy = audioPolicy
    self.timedMetadataPolicy = timedMetadataPolicy
    self.inputColourPolicy = inputColourPolicy
    self.memoryBudgetBytes = memoryBudgetBytes
  }
  public init(from decoder: any Decoder) throws {
    let all = try decoder.container(keyedBy: AnyKey.self)
    let allowed = Set([
      "schemaVersion", "id", "source", "destination", "resizeWidth", "videoBitrate", "audioPolicy",
      "memoryBudgetBytes", "inputColourPolicy", "outputCodec", "timedMetadataPolicy",
      "outputContainer",
    ])
    guard Set(all.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
      throw MediaError(.invalidRequest, stage: "request", "Unknown request field")
    }
    let c = try decoder.container(keyedBy: CodingKeys.self)
    guard try c.decode(Int.self, forKey: .schemaVersion) == 1 else {
      throw MediaError(.invalidRequest, stage: "request", "Unsupported schema version")
    }
    try self.init(
      id: c.decode(UUID.self, forKey: .id), source: c.decode(URL.self, forKey: .source),
      destination: c.decode(URL.self, forKey: .destination),
      resizeWidth: c.decodeIfPresent(Int.self, forKey: .resizeWidth),
      videoBitrate: c.decode(Int.self, forKey: .videoBitrate),
      audioPolicy: c.decode(AudioPolicy.self, forKey: .audioPolicy),
      memoryBudgetBytes: c.decodeIfPresent(Int.self, forKey: .memoryBudgetBytes) ?? 268_435_456,
      inputColourPolicy: c.decodeIfPresent(InputColourPolicy.self, forKey: .inputColourPolicy)
        ?? .requireTagged,
      outputCodec: c.decodeIfPresent(OutputVideoCodec.self, forKey: .outputCodec) ?? .h264,
      timedMetadataPolicy: c.decodeIfPresent(TimedMetadataPolicy.self, forKey: .timedMetadataPolicy)
        ?? .reject,
      outputContainer: c.decodeIfPresent(OutputContainer.self, forKey: .outputContainer) ?? .mov)
  }
  public static func decodeStrict(_ data: Data) throws -> Self {
    do { return try JSONDecoder().decode(Self.self, from: data) } catch let e as MediaError {
      throw e
    } catch { throw MediaError(.invalidRequest, stage: "request", "Invalid job JSON: \(error)") }
  }
  public func normalizedData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }
}
private struct AnyKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}
public struct EngineConfiguration: Sendable {
  public let defaultMemoryBudgetBytes: Int
  public let noProgressTimeout: TimeInterval
  public init(defaultMemoryBudgetBytes: Int = 268_435_456, noProgressTimeout: TimeInterval = 60)
    throws
  {
    guard (67_108_864...2_147_483_648).contains(defaultMemoryBudgetBytes),
      noProgressTimeout.isFinite, noProgressTimeout > 0
    else {
      throw MediaError(
        .invalidRequest, stage: "configuration", "Invalid budget or watchdog interval")
    }
    self.defaultMemoryBudgetBytes = defaultMemoryBudgetBytes
    self.noProgressTimeout = noProgressTimeout
  }
}
public struct OutputGeometry: Codable, Sendable, Equatable {
  public let width: Int
  public let height: Int
  public init(sourceWidth: Int, sourceHeight: Int, width: Int?) throws {
    let w = width ?? sourceWidth
    guard (16...4096).contains(sourceWidth), (16...4096).contains(sourceHeight),
      (16...4096).contains(w), sourceWidth % 2 == 0, sourceHeight % 2 == 0, w % 2 == 0
    else {
      throw MediaError(
        .unsupportedMedia, stage: "geometry", "Dimensions must be even and in 16...4096")
    }
    let h = ((sourceHeight * w + sourceWidth) / (2 * sourceWidth)) * 2
    guard (16...4096).contains(h) else {
      throw MediaError(
        .unsupportedMedia, stage: "geometry", "Resized height outside supported range")
    }
    self.width = w
    self.height = h
  }
}
