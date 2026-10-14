import Foundation
import PXLMedia

public enum SemanticComputePolicy: String, Codable, Sendable, CaseIterable {
  case cpuOnly, cpuAndNeuralEngine, all
}
public struct SamplingOptions: Codable, Sendable {
  public let intervalSeconds: Double
  public let maximumSamplesPerSource: Int
  public init(intervalSeconds: Double = 1, maximumSamplesPerSource: Int = 256) throws {
    guard intervalSeconds.isFinite, (0.1...60).contains(intervalSeconds),
      (1...4096).contains(maximumSamplesPerSource)
    else {
      throw analysisError("Interval must be 0.1...60 seconds and sample limit 1...4096")
    }
    self.intervalSeconds = intervalSeconds
    self.maximumSamplesPerSource = maximumSamplesPerSource
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      intervalSeconds: c.decode(Double.self, forKey: .intervalSeconds),
      maximumSamplesPerSource: c.decode(Int.self, forKey: .maximumSamplesPerSource))
  }
}
public struct IndexedSource: Codable, Sendable {
  public let url: URL
  public let sha256: String
  public let asset: AssetDescriptor
  public let videoStartSeconds: Double
  public let videoEndSeconds: Double
  public let truncated: Bool
  public let samplingBackend: String
}
public struct FrameEmbedding: Codable, Sendable {
  public let sourceIndex: Int
  public let requestedTime: MediaTime
  public let actualTime: MediaTime
  public let vector: [Float]
  public let inferenceMilliseconds: Double
}
public struct SemanticIndex: Codable, Sendable {
  public static let preprocessing = "nativeVT-BT709-or-system-forceSDR-sRGB-centerCrop256-v1"
  public let schemaVersion: Int
  public let modelID: String
  public let modelName: String
  public let preprocessing: String
  public let computePolicy: SemanticComputePolicy
  public let sampling: SamplingOptions
  public let inputColourPolicy: InputColourPolicy
  public let sources: [IndexedSource]
  public let frames: [FrameEmbedding]
  public let elapsedMilliseconds: Double

  public func validate() throws {
    guard schemaVersion == 1, Self.isDigest(modelID), ["s0", "s2"].contains(modelName),
      preprocessing == Self.preprocessing, (1...32).contains(sources.count),
      (1...4096).contains(frames.count), elapsedMilliseconds.isFinite,
      elapsedMilliseconds >= 0
    else { throw analysisError("Invalid or incompatible index") }
    var last: [Int: MediaTime] = [:]
    for source in sources {
      guard source.url.isFileURL, Self.isDigest(source.sha256),
        source.videoStartSeconds.isFinite, source.videoEndSeconds.isFinite,
        source.videoStartSeconds >= 0, source.videoEndSeconds > source.videoStartSeconds,
        ["assetImageGenerator-forceSDR", "nativeVT-explicitBT709", "nativeVT-BT709"].contains(
          source.samplingBackend)
      else { throw analysisError("Invalid source identity or video range") }
    }
    for f in frames {
      guard sources.indices.contains(f.sourceIndex), f.vector.count == 512,
        f.inferenceMilliseconds.isFinite, f.inferenceMilliseconds >= 0
      else {
        throw analysisError("Invalid frame record")
      }
      let s = sources[f.sourceIndex]
      guard f.actualTime.seconds >= s.videoStartSeconds - 0.05,
        f.actualTime.seconds < s.videoEndSeconds,
        f.requestedTime.seconds >= s.videoStartSeconds,
        f.requestedTime.seconds < s.videoEndSeconds,
        last[f.sourceIndex].map({ $0 < f.actualTime }) ?? true
      else {
        throw analysisError("Invalid or repeated sample timestamp")
      }
      let normalized = try Embedding.normalized(f.vector)
      guard zip(normalized, f.vector).allSatisfy({ abs($0 - $1) < 0.001 }) else {
        throw analysisError("Stored embedding must be normalized")
      }
      last[f.sourceIndex] = f.actualTime
    }
  }

  public static func read(from url: URL) throws -> Self {
    guard url.isFileURL else { throw analysisError("Index must be local") }
    let data = try boundedData(at: url, maximum: 32 * 1024 * 1024)
    let index = try JSONDecoder().decode(Self.self, from: data)
    try index.validate()
    return index
  }
  public func write(to url: URL) throws {
    guard url.isFileURL,
      !sources.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL })
    else {
      throw analysisError("Sidecar must be a new local file")
    }
    try validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(self)
    guard data.count <= 32 * 1024 * 1024 else { throw analysisError("Index exceeds 32 MiB") }
    try publishNew(data, to: url)
  }
  static func isDigest(_ s: String) -> Bool {
    s.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}
public struct SearchHit: Codable, Sendable {
  public let source: URL
  public let sourceSHA256: String
  public let actualTime: MediaTime
  public let score: Float
}
func analysisError(_ message: String) -> MediaError {
  MediaError(.invalidRequest, stage: "semantic", message)
}
