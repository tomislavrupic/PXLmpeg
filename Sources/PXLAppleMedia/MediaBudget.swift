import Foundation
import PXLMedia

package enum ReservationKind { case bytes, frame, packet }
// All counters are guarded by lock; reservations can be released on a native callback thread.
package final class MediaBudget: @unchecked Sendable {
  private let lock = NSLock()
  private let limit: Int
  private let frameLimit: Int
  private var used = 0, peakUsed = 0, frames = 0, packets = 0, packetBytes = 0
  package init(limit: Int, frameLimit: Int = 4) {
    self.limit = limit
    self.frameLimit = max(1, min(17, frameLimit))
  }
  package var current: Int { lock.withLock { used } }
  package var peak: Int { lock.withLock { peakUsed } }
  package var frameCount: Int { lock.withLock { frames } }
  package func reserve(bytes: Int, kind: ReservationKind) throws -> Reservation {
    try lock.withLock {
      guard bytes >= 0, bytes <= limit - used,
        kind != .frame || frames < frameLimit,
        kind != .packet
          || (packets < 32 && bytes <= 8 * 1024 * 1024 && bytes <= 32 * 1024 * 1024 - packetBytes)
      else {
        throw MediaError(
          .resourceLimit, stage: "memory", "Owned media budget or admission limit exceeded")
      }
      used += bytes
      peakUsed = max(peakUsed, used)
      if kind == .frame { frames += 1 }
      if kind == .packet {
        packets += 1
        packetBytes += bytes
      }
      return Reservation { [self] in
        lock.withLock {
          used -= bytes
          if kind == .frame { frames -= 1 }
          if kind == .packet {
            packets -= 1
            packetBytes -= bytes
          }
        }
      }
    }
  }
}
package final class Reservation {
  private let lock = NSLock()
  private var action: (() -> Void)?
  package init(_ action: @escaping () -> Void) { self.action = action }
  package func release() {
    let callback = lock.withLock {
      let a = action
      action = nil
      return a
    }
    callback?()
  }
  deinit { release() }
}
