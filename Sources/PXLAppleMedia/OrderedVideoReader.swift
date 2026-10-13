import Foundation
import PXLMedia

// One worker owns read/decode/window/render. Synchronous VT completion leaves no
// outstanding callback when a packet is released or queued frames are cancelled.
package final class OrderedVideoReader {
  private let reader: SampleReader, decoder: VideoDecoder, budget: MediaBudget
  private let queue: PresentationBuffer<MediaLease>
  private var eof = false
  package private(set) var retainedFramesPeak = 0
  package init(reader: SampleReader, decoder: VideoDecoder, budget: MediaBudget, reorderDepth: Int)
    throws
  {
    self.reader = reader
    self.decoder = decoder
    self.budget = budget
    queue = try PresentationBuffer(reorderDepth: reorderDepth)
  }
  package func next(check: () throws -> Void) throws -> MediaLease? {
    while true {
      try check()
      if let frame = try queue.pop(atEOF: eof) { return frame }
      if eof { return nil }
      try autoreleasepool {
        guard let packet = try reader.nextVideo() else {
          eof = true
          return
        }
        let reservation = try budget.reserve(bytes: packet.bytes, kind: .packet)
        defer { reservation.release() }
        let frame = try decoder.decode(packet, budget: budget)
        try check()
        try queue.insert(frame, pts: frame.pts)
        retainedFramesPeak = max(retainedFramesPeak, queue.count)
      }
    }
  }
  package func cancel() { queue.removeAll() }
}
