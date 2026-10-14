import CoreMedia
import PXLAppleMedia

/// Worker-confined selection state. Requested times advance independently of
/// actual frame timestamps: a presentation gap may select a future candidate.
final class DecodedFrameCursor {
  private var last: MediaLease?
  private var lastRequested: CMTime?
  func select(at requested: CMTime, next: () throws -> MediaLease?) throws -> MediaLease {
    if let lastRequested, requested < lastRequested {
      throw analysisError("Explicit-colour sampling is forward only")
    }
    lastRequested = requested
    if let previous = last, requested >= CMTimeAdd(previous.pts, previous.duration) { last = nil }
    while last == nil {
      guard let frame = try next() else {
        throw analysisError("No decoded frame covers requested time")
      }
      if CMTimeAdd(frame.pts, frame.duration) > requested { last = frame }
    }
    return last!
  }
  func reset() {
    last = nil
    lastRequested = nil
  }
}
