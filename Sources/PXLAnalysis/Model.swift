import CoreImage
import CoreML
import CoreVideo
import CryptoKit
import Foundation

extension SemanticComputePolicy {
  var units: MLComputeUnits {
    switch self {
    case .cpuOnly: .cpuOnly
    case .cpuAndNeuralEngine: .cpuAndNeuralEngine
    case .all: .all
    }
  }
}
/// Owned exclusively by one SemanticAnalyzer actor; synchronous prediction never crosses that boundary.
final class ModelPair {
  let image: MLModel
  let text: MLModel
  private let compiled: CompiledModelArtifacts
  let imageURL: URL
  let textURL: URL
  let identity: String
  let tokenizer: CLIPTokenizer
  let configuration: MLModelConfiguration
  let loadMilliseconds: Double
  private(set) var lastPredictionMilliseconds: Double = 0
  private let context = CIContext(options: [.cacheIntermediates: false])
  private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

  init(directory: URL, variant: String, policy: SemanticComputePolicy) throws {
    let start = ContinuousClock.now
    struct Manifest: Decodable {
      let schemaVersion: Int
      let files: [String: String]
    }
    let manifest = try JSONDecoder().decode(
      Manifest.self,
      from: boundedData(
        at: directory.appendingPathComponent("download-manifest.json"), maximum: 1_048_576))
    guard manifest.schemaVersion == 1 else { throw analysisError("Unsupported model manifest") }
    var paths = ["clip-vocab.json", "clip-merges.txt"]
    for kind in ["image", "text"] {
      for part in [
        "Manifest.json", "Data/com.apple.CoreML/model.mlmodel",
        "Data/com.apple.CoreML/weights/weight.bin",
      ] {
        paths.append("mobileclip_\(variant)_\(kind).mlpackage/\(part)")
      }
    }
    var fingerprint = ""
    for path in paths.sorted() {
      let hash = try contentDigest(directory.appendingPathComponent(path))
      guard manifest.files[path] == hash else {
        throw analysisError("Model/tokenizer asset hash mismatch: \(path)")
      }
      fingerprint += path + "\0" + hash + "\n"
    }
    fingerprint += SemanticIndex.preprocessing
    identity = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
    tokenizer = try CLIPTokenizer(directory: directory)
    configuration = MLModelConfiguration()
    configuration.computeUnits = policy.units
    let modelIdentity = identity
    let config = configuration
    var admitted: (MLModel, MLModel)?
    compiled = try CompiledModelPool.shared.lease(
      identity: modelIdentity,
      build: {
        try CompiledModelArtifacts(
          imageSource: directory.appendingPathComponent("mobileclip_\(variant)_image.mlpackage"),
          textSource: directory.appendingPathComponent("mobileclip_\(variant)_text.mlpackage"),
          compiler: { try MLModel.compileModel(at: $0) })
      },
      validate: { artifact in
        let image = try MLModel(contentsOf: artifact.imageURL, configuration: config)
        let text = try MLModel(contentsOf: artifact.textURL, configuration: config)
        guard let ic = image.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
          ic.pixelsWide == 256, ic.pixelsHigh == 256,
          text.modelDescription.inputDescriptionsByName["text"]?.multiArrayConstraint?.shape == [
            1, 77,
          ],
          text.modelDescription.inputDescriptionsByName["text"]?.multiArrayConstraint?.dataType
            == .int32,
          image.modelDescription.outputDescriptionsByName["final_emb_1"]?.multiArrayConstraint?
            .shape
            == [1, 512],
          text.modelDescription.outputDescriptionsByName["final_emb_1"]?.multiArrayConstraint?.shape
            == [1, 512]
        else {
          throw analysisError("Unexpected MobileCLIP input/output contract")
        }
        for path in paths {
          guard try contentDigest(directory.appendingPathComponent(path)) == manifest.files[path]
          else {
            throw analysisError("Model/tokenizer source changed during loading")
          }
        }
        admitted = (image, text)
      })
    guard let admitted else { throw analysisError("Model admission did not complete") }
    imageURL = compiled.imageURL
    textURL = compiled.textURL
    image = admitted.0
    text = admitted.1
    loadMilliseconds = milliseconds(since: start)
  }

  func prepareImage(_ image: CGImage) throws -> CVPixelBuffer {
    let input = CIImage(cgImage: image)
    let scale = 256 / min(input.extent.width, input.extent.height)
    let resized = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let crop = CGRect(
      x: (resized.extent.width - 256) / 2, y: (resized.extent.height - 256) / 2, width: 256,
      height: 256)
    let output = resized.cropped(to: crop).transformed(
      by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    var pixel: CVPixelBuffer?
    let result = CVPixelBufferCreate(
      nil, 256, 256, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pixel)
    guard result == kCVReturnSuccess, let pixel else {
      throw analysisError("Cannot allocate model image")
    }
    context.render(
      output, to: pixel, bounds: CGRect(x: 0, y: 0, width: 256, height: 256), colorSpace: srgb)
    return pixel
  }
  func imageEmbedding(_ pixel: CVPixelBuffer) throws -> [Float] {
    try predict(image, input: "image", value: MLFeatureValue(pixelBuffer: pixel))
  }
  func textEmbedding(_ query: String) throws -> [Float] {
    let tokens = try tokenizer.encode(query)
    let array = try MLMultiArray(shape: [1, 77], dataType: .int32)
    for i in tokens.indices { array[i] = NSNumber(value: tokens[i]) }
    return try predict(text, input: "text", value: MLFeatureValue(multiArray: array))
  }
  private func predict(_ model: MLModel, input: String, value: MLFeatureValue) throws -> [Float] {
    try Task.checkCancellation()
    let predictionStart = ContinuousClock.now
    let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [input: value]))
    lastPredictionMilliseconds = milliseconds(since: predictionStart)
    try Task.checkCancellation()
    guard let vector = result.featureValue(for: "final_emb_1")?.multiArrayValue, vector.count == 512
    else {
      throw analysisError("Unexpected embedding output")
    }
    return try Embedding.normalized((0..<vector.count).map { vector[$0].floatValue })
  }
}
