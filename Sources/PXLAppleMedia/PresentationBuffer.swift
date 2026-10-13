import CoreMedia
import PXLMedia

// Worker-confined. H.264's maximum number of pictures preceding a picture in
// decoding order and succeeding it in display order bounds this sorted window.
package final class PresentationBuffer<Value> {
  private let depth: Int
  private var entries: [(CMTime, Value)] = []
  private var lastEmitted: CMTime?
  package var count: Int { entries.count }
  package init(reorderDepth: Int) throws {
    guard (0...16).contains(reorderDepth) else {
      throw MediaError(.unsupportedMedia, stage: "reorder", "Unsupported presentation window")
    }
    depth = reorderDepth
  }
  package func insert(_ value: Value, pts: CMTime) throws {
    guard entries.count < depth + 1 else {
      throw MediaError(.resourceLimit, stage: "reorder", "Presentation window is full")
    }
    guard pts.isNumeric, pts >= .zero,
      lastEmitted.map({ pts > $0 }) ?? true,
      !entries.contains(where: { $0.0 == pts })
    else {
      throw MediaError(
        .timingViolation, stage: "reorder",
        "Duplicate/late presentation timestamp or underreported SPS reorder depth")
    }
    let index = entries.firstIndex(where: { $0.0 > pts }) ?? entries.count
    entries.insert((pts, value), at: index)
  }
  package func pop(atEOF: Bool = false) throws -> Value? {
    guard !entries.isEmpty, atEOF || entries.count > depth else { return nil }
    let first = entries.removeFirst()
    lastEmitted = first.0
    return first.1
  }
  package func removeAll() { entries.removeAll() }
}
