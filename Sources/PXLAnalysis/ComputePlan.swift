import CoreML
import Foundation

public struct EncoderComputePlan: Codable, Sendable {
  public let totalOperations: Int
  public let preferredOperations: [String: Int]
  public let supportedOperations: [String: Int]
  public let estimatedCostWeight: [String: Double]
  public let note: String
}
public struct ModelComputeReport: Codable, Sendable {
  public let modelID: String
  public let computePolicy: SemanticComputePolicy
  public let image: EncoderComputePlan
  public let text: EncoderComputePlan
}
func describePlan(url: URL, policy: SemanticComputePolicy) async throws -> EncoderComputePlan {
  let configuration = MLModelConfiguration()
  configuration.computeUnits = policy.units
  let plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration)
  guard case .program(let program) = plan.modelStructure else {
    throw analysisError("Expected ML Program")
  }
  var preferred: [String: Int] = [:]
  var supported: [String: Int] = [:]
  var costs: [String: Double] = [:]
  var total = 0
  func name(_ device: MLComputeDevice) -> String {
    switch device {
    case .cpu: "cpu"
    case .gpu: "gpu"
    case .neuralEngine: "ane"
    @unknown default: "unknown"
    }
  }
  func visit(_ block: MLModelStructure.Program.Block) {
    for op in block.operations {
      total += 1
      let usage = plan.deviceUsage(for: op)
      let key = usage.map { name($0.preferred) } ?? "unassigned"
      preferred[key, default: 0] += 1
      costs[key, default: 0] += plan.estimatedCost(of: op)?.weight ?? 0
      for device in usage?.supported ?? [] { supported[name(device), default: 0] += 1 }
      for nested in op.blocks { visit(nested) }
    }
  }
  for function in program.functions.values { visit(function.block) }
  return EncoderComputePlan(
    totalOperations: total, preferredOperations: preferred, supportedOperations: supported,
    estimatedCostWeight: costs,
    note:
      "Planned placement and estimated cost weights, not measured execution or runtime percentages. Unassigned includes constants/control bookkeeping."
  )
}
