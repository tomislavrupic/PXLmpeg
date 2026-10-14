import Foundation

public enum Embedding {
  public static func normalized(_ vector: [Float]) throws -> [Float] {
    guard !vector.isEmpty, vector.count <= 4096, vector.allSatisfy({ $0.isFinite }) else {
      throw analysisError("Embedding must contain 1...4096 finite values")
    }
    let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
    guard norm.isFinite, norm > 1e-12 else { throw analysisError("Zero or invalid embedding") }
    return vector.map { Float(Double($0) / norm) }
  }
  public static func cosine(_ lhs: [Float], _ rhs: [Float]) throws -> Float {
    guard lhs.count == rhs.count else { throw analysisError("Embedding dimensions differ") }
    let a = try normalized(lhs)
    let b = try normalized(rhs)
    return min(1, max(-1, zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }))
  }
}
public enum SemanticSearch {
  public static func rank(index: SemanticIndex, query: [Float], modelID: String, limit: Int = 10)
    throws -> [SearchHit]
  {
    try index.validate()
    guard modelID == index.modelID, query.count == 512, (1...100).contains(limit) else {
      throw analysisError("Model identity/dimensions mismatch or result limit outside 1...100")
    }
    let vector = try Embedding.normalized(query)
    var scores: [(Int, Float)] = []
    for (i, frame) in index.frames.enumerated() {
      var score: Float = 0
      for j in vector.indices { score += vector[j] * frame.vector[j] }
      scores.append((i, score))
    }
    scores.sort { left, right in left.1 == right.1 ? left.0 < right.0 : left.1 > right.1 }
    return scores.prefix(limit).map { i, score in
      let f = index.frames[i]
      let s = index.sources[f.sourceIndex]
      return SearchHit(
        source: s.url, sourceSHA256: s.sha256, actualTime: f.actualTime,
        score: min(1, max(-1, score)))
    }
  }
}
