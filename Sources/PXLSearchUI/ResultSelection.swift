import PXLAnalysis

/// Limit repeated adjacent frames without inventing a continuous event span.
enum ResultSelection {
  static func candidates(_ hits: [SearchHit]) -> [SearchHit] {
    var selected: [SearchHit] = []
    for hit in hits {
      let sameSource = selected.filter {
        $0.sourceSHA256 == hit.sourceSHA256 && $0.source == hit.source
      }
      guard sameSource.count < 3,
        sameSource.allSatisfy({ abs($0.actualTime.seconds - hit.actualTime.seconds) >= 1 })
      else { continue }
      selected.append(hit)
      if selected.count == 12 { break }
    }
    return selected
  }
}
