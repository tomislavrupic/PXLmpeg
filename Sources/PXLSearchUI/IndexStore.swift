import Foundation
import PXLAnalysis

actor IndexStore {
  func read(_ url: URL) throws -> SemanticIndex {
    try Task.checkCancellation()
    return try SemanticIndex.read(from: url)
  }
  func write(_ index: SemanticIndex, to url: URL) throws {
    try Task.checkCancellation()
    try index.write(to: url)
  }
}
