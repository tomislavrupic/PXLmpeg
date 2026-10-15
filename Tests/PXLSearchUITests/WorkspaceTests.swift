import Foundation
import PXLAnalysis
import PXLMedia
import XCTest

@testable import PXLSearchUI

@MainActor final class WorkspaceTests: XCTestCase {
  func fixture() throws -> (URL, URL) {
    let env = ProcessInfo.processInfo.environment
    guard let models = env["PXL_SEMANTIC_MODELS"], let index = env["PXL_SEARCH_INDEX"] else {
      throw XCTSkip("Supply real models and PXL_SEARCH_INDEX")
    }
    return (URL(fileURLWithPath: models), URL(fileURLWithPath: index))
  }
  func waitIdle(_ workspace: SearchWorkspace) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while workspace.isBusy {
      if ContinuousClock.now >= deadline {
        XCTFail("Workspace did not finish")
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
  // Missing assets must be actionable, rather than starting an unusable index job.
  func testMissingModelsAndInvalidSourcesAreVisibleWithoutStartingWork() {
    let w = SearchWorkspace()
    w.chooseSources([URL(fileURLWithPath: "/missing.mov")], colourPolicy: .requireTagged)
    w.buildIndex()
    XCTAssertNotNil(w.error)
    XCTAssertFalse(w.isBusy)
    XCTAssertNil(w.index)
    w.chooseSources([], colourPolicy: .requireTagged)
    XCTAssertNotNil(w.error)
    w.close()
  }
  // A late query must never repopulate results after the user chooses new footage.
  func testFootageReplacementFencesPendingSearch() async throws {
    let (models, source) = try fixture()
    let w = SearchWorkspace(models: models)
    defer { w.close() }
    w.openIndex(source)
    try await waitIdle(w)
    XCTAssertNotNil(w.index)
    w.search("a guitar beside a plant")
    try await Task.sleep(for: .milliseconds(20))
    let prior = w.workTask
    let replacement = URL(fileURLWithPath: "/replacement.mov")
    w.chooseSources([replacement], colourPolicy: .requireTagged)
    await prior?.value
    XCTAssertNil(w.index)
    XCTAssertTrue(w.results.isEmpty)
    XCTAssertEqual(w.sources, [replacement])
    XCTAssertNil(w.playback.snapshot.source)
    XCTAssertFalse(w.isBusy)
  }
  // A valid sidecar with a missing current source cannot be searched or played.
  func testMissingIndexedSourceFailsBeforeResults() async throws {
    let (models, source) = try fixture()
    let scratch = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).appendingPathComponent(
      UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: scratch) }
    var json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
    var sources = try XCTUnwrap(json["sources"] as? [[String: Any]])
    sources[0]["url"] = "file:///tmp/missing-" + UUID().uuidString + ".mov"
    json["sources"] = sources
    try JSONSerialization.data(withJSONObject: json).write(to: scratch)
    let w = SearchWorkspace(models: models)
    defer { w.close() }
    w.openIndex(scratch)
    try await waitIdle(w)
    XCTAssertNotNil(w.index)
    w.search("a room with a guitar")
    try await waitIdle(w)
    XCTAssertNotNil(w.error)
    XCTAssertTrue(w.results.isEmpty)
    XCTAssertNil(w.playback.snapshot.source)
  }
  // Saving a new sidecar must preserve a pre-existing destination even on failure.
  func testSaveRefusesExistingFileAndKeepsLoadedIndex() async throws {
    let (models, source) = try fixture()
    let scratch = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).appendingPathComponent(
      UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let original = Data("preserve this file".utf8)
    try original.write(to: scratch)
    let w = SearchWorkspace(models: models)
    defer { w.close() }
    w.openIndex(source)
    try await waitIdle(w)
    w.saveIndex(scratch)
    try await waitIdle(w)
    XCTAssertNotNil(w.error)
    XCTAssertNotNil(w.index)
    XCTAssertEqual(try Data(contentsOf: scratch), original)
  }
  func testIndexChosenRealFootageAndSaveNewSidecar() async throws {
    let (models, source) = try fixture()
    let existing = try SemanticIndex.read(from: source)
    let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).appendingPathComponent(
      UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: output) }
    let w = SearchWorkspace(models: models)
    defer { w.close() }
    w.chooseSources(Array(existing.sources.prefix(2).map(\.url)), colourPolicy: .assumeBT709Limited)
    w.buildIndex()
    try await waitIdle(w)
    XCTAssertNil(w.error)
    let index = try XCTUnwrap(w.index)
    XCTAssertEqual(index.sources.count, 2)
    XCTAssertEqual(
      index.sources[0].sha256, "869d328924d5a3df27163822c0f69c104e900c9c2ae102face9906a8ca11ccc6")
    XCTAssertFalse(index.frames.isEmpty)
    w.saveIndex(output)
    try await waitIdle(w)
    XCTAssertNil(w.error)
    XCTAssertEqual(try SemanticIndex.read(from: output).frames.count, index.frames.count)
  }
  func testCloseDuringSearchCannotPublishLateResults() async throws {
    let (models, source) = try fixture()
    let w = SearchWorkspace(models: models)
    w.openIndex(source)
    try await waitIdle(w)
    w.search("a guitar beside a plant")
    try await Task.sleep(for: .milliseconds(20))
    let pending = w.workTask
    w.close()
    await pending?.value
    XCTAssertTrue(w.results.isEmpty)
    XCTAssertNil(w.playback.snapshot.source)
    XCTAssertFalse(w.isBusy)
  }
  func testNewQuerySupersedesThumbnailUpdates() async throws {
    let (models, source) = try fixture()
    let w = SearchWorkspace(models: models)
    defer { w.close() }
    w.openIndex(source)
    try await waitIdle(w)
    var replaced = false
    w.onChange = {
      if w.phase == .thumbnails && !replaced {
        replaced = true
        w.search("a frightened woman in a white spacesuit")
      }
    }
    w.search("a guitar beside a plant")
    try await waitIdle(w)
    XCTAssertTrue(replaced)
    XCTAssertNil(w.error)
    XCTAssertEqual(
      w.results.first?.hit.sourceSHA256,
      "15cab67cd81f72e5f53ca5e506936564ace981147388867ca3ff43440fc9ad93")
    XCTAssertTrue(w.results.allSatisfy { $0.thumbnail != nil })
  }
  func testChangedSourceAfterSearchCannotBeginPlayback() async throws {
    let (models, source) = try fixture()
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = try SemanticIndex.read(from: source)
    let copy = root.appendingPathComponent("camera.mov")
    try FileManager.default.copyItem(at: original.sources[0].url, to: copy)
    var json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
    var sources = try XCTUnwrap(json["sources"] as? [[String: Any]])
    sources[0]["url"] = copy.absoluteString
    json["sources"] = [sources[0]]
    json["frames"] = (json["frames"] as? [[String: Any]])?.filter {
      ($0["sourceIndex"] as? Int) == 0
    }
    let sidecar = root.appendingPathComponent("index.json")
    try JSONSerialization.data(withJSONObject: json).write(to: sidecar)
    let w = SearchWorkspace(models: models)
    defer { w.close() }
    w.openIndex(sidecar)
    try await waitIdle(w)
    w.search("a guitar beside a plant")
    try await waitIdle(w)
    let first = try XCTUnwrap(w.results.first)
    let file = try FileHandle(forWritingTo: copy)
    try file.seekToEnd()
    try file.write(contentsOf: Data([0]))
    try file.close()
    w.select(first.id)
    await w.playbackTask?.value
    XCTAssertNotNil(w.error)
    XCTAssertNil(w.lastJump)
    XCTAssertNil(w.playback.snapshot.source)
    XCTAssertFalse(w.playback.snapshot.isPlaybackRequested)
  }

}
