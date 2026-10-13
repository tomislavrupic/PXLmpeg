import AVFoundation
import AppKit
import PXLMedia
import PXLTestSupport
import XCTest

@testable import PXLPlayback

@MainActor final class PlaybackTests: XCTestCase {
  func testNativePlayPauseSeekDecodedFrameAndClose() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("play.mov")
    try FixtureFactory.make(
      at: source, width: 320, height: 192, frames: 72, audio: true, reorder: true)
    let session = PlaybackSession()
    session.isMuted = true
    try await session.open(source)
    XCTAssertEqual(session.snapshot.state, .ready)
    XCTAssertEqual(session.snapshot.asset?.hasAudio, true)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    try XCTUnwrap(session.player.currentItem).add(output)
    session.play()
    try await eventually { session.snapshot.positionSeconds > 0.2 }
    session.pause()
    let paused = session.snapshot.positionSeconds
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(session.snapshot.positionSeconds, paused, accuracy: 0.05)
    try await session.seek(to: 1.5)
    XCTAssertEqual(session.snapshot.positionSeconds, 1.5, accuracy: 1.0 / 24)
    session.play()
    try await eventually {
      output.copyPixelBuffer(forItemTime: session.player.currentTime(), itemTimeForDisplay: nil)
        != nil
    }
    session.pause()
    try await session.seek(to: 0.25)
    XCTAssertEqual(session.snapshot.positionSeconds, 0.25, accuracy: 1.0 / 24)
    let view = PlaybackView(session: session)
    view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(view.layer?.sublayers?.first?.bounds.size, view.bounds.size)
    session.close()
    XCTAssertEqual(session.snapshot.state, .idle)
    XCTAssertNil(session.player.currentItem)
  }

  func testReplacementCloseAndCancellationCannotResurrectOldOpen() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("a.mov")
    let b = dir.appendingPathComponent("b.mov")
    try FixtureFactory.make(at: a, width: 320, height: 192, frames: 24)
    try FixtureFactory.make(at: b, width: 192, height: 320, frames: 24, rotationDegrees: 90)
    let session = PlaybackSession()
    let old = Task { try await session.open(a) }
    await Task.yield()
    try await session.open(b)
    do {
      try await old.value
      XCTFail("Superseded open succeeded")
    } catch is CancellationError {}
    XCTAssertEqual(session.snapshot.source, b)
    XCTAssertEqual(session.snapshot.asset?.rotation, .clockwise90)
    let pending = Task { try await session.open(a) }
    await Task.yield()
    session.close()
    do {
      try await pending.value
      XCTFail("Closed open succeeded")
    } catch is CancellationError {}
    XCTAssertEqual(session.snapshot.state, .idle)
    let cancelled = Task { try await session.open(b) }
    cancelled.cancel()
    do {
      try await cancelled.value
      XCTFail("Cancelled open succeeded")
    } catch is CancellationError {}
    XCTAssertEqual(session.snapshot.state, .idle)
  }

  func testInvalidSourceSeekAndReentrantClose() async throws {
    let session = PlaybackSession()
    do {
      try await session.open(URL(string: "https://example.com/a.mp4")!)
      XCTFail()
    } catch let error as MediaError { XCTAssertEqual(error.code, .unsupportedMedia) }
    XCTAssertEqual(session.snapshot.state, .failed)
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("one.mov")
    try FixtureFactory.make(at: source, width: 320, height: 192, frames: 24)
    try await session.open(source)
    for target in [-1.0, Double.nan, Double.infinity, 2.0] {
      do {
        try await session.seek(to: target)
        XCTFail("Invalid seek accepted")
      } catch let error as MediaError { XCTAssertEqual(error.code, .invalidRequest) }
    }
    session.onChange = { [weak session] snapshot in
      if snapshot.state == .seeking { session?.close() }
    }
    do {
      try await session.seek(to: 0.5)
      XCTFail("Closed seek succeeded")
    } catch is CancellationError {}
    XCTAssertNil(session.player.currentItem)
    XCTAssertEqual(session.snapshot.state, .idle)
    session.onChange = nil
  }

  func testHEVCMain10EndAndReplay() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("hdr.mov")
    try FixtureFactory.make(
      at: source, width: 320, height: 192, frames: 24,
      reorder: true, codec: .hevc, rotationDegrees: 90, bitDepth: 10, colourSpace: .hlg2020)
    let session = PlaybackSession()
    session.isMuted = true
    try await session.open(source)
    XCTAssertEqual(session.snapshot.asset?.bitDepth, 10)
    XCTAssertEqual(session.snapshot.asset?.colourSpace, .hlg2020)
    try await session.seek(to: 0.8)
    session.play()
    try await eventually { session.snapshot.state == .ended }
    try await session.seek(to: 0)
    session.play()
    try await eventually {
      session.snapshot.state == .playing && session.snapshot.positionSeconds > 0.1
    }
    session.close()
  }

  func testCancellingFromLoadingAndSeekingCallbacksCleansUp() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("cancel.mov")
    try FixtureFactory.make(at: source, width: 320, height: 192, frames: 48)
    let session = PlaybackSession()
    var pending: Task<Void, any Error>?
    session.onChange = { snapshot in
      if snapshot.state == .loading { pending?.cancel() }
    }
    pending = Task { try await session.open(source) }
    do {
      try await pending!.value
      XCTFail("Cancelled open succeeded")
    } catch is CancellationError {}
    XCTAssertEqual(session.snapshot.state, .idle)
    session.onChange = nil
    try await session.open(source)
    session.onChange = { snapshot in
      if snapshot.state == .seeking { pending?.cancel() }
    }
    pending = Task { try await session.seek(to: 0.5) }
    do {
      try await pending!.value
      XCTFail("Cancelled seek succeeded")
    } catch is CancellationError {}
    XCTAssertEqual(session.snapshot.state, .paused)
    session.onChange = nil
    session.play()
    try await eventually { session.snapshot.positionSeconds > 0.1 }
    session.close()
  }

  func testLatestSeekWinsAndPauseDuringSeekStaysPaused() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("seeks.mov")
    try FixtureFactory.make(at: source, width: 320, height: 192, frames: 72)
    let session = PlaybackSession()
    try await session.open(source)
    session.play()
    let first = Task { try await session.seek(to: 0.5) }
    await Task.yield()
    try await session.seek(to: 1.5)
    do {
      try await first.value
      XCTFail("Old seek succeeded")
    } catch is CancellationError {}
    XCTAssertEqual(session.snapshot.positionSeconds, 1.5, accuracy: 1.0 / 24)
    XCTAssertTrue(session.snapshot.isPlaybackRequested)
    session.onChange = { [weak session] snapshot in
      if snapshot.state == .seeking { session?.pause() }
    }
    try await session.seek(to: 0.25)
    XCTAssertEqual(session.snapshot.state, .paused)
    XCTAssertEqual(session.player.rate, 0)
    session.onChange = nil
    session.close()
  }

  func testAudioLongerThanVideoUsesWholeTimelineAndUntaggedNeedsPolicy() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("untagged.mov")
    try FixtureFactory.make(
      at: source, width: 320, height: 192, frames: 12,
      tagged: false, audio: true, audioFrames: 48)
    let session = PlaybackSession()
    session.isMuted = true
    do {
      try await session.open(source)
      XCTFail("Implicit colour assumption")
    } catch let error as MediaError { XCTAssertEqual(error.code, .unsupportedMedia) }
    try await session.open(source, colourPolicy: .assumeBT709Limited)
    XCTAssertGreaterThan(session.snapshot.durationSeconds, 1.9)
    try await session.seek(to: 1.8)
    session.play()
    try await eventually { session.snapshot.state == .ended }
    session.close()
  }

  func testOptionalCameraOriginalReadOnly() async throws {
    guard let path = ProcessInfo.processInfo.environment["PXL_PLAYBACK_SOURCE"] else {
      throw XCTSkip("Set PXL_PLAYBACK_SOURCE for local camera validation")
    }
    let session = PlaybackSession()
    session.isMuted = true
    try await session.open(URL(fileURLWithPath: path))
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    try XCTUnwrap(session.player.currentItem).add(output)
    try await session.seek(to: min(1, session.snapshot.durationSeconds / 2))
    session.play()
    try await eventually {
      output.copyPixelBuffer(forItemTime: session.player.currentTime(), itemTimeForDisplay: nil)
        != nil
    }
    session.pause()
    try await session.seek(to: 0)
    session.close()
    XCTAssertEqual(session.snapshot.state, .idle)
  }

  func testReentrantControlsDoNotRecursivelyNotifyAndCloseCancelsCompletingSeek() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("observers.mov")
    try FixtureFactory.make(at: source, width: 320, height: 192, frames: 48)
    let session = PlaybackSession()
    try await session.open(source)
    session.play()
    try await eventually { session.snapshot.positionSeconds > 0.1 }
    var pauses = 0
    session.onChange = { [weak session] snapshot in
      if snapshot.state == .paused {
        pauses += 1
        if pauses < 8 { session?.pause() }
      }
    }
    session.pause()
    XCTAssertEqual(pauses, 1, "Idempotent controls recursively notified")
    session.onChange = { [weak session] snapshot in
      if snapshot.state == .paused, snapshot.positionSeconds > 0.4 { session?.close() }
    }
    do {
      try await session.seek(to: 0.5)
      XCTFail("Seek completed after callback closed it")
    } catch is CancellationError {}
    var closes = 0
    session.onChange = { [weak session] snapshot in
      if snapshot.state == .idle {
        closes += 1
        if closes < 8 { session?.close() }
      }
    }
    try await session.open(source)
    session.close()
    XCTAssertEqual(closes, 1)
    session.onChange = nil
  }

  private func eventually(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(8)
    while !predicate() {
      if ContinuousClock.now > deadline {
        XCTFail("Playback deadline exceeded")
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
}
