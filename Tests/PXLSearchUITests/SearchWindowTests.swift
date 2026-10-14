import AppKit
import Foundation
import PXLAnalysis
import PXLPlayback
import XCTest

@testable import PXLSearchUI

@MainActor final class SearchWindowTests: XCTestCase {
  func fixture() throws -> (URL, URL) {
    let env = ProcessInfo.processInfo.environment
    guard let models = env["PXL_SEMANTIC_MODELS"], let index = env["PXL_SEARCH_INDEX"] else {
      throw XCTSkip("Supply real models and PXL_SEARCH_INDEX")
    }
    return (URL(fileURLWithPath: models), URL(fileURLWithPath: index))
  }
  func wait(_ condition: @escaping @MainActor () -> Bool, seconds: Int = 30) async throws {
    let end = ContinuousClock.now + .seconds(seconds)
    while !condition() {
      guard ContinuousClock.now < end else {
        XCTFail("Native UI operation timed out")
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
  func testPreviewUsesAvailableWindowWidth() throws {
    _ = NSApplication.shared
    let w = SearchWorkspace()
    let ui = SearchWindowController(workspace: w)
    defer {
      w.close()
      ui.close()
    }
    let content = try XCTUnwrap(ui.window?.contentView)
    content.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView) -> [NSView] {
      view.subviews.flatMap { [$0] + descendants($0) }
    }
    let video = try XCTUnwrap(descendants(content).first { $0 is PlaybackView })
    XCTAssertEqual(
      video.convert(video.bounds, to: content).maxX, content.bounds.maxX - 24, accuracy: 2)
    if let directory = ProcessInfo.processInfo.environment["PXL_SEARCH_UI_STYLE_EVIDENCE"] {
      let url = URL(fileURLWithPath: directory)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
        content.effectiveAppearance.performAsCurrentDrawingAppearance {
          content.cacheDisplay(in: content.bounds, to: bitmap)
        }
        try bitmap.representation(using: .png, properties: [:])?.write(
          to: url.appendingPathComponent("empty-workspace.png"))
      }
    }
    ui.window?.setContentSize(NSSize(width: 920, height: 620))
    content.layoutSubtreeIfNeeded()
    XCTAssertGreaterThanOrEqual(video.bounds.width, 420)
    XCTAssertGreaterThan(video.bounds.height, 120)
    XCTAssertEqual(
      video.convert(video.bounds, to: content).maxX,
      content.bounds.maxX - 24, accuracy: 2)
  }
  func testSelectedFootageNamesReplaceInitialEmptyGuidance() throws {
    _ = NSApplication.shared
    let workspace = SearchWorkspace()
    let controller = SearchWindowController(workspace: workspace)
    defer {
      workspace.close()
      controller.close()
    }
    workspace.chooseSources(
      [URL(fileURLWithPath: "/test/editor-export.mov")], colourPolicy: .requireTagged)
    let content = try XCTUnwrap(controller.window?.contentView)
    func labels(_ view: NSView) -> [String] {
      (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
    }
    XCTAssertTrue(labels(content).contains { $0.contains("editor-export.mov") })
    XCTAssertFalse(labels(content).contains("Start with your footage"))
  }

  // Catch disconnected native buttons, wrong thumbnail identity and rank-based seeks.
  func testRealResultButtonSeeksToIndexedMomentAndPlaybackAdvances() async throws {
    _ = NSApplication.shared
    let (models, index) = try fixture()
    let w = SearchWorkspace(models: models)
    let ui = SearchWindowController(workspace: w)
    ui.showWindow(nil)
    ui.window?.contentView?.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView) -> [NSView] {
      view.subviews.flatMap { [$0] + descendants($0) }
    }
    let content = try XCTUnwrap(ui.window?.contentView)
    let video = try XCTUnwrap(descendants(content).first { $0 is PlaybackView })
    XCTAssertEqual(
      video.convert(video.bounds, to: content).maxX, content.bounds.maxX - 24, accuracy: 2,
      "The preview should use the available window width")
    defer {
      w.close()
      ui.close()
    }
    w.openIndex(index)
    try await wait { !w.isBusy }
    ui.queryField.stringValue = "a frightened woman in a white spacesuit"
    ui.searchButton.performClick(nil)
    try await wait { !w.isBusy }
    XCTAssertNil(w.error)
    let first = try XCTUnwrap(w.results.first)
    XCTAssertEqual(
      first.hit.sourceSHA256, "15cab67cd81f72e5f53ca5e506936564ace981147388867ca3ff43440fc9ad93")
    XCTAssertEqual(first.hit.actualTime.seconds, 3, accuracy: 0.001)
    let image = try XCTUnwrap(first.thumbnail)
    XCTAssertLessThanOrEqual(image.width, 320)
    XCTAssertLessThanOrEqual(image.height, 180)
    XCTAssertEqual(try XCTUnwrap(first.thumbnailTime).seconds, 3, accuracy: 0.05)
    let button = try XCTUnwrap(ui.resultButtons.first)
    let background = try XCTUnwrap(button.layer?.backgroundColor).components ?? []
    XCTAssertLessThan(
      background.prefix(3).reduce(0, +) / 3, 0.5,
      "A dark window must not have light row backgrounds behind light text")
    button.performClick(nil)
    try await wait { w.lastJump != nil || w.error != nil }
    XCTAssertNil(w.error)
    let jump = try XCTUnwrap(w.lastJump)
    XCTAssertEqual(jump.source, first.hit.source)
    XCTAssertEqual(jump.requestedSeconds, 3, accuracy: 0.001)
    XCTAssertEqual(jump.landedSeconds, 3, accuracy: 0.05)
    XCTAssertEqual(w.playback.snapshot.source, first.hit.source)
    XCTAssertTrue(w.playback.snapshot.isPlaybackRequested)
    try await wait({ w.playback.snapshot.positionSeconds > 3.15 }, seconds: 5)
    // Save only local UI evidence if requested; never publish private footage pixels.
    if let directory = ProcessInfo.processInfo.environment["PXL_SEARCH_UI_EVIDENCE"] {
      let root = URL(fileURLWithPath: directory)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      ui.window?.contentView?.layoutSubtreeIfNeeded()
      if let view = ui.window?.contentView,
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
      {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
          view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        try bitmap.representation(using: .png, properties: [:])?.write(
          to: root.appendingPathComponent("search-window.png"))
      }
      let report: [String: Any] = [
        "query": ui.queryField.stringValue,
        "visibleResults": w.results.count,
        "thumbnails": w.results.filter { $0.thumbnail != nil }.count,
        "selectedSourceSHA256": first.hit.sourceSHA256, "requestedSeconds": jump.requestedSeconds,
        "landedSeconds": jump.landedSeconds, "advancedSeconds": w.playback.snapshot.positionSeconds,
        "nativeResultButtonAction": true, "muted": w.playback.isMuted,
      ]
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: root.appendingPathComponent("ui-flow.json"))
    }
  }
}
