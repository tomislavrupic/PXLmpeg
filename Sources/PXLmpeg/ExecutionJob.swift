import Foundation
import PXLMedia

// Common immutable execution contract keeps actor lifecycle/commit checks identical.
struct ExecutionJob: Sendable {
  enum Work: Sendable {
    case transcode(PreparedJob)
    case remux(PreparedRemux)
  }
  let work: Work
  let id: UUID, engineID: UUID
  let source: URL
  let fingerprint: SourceFingerprint
  let requestDigest: String
  let colourPolicy: InputColourPolicy, audioPolicy: AudioPolicy
  let codec: String
  let width: Int, height: Int
  let rotation: DisplayRotation
  let container: OutputContainer
  var operation: MediaOperation {
    if case .remux = work { return .remux }
    return .transcode
  }
  init(_ job: PreparedJob) {
    work = .transcode(job)
    id = job.id
    engineID = job.engineID
    source = job.request.source
    fingerprint = job.fingerprint
    requestDigest = job.requestDigest
    colourPolicy = job.request.inputColourPolicy
    audioPolicy = job.request.audioPolicy
    codec = job.request.outputCodec.rawValue
    width = job.geometry.width
    height = job.geometry.height
    rotation = .none
    container = job.request.outputContainer
  }
  init(_ job: PreparedRemux) {
    work = .remux(job)
    id = job.id
    engineID = job.engineID
    source = job.request.source
    fingerprint = job.fingerprint
    requestDigest = job.requestDigest
    colourPolicy = .requireTagged
    audioPolicy = job.request.audioPolicy
    codec = job.asset.codec
    width = job.asset.width
    height = job.asset.height
    rotation = job.asset.rotation ?? .none
    container = job.request.outputContainer
  }
}
