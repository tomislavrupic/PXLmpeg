import Foundation
import OSLog
import PXLMedia

public struct SemanticBenchmark: Codable, Sendable {
  public let modelID: String
  public let modelName: String
  public let computePolicy: SemanticComputePolicy
  public let loadMilliseconds: Double
  public let sampleActualTime: MediaTime
  public let firstImagePredictionMilliseconds: Double
  public let firstTextPredictionMilliseconds: Double
  public let warmupCount: Int
  public let imagePredictionMilliseconds: [Double]
  public let textPredictionMilliseconds: [Double]
  public let note: String
}

extension SemanticAnalyzer {
  public func benchmark(
    source: URL, repetitions: Int = 100,
    colourPolicy: InputColourPolicy = .requireTagged
  ) async throws -> SemanticBenchmark {
    try begin()
    defer { active = false }
    guard (1...1000).contains(repetitions) else {
      throw analysisError("Repetitions must be 1...1000")
    }
    let m = try models()
    let sampler = try await VideoSampler(source: source, colourPolicy: colourPolicy)
    let sample = try await sampler.sample(seconds: sampler.videoStartSeconds)
    let pixel = try m.prepareImage(sample.image)
    _ = try m.imageEmbedding(pixel)
    let coldImage = m.lastPredictionMilliseconds
    _ = try m.textEmbedding("a person in a room")
    let coldText = m.lastPredictionMilliseconds
    for _ in 0..<5 {
      _ = try m.imageEmbedding(pixel)
      _ = try m.textEmbedding("a person in a room")
    }
    let signposter = OSSignposter(
      subsystem: "studio.pixelrecords.pxlmpeg", category: "PointsOfInterest")
    var images: [Double] = []
    var texts: [Double] = []
    let imageState = signposter.beginInterval("MeasuredImageBatch")
    do {
      defer { signposter.endInterval("MeasuredImageBatch", imageState) }
      for _ in 0..<repetitions {
        _ = try m.imageEmbedding(pixel)
        images.append(m.lastPredictionMilliseconds)
      }
    }
    let textState = signposter.beginInterval("MeasuredTextBatch")
    do {
      defer { signposter.endInterval("MeasuredTextBatch", textState) }
      for _ in 0..<repetitions {
        _ = try m.textEmbedding("a person in a room")
        texts.append(m.lastPredictionMilliseconds)
      }
    }
    return SemanticBenchmark(
      modelID: m.identity, modelName: variant, computePolicy: policy,
      loadMilliseconds: m.loadMilliseconds, sampleActualTime: sample.actualTime,
      firstImagePredictionMilliseconds: coldImage, firstTextPredictionMilliseconds: coldText,
      warmupCount: 5,
      imagePredictionMilliseconds: images, textPredictionMilliseconds: texts,
      note:
        "Synchronous Core ML prediction wall time only; preprocessing/tokenization/output normalization excluded. Five warmups excluded. Load may use existing compiler/system caches; first prediction is not a guaranteed cold-system measurement. Runtime device use requires a separate trace."
    )
  }
}
