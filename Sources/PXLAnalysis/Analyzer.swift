import Foundation
import PXLMedia

public actor SemanticAnalyzer {
  private let directory: URL
  let variant: String
  let policy: SemanticComputePolicy
  private var pair: ModelPair?
  var active = false
  public init(
    models: URL, variant: String = "s2", computePolicy: SemanticComputePolicy = .cpuAndNeuralEngine
  ) throws {
    guard models.isFileURL, ["s0", "s2"].contains(variant) else {
      throw analysisError("Expected local models and variant s0 or s2")
    }
    directory = models
    self.variant = variant
    policy = computePolicy
  }
  func models() throws -> ModelPair {
    if let pair { return pair }
    let loaded = try ModelPair(directory: directory, variant: variant, policy: policy)
    pair = loaded
    return loaded
  }
  func begin() throws {
    try Task.checkCancellation()
    guard !active else {
      throw MediaError(.engineBusy, stage: "semantic", "Analyzer already has an active operation")
    }
    active = true
  }
  public func index(
    sources: [URL], options: SamplingOptions = try! SamplingOptions(),
    colourPolicy: InputColourPolicy = .requireTagged
  ) async throws -> SemanticIndex {
    try begin()
    defer { active = false }
    guard (1...32).contains(sources.count),
      Set(sources.map(\.standardizedFileURL)).count == sources.count,
      sources.allSatisfy(\.isFileURL)
    else { throw analysisError("Expected 1...32 distinct local sources") }
    for source in sources {
      guard ["mov", "mp4"].contains(source.pathExtension.lowercased()) else {
        throw analysisError("Only MOV/MP4 sources are supported")
      }
      let handle = try regularFile(source)
      try handle.close()
    }
    let start = ContinuousClock.now
    let m = try models()
    var records: [IndexedSource] = []
    var frames: [FrameEmbedding] = []
    for source in sources {
      try Task.checkCancellation()
      let hash = try contentDigest(source)
      let sampler = try await VideoSampler(source: source, colourPolicy: colourPolicy)
      let first = sampler.videoStartSeconds
      let end = sampler.videoEndSeconds
      var next = first
      var last: MediaTime?
      var count = 0
      while next < end, count < options.maximumSamplesPerSource {
        try Task.checkCancellation()
        guard frames.count < 4096 else {
          throw analysisError("Aggregate frame limit is 4096; reduce sampling")
        }
        let sample = try await sampler.sample(seconds: next)
        if last.map({ $0 < sample.actualTime }) ?? true {
          let pixel = try m.prepareImage(sample.image)
          let inference = ContinuousClock.now
          let vector = try m.imageEmbedding(pixel)
          frames.append(
            FrameEmbedding(
              sourceIndex: records.count,
              requestedTime: try MediaTime(
                value: Int64((next * 600_000).rounded()), timescale: 600_000),
              actualTime: sample.actualTime, vector: vector,
              inferenceMilliseconds: milliseconds(since: inference)))
          last = sample.actualTime
        }
        count += 1
        next = first + Double(count) * options.intervalSeconds
      }
      guard try contentDigest(source) == hash else {
        throw MediaError(
          .sourceChanged, stage: "semantic", "Source content changed during indexing")
      }
      records.append(
        IndexedSource(
          url: source, sha256: hash, asset: sampler.descriptor,
          videoStartSeconds: first, videoEndSeconds: end, truncated: next < end,
          samplingBackend: sampler.backend))
    }
    try Task.checkCancellation()
    let result = SemanticIndex(
      schemaVersion: 1, modelID: m.identity, modelName: variant,
      preprocessing: SemanticIndex.preprocessing, computePolicy: policy, sampling: options,
      inputColourPolicy: colourPolicy, sources: records, frames: frames,
      elapsedMilliseconds: milliseconds(since: start))
    try result.validate()
    return result
  }
  public func query(_ text: String, index: SemanticIndex, limit: Int = 10) throws -> [SearchHit] {
    try begin()
    defer { active = false }
    try index.validate()
    guard (1...100).contains(limit), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= 8192
    else { throw analysisError("Invalid query or result limit") }
    let m = try models()
    guard index.modelID == m.identity else {
      throw analysisError("Index and query model/tokenizer identities differ")
    }
    return try SemanticSearch.rank(
      index: index, query: m.textEmbedding(text), modelID: m.identity, limit: limit)
  }
  public func computePlan() async throws -> ModelComputeReport {
    try begin()
    defer { active = false }
    let m = try models()
    let image = try await describePlan(url: m.imageURL, policy: policy)
    let text = try await describePlan(url: m.textURL, policy: policy)
    try Task.checkCancellation()
    return ModelComputeReport(modelID: m.identity, computePolicy: policy, image: image, text: text)
  }
}
