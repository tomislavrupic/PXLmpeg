import Foundation
import PXLMedia
import XCTest

@testable import PXLAnalysis
@testable import PXLSearchUI

final class SourceAndResultTests: XCTestCase {
  // Removing the comparison would accept changed media and break timestamp identity.
  func testSourceVerificationRejectsChangedAndMissingContent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("source.mov")
    try Data("abc".utf8).write(to: file)
    let sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    let verifier = SemanticSourceVerifier()
    try await verifier.verify(source: file, sha256: sha)
    try Data("abd".utf8).write(to: file)
    do {
      try await verifier.verify(source: file, sha256: sha)
      XCTFail("Changed content accepted")
    } catch let e as MediaError { XCTAssertEqual(e.code, .sourceChanged) }
    try FileManager.default.removeItem(at: file)
    do {
      try await verifier.verify(source: file, sha256: sha)
      XCTFail("Missing content accepted")
    } catch {}
  }

  // Dropping diversity would fill all visible rows with adjacent frames of one clip.
  func testVisibleCandidatesKeepRankingAndSeparateSameSourceMoments() throws {
    func hit(_ source: String, _ seconds: Int, _ score: Float) throws -> SearchHit {
      SearchHit(
        source: URL(fileURLWithPath: "/" + source + ".mov"),
        sourceSHA256: String(repeating: "a", count: 64),
        actualTime: try MediaTime(value: Int64(seconds), timescale: 10), score: score)
    }
    let input = try [
      hit("a", 0, 0.9), hit("a", 5, 0.89), hit("a", 10, 0.8),
      hit("b", 0, 0.7), hit("a", 20, 0.6), hit("a", 30, 0.5), hit("b", 10, 0.4),
    ]
    let visible = ResultSelection.candidates(input)
    XCTAssertEqual(
      visible.map { $0.source.lastPathComponent }, ["a.mov", "a.mov", "b.mov", "a.mov", "b.mov"])
    XCTAssertEqual(visible.map { $0.actualTime.seconds }, [0, 1, 0, 2, 1])
    let many = try (0..<20).map { try hit("clip" + String($0), 0, 0.5) }
    XCTAssertEqual(ResultSelection.candidates(many).count, 12)
  }
}
