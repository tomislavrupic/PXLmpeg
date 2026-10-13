import Foundation

// Compressed copy has no bitrate, pixel conversion, resize or codec-selection knobs.
public struct RemuxRequest: Codable, Sendable, Equatable {
  public let schemaVersion: Int
  public let id: UUID
  public let source: URL, destination: URL
  public let outputContainer: OutputContainer
  public let audioPolicy: AudioPolicy
  public let timedMetadataPolicy: TimedMetadataPolicy
  public let memoryBudgetBytes: Int
  public init(
    id: UUID = UUID(), source: URL, destination: URL, outputContainer: OutputContainer = .mov,
    audioPolicy: AudioPolicy = .copy, timedMetadataPolicy: TimedMetadataPolicy = .reject,
    memoryBudgetBytes: Int = 67_108_864
  ) throws {
    let checked = try JobRequest(
      id: id, source: source, destination: destination, videoBitrate: 1,
      memoryBudgetBytes: memoryBudgetBytes)
    schemaVersion = 1
    self.id = id
    self.source = checked.source
    self.destination = checked.destination
    self.outputContainer = outputContainer
    self.audioPolicy = audioPolicy
    self.timedMetadataPolicy = timedMetadataPolicy
    self.memoryBudgetBytes = memoryBudgetBytes
  }
  public init(from decoder: any Decoder) throws {
    let all = try decoder.container(keyedBy: AnyRemuxKey.self)
    let allowed = Set([
      "schemaVersion", "id", "source", "destination", "outputContainer", "audioPolicy",
      "timedMetadataPolicy", "memoryBudgetBytes",
    ])
    guard Set(all.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
      throw MediaError(
        .invalidRequest, stage: "request",
        "Unknown remux field; compressed copy has no processing options")
    }
    let c = try decoder.container(keyedBy: CodingKeys.self)
    guard try c.decode(Int.self, forKey: .schemaVersion) == 1 else {
      throw MediaError(.invalidRequest, stage: "request", "Unsupported remux schema")
    }
    try self.init(
      id: c.decode(UUID.self, forKey: .id), source: c.decode(URL.self, forKey: .source),
      destination: c.decode(URL.self, forKey: .destination),
      outputContainer: c.decodeIfPresent(OutputContainer.self, forKey: .outputContainer) ?? .mov,
      audioPolicy: c.decodeIfPresent(AudioPolicy.self, forKey: .audioPolicy) ?? .copy,
      timedMetadataPolicy: c.decodeIfPresent(TimedMetadataPolicy.self, forKey: .timedMetadataPolicy)
        ?? .reject,
      memoryBudgetBytes: c.decodeIfPresent(Int.self, forKey: .memoryBudgetBytes) ?? 67_108_864)
  }
  public static func decodeStrict(_ data: Data) throws -> Self {
    do { return try JSONDecoder().decode(Self.self, from: data) } catch let e as MediaError {
      throw e
    } catch { throw MediaError(.invalidRequest, stage: "request", "Invalid remux JSON: \(error)") }
  }
  public func normalizedData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }
}
private struct AnyRemuxKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { nil }
}
