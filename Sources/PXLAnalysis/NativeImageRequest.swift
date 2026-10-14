import Foundation
import PXLMedia

private enum NativeImageScheduling {
  static let queue = DispatchQueue(
    label: "studio.pixelrecords.pxlmpeg.native-images", qos: .utility)
  static let budget = NativeImageBudget()
}
private final class NativeImageBudget: @unchecked Sendable {
  private let lock = NSLock()
  private var pending = 0
  func acquire() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard pending < 2 else { return false }
    pending += 1
    return true
  }
  func release() {
    lock.lock()
    pending -= 1
    lock.unlock()
  }
}

/// Bounds logical waits without claiming that an unresponsive OS call has stopped.
/// A timed-out native call retains its permit until its callback, preventing runaway replacements.
package enum NativeImageRequest<Value: Sendable> {
  package static func run(
    timeout: Duration,
    start: @escaping @Sendable (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void,
    cancel: @escaping @Sendable () -> Void
  ) async throws -> Value {
    let request = ImageRequestState<Value>(cancel: cancel)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        request.install(continuation)
        request.arm(timeout)
        request.start(start)
      }
    } onCancel: {
      request.stop(CancellationError())
    }
  }
}

private final class ImageRequestState<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, any Error>?
  private var terminal: Result<Value, any Error>?
  private var deadline: Task<Void, Never>?
  private var cancelNative: (@Sendable () -> Void)?
  private var nativePending = false
  init(cancel: @escaping @Sendable () -> Void) { cancelNative = cancel }

  func install(_ continuation: CheckedContinuation<Value, any Error>) {
    lock.lock()
    let result = terminal
    if result == nil { self.continuation = continuation }
    lock.unlock()
    if let result { continuation.resume(with: result) }
  }
  func arm(_ timeout: Duration) {
    let timer = Task.detached(priority: .utility) { [self] in
      do { try await Task.sleep(for: timeout) } catch { return }
      stop(
        MediaError(
          .noProgress, stage: "native-image",
          "Native thumbnail/sampling request timed out; native teardown may still be pending."))
    }
    lock.lock()
    if terminal == nil {
      deadline = timer
      lock.unlock()
    } else {
      lock.unlock()
      timer.cancel()
    }
  }
  func start(
    _ body: @escaping @Sendable (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void
  ) {
    lock.lock()
    guard terminal == nil else {
      lock.unlock()
      return
    }
    guard NativeImageScheduling.budget.acquire() else {
      lock.unlock()
      finish(
        .failure(
          MediaError(
            .engineBusy, stage: "native-image",
            "Two native image requests are still pending; no additional work was started.")))
      return
    }
    nativePending = true
    lock.unlock()
    NativeImageScheduling.queue.async { [self] in
      lock.lock()
      let stopped = terminal != nil
      lock.unlock()
      if stopped {
        received(.failure(CancellationError()))
        return
      }
      body { [self] in received($0) }
    }
  }
  func received(_ result: Result<Value, any Error>) {
    lock.lock()
    let release = nativePending
    nativePending = false
    lock.unlock()
    if release { NativeImageScheduling.budget.release() }
    finish(result)
  }
  func stop(_ error: any Error) { finish(.failure(error), cancelWork: true) }
  private func finish(_ result: Result<Value, any Error>, cancelWork: Bool = false) {
    lock.lock()
    guard terminal == nil else {
      lock.unlock()
      return
    }
    terminal = result
    let continuation = self.continuation
    self.continuation = nil
    let timer = deadline
    deadline = nil
    let cancel = cancelWork && nativePending ? cancelNative : nil
    cancelNative = nil
    lock.unlock()
    timer?.cancel()
    // Enqueue native cancellation before waking the caller. Neither path blocks the main actor.
    if let cancel { NativeImageScheduling.queue.async(execute: cancel) }
    continuation?.resume(with: result)
  }
}
