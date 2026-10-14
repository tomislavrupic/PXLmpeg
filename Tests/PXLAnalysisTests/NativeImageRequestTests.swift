import Foundation
import PXLMedia
import XCTest

@testable import PXLAnalysis

private final class CallbackSlot: @unchecked Sendable {
  private let lock = NSLock()
  private var callback: (@Sendable (Result<Int, any Error>) -> Void)?
  var started: Bool {
    lock.lock()
    defer { lock.unlock() }
    return callback != nil
  }
  func install(_ callback: @escaping @Sendable (Result<Int, any Error>) -> Void) {
    lock.lock()
    self.callback = callback
    lock.unlock()
  }
  func complete() {
    lock.lock()
    let callback = self.callback
    self.callback = nil
    lock.unlock()
    callback?(.success(42))
  }
}
final class NativeImageRequestTests: XCTestCase {
  private func waitStarted(_ slot: CallbackSlot) async throws {
    let end = ContinuousClock.now + .seconds(2)
    while !slot.started && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertTrue(slot.started)
  }
  func testTimeoutReturnsFailureAndIgnoresLateNativeSuccess() async throws {
    let slot = CallbackSlot()
    let request = Task {
      try await NativeImageRequest<Int>.run(
        timeout: .milliseconds(30),
        start: { slot.install($0) }, cancel: {})
    }
    try await waitStarted(slot)
    try await Task.sleep(for: .milliseconds(80))
    slot.complete()
    do {
      _ = try await request.value
      XCTFail("Native wait exceeded its deadline and returned late success")
    } catch let e as MediaError { XCTAssertEqual(e.code, .noProgress) }
  }
  func testCancellationWinsOverLateNativeSuccess() async throws {
    let slot = CallbackSlot()
    let request = Task {
      try await NativeImageRequest<Int>.run(
        timeout: .seconds(1),
        start: { slot.install($0) }, cancel: {})
    }
    try await waitStarted(slot)
    request.cancel()
    try await Task.sleep(for: .milliseconds(10))
    slot.complete()
    do {
      _ = try await request.value
      XCTFail("Cancelled request returned native success")
    } catch { XCTAssertTrue(error is CancellationError) }
  }
  func testTimedOutNativeWorkRemainsBoundedUntilCallbacksReleaseIt() async throws {
    let first = CallbackSlot()
    let second = CallbackSlot()
    let a = Task {
      try await NativeImageRequest<Int>.run(
        timeout: .milliseconds(20),
        start: { first.install($0) }, cancel: {})
    }
    let b = Task {
      try await NativeImageRequest<Int>.run(
        timeout: .milliseconds(20),
        start: { second.install($0) }, cancel: {})
    }
    try await waitStarted(first)
    try await waitStarted(second)
    try await Task.sleep(for: .milliseconds(60))
    do {
      _ = try await NativeImageRequest<Int>.run(
        timeout: .seconds(1), start: { $0(.success(3)) }, cancel: {})
      XCTFail("Admitted more native work while two timed-out calls were outstanding")
    } catch let e as MediaError { XCTAssertEqual(e.code, .engineBusy) }
    first.complete()
    second.complete()
    _ = await a.result
    _ = await b.result
    let next = try await NativeImageRequest<Int>.run(
      timeout: .seconds(1), start: { $0(.success(9)) }, cancel: {})
    XCTAssertEqual(next, 9)
  }
}
