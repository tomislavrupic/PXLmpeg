import Foundation
import PXLMedia

public struct PreparedJob: Sendable {
  public let request: JobRequest
  public let asset: AssetDescriptor
  public let geometry: OutputGeometry
  public let requestDigest: String
  public let estimatedWorkingSetBytes: Int
  public var id: UUID { request.id }
  let fingerprint: SourceFingerprint
  let engineID: UUID
}
