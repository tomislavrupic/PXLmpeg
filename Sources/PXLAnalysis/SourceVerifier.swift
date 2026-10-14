import Foundation
import PXLMedia

/// Hosts verify content before reusing a sidecar against current local footage.
/// Hashing runs on this actor, outside the main actor, with cooperative cancellation.
public actor SemanticSourceVerifier {
  public init() {}
  public func verify(source: URL, sha256: String) throws {
    try Task.checkCancellation()
    guard SemanticIndex.isDigest(sha256) else {
      throw analysisError("Invalid expected source digest")
    }
    guard try contentDigest(source) == sha256 else {
      throw MediaError(
        .sourceChanged, stage: "semantic-source",
        "Source changed; rebuild the index: \(source.lastPathComponent)")
    }
  }
  public func verify(index: SemanticIndex) throws {
    try index.validate()
    for source in index.sources {
      try verify(source: source.url, sha256: source.sha256)
    }
  }
}
