import Foundation
import PXLMedia

public struct PreparedRemux: Sendable {
  public let request: RemuxRequest
  public let asset: AssetDescriptor
  public let requestDigest: String
  public let estimatedWorkingSetBytes: Int
  public var id: UUID { request.id }
  let fingerprint: SourceFingerprint
  let engineID: UUID
}
