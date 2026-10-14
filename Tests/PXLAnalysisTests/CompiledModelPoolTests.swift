import Foundation
import XCTest

@testable import PXLAnalysis

final class CompiledModelPoolTests: XCTestCase {
  func factory(_ root: URL) -> @Sendable () throws -> CompiledModelArtifacts {
    {
      try CompiledModelArtifacts(
        imageSource: root.appendingPathComponent("image"),
        textSource: root.appendingPathComponent("text")
      ) { source in
        let output = root.appendingPathComponent(
          source.lastPathComponent + UUID().uuidString + ".mlmodelc")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("compiled fixture".utf8).write(to: output.appendingPathComponent("model"))
        return output
      }
    }
  }
  func testRepeatedIdentityReusesCompilerOwnedArtifacts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let pool = CompiledModelPool(capacity: 2)
    let first = try pool.lease(identity: "a", build: factory(root))
    let second = try pool.lease(identity: "a", build: factory(root))
    XCTAssertEqual(first.imageURL, second.imageURL)
    XCTAssertEqual(first.textURL, second.textURL)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count,
      2)
  }
  func testEvictionPreservesActiveLeaseAndRemovesReleasedOwnedFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let pool = CompiledModelPool(capacity: 1)
    var first: CompiledModelArtifacts? = try pool.lease(identity: "a", build: factory(root))
    let path = try XCTUnwrap(first).imageURL.path
    var second: CompiledModelArtifacts? = try pool.lease(identity: "b", build: factory(root))
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    first = nil
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    let other = try XCTUnwrap(second).imageURL.path
    pool.removeAll()
    XCTAssertTrue(FileManager.default.fileExists(atPath: other))
    second = nil
    XCTAssertFalse(FileManager.default.fileExists(atPath: other))
  }
  func testFailedSecondCompilationCleansFirstOwnedArtifact() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("first.mlmodelc")
    XCTAssertThrowsError(
      try CompiledModelArtifacts(
        imageSource: root.appendingPathComponent("image"),
        textSource: root.appendingPathComponent("text")
      ) { source in
        if source.lastPathComponent == "text" { throw CocoaError(.fileReadUnknown) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        return output
      })
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
  }
  func testFailedValidationCannotPublishOrReuseCompiledArtifacts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let pool = CompiledModelPool(capacity: 1)
    var first: CompiledModelArtifacts? = try pool.lease(identity: "a", build: factory(root))
    let originalPath = try XCTUnwrap(first).imageURL
    XCTAssertThrowsError(
      try pool.lease(
        identity: "a", build: factory(root),
        validate: { _ in
          throw CocoaError(.fileReadCorruptFile)
        }))
    first = nil
    let replacement = try pool.lease(identity: "a", build: factory(root))
    XCTAssertNotEqual(replacement.imageURL, originalPath)
    XCTAssertFalse(FileManager.default.fileExists(atPath: originalPath.path))
    let secondPool = CompiledModelPool(capacity: 1)
    XCTAssertThrowsError(
      try secondPool.lease(
        identity: "new", build: factory(root),
        validate: { _ in
          throw CocoaError(.fileReadCorruptFile)
        }))
  }
  func testShutdownDoesNotWaitForStalledCompilation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let pool = CompiledModelPool(capacity: 1)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let build = factory(root)
    let compiling = Task.detached {
      try pool.lease(
        identity: "a",
        build: {
          entered.signal()
          release.wait()
          return try build()
        })
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { release.signal() }
    let start = ContinuousClock.now
    pool.shutdown()
    XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
    _ = try await compiling.value
  }

}
