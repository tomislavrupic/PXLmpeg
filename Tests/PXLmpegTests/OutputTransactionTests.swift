import Foundation
import PXLMedia
import PXLTestSupport
import XCTest

@testable import PXLmpeg

final class OutputTransactionTests: XCTestCase {
  func testAtomicNoReplaceAndCleanup() throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("source.mov")
    let dest = dir.appendingPathComponent("output č.mov")
    try Data([1, 2, 3]).write(to: source)
    let transaction = try OutputTransaction(destination: dest, source: source, jobID: UUID())
    try Data([4, 5]).write(to: transaction.temporaryURL)
    try Data([99]).write(to: dest)
    XCTAssertThrowsError(try transaction.commit())
    transaction.abort()
    transaction.abort()
    XCTAssertEqual(try Data(contentsOf: dest), Data([99]))
    XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.temporaryURL.path))
    XCTAssertThrowsError(try OutputTransaction(destination: source, source: source, jobID: UUID()))
  }
  func testSuccessfulPublicationAndFingerprintChange() throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("source.mov")
    let dest = dir.appendingPathComponent("new.mov")
    try Data([1]).write(to: source)
    let before = try SourceFingerprint.read(source)
    let transaction = try OutputTransaction(destination: dest, source: source, jobID: UUID())
    try Data([7, 8]).write(to: transaction.temporaryURL)
    try transaction.commit()
    XCTAssertEqual(try Data(contentsOf: dest), Data([7, 8]))
    try Data([1, 2]).write(to: source)
    XCTAssertNotEqual(try SourceFingerprint.read(source), before)
  }
  func testAbortRemovesWriterSafeSaveScratchAndPreservesUnknownFiles() throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("source.mov")
    try Data([1]).write(to: source)
    for keepUnknown in [false, true] {
      let transaction = try OutputTransaction(
        destination: dir.appendingPathComponent("copy-\(keepUnknown).mp4"), source: source,
        jobID: UUID(), container: .mp4)
      let scratch = transaction.temporaryURL.deletingLastPathComponent().appendingPathComponent(
        "media.mp4.sb-owned-test")
      let unrelated = scratch.deletingLastPathComponent().appendingPathComponent("keep.txt")
      try Data([2]).write(to: scratch)
      if keepUnknown { try Data([9]).write(to: unrelated) }
      transaction.abort()
      XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
      XCTAssertEqual(
        FileManager.default.fileExists(atPath: scratch.deletingLastPathComponent().path),
        keepUnknown)
      if keepUnknown { XCTAssertEqual(try Data(contentsOf: unrelated), Data([9])) }
    }
  }
}
