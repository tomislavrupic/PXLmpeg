import Foundation
import PXLMedia

// Lock protects state shared by actor, worker and cancellation handlers. The final
// commit and cancellation decision use this same lock; publication wins only once.
final class JobControl: @unchecked Sendable {
  let id: UUID
  private let lock = NSLock()
  private let timeout: TimeInterval
  private var cancelled = false, committed = false
  private var stalled = false
  private var watchdog: DispatchSourceTimer?
  private var state = "preparing", frames = 0, seconds = 0.0, peak = 0
  private var lastProgress = ProcessInfo.processInfo.systemUptime
  init(id: UUID, timeout: TimeInterval) {
    self.id = id
    self.timeout = timeout
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "PXLmpeg.watchdog"))
    timer.schedule(deadline: .now() + min(timeout / 4, 1), repeating: min(timeout / 4, 1))
    timer.setEventHandler { [weak self] in self?.watchdogTick() }
    watchdog = timer
    timer.resume()
  }
  func stopWatchdog() { watchdog?.cancel() }
  deinit { watchdog?.cancel() }
  func watchdogTick() {
    lock.withLock {
      if !committed && ProcessInfo.processInfo.systemUptime - lastProgress > timeout {
        stalled = true
      }
    }
  }
  func cancel() { lock.withLock { if !committed { cancelled = true } } }
  func check() throws {
    try lock.withLock {
      if cancelled { throw MediaError(.cancelled, stage: state, "Job cancelled") }
      if stalled || ProcessInfo.processInfo.systemUptime - lastProgress > timeout {
        throw MediaError(.noProgress, stage: state, "No backend progress within \(timeout) seconds")
      }
    }
  }
  func setState(_ value: String) {
    lock.withLock {
      state = value
      lastProgress = ProcessInfo.processInfo.systemUptime
    }
  }
  func advance(frames: Int, seconds: Double, peak: Int) {
    lock.withLock {
      self.frames = frames
      self.seconds = seconds
      self.peak = peak
      lastProgress = ProcessInfo.processInfo.systemUptime
    }
  }
  func heartbeat() { lock.withLock { lastProgress = ProcessInfo.processInfo.systemUptime } }
  var snapshot: JobProgress {
    lock.withLock {
      JobProgress(
        jobID: id,
        state: ["failed", "cancelled", "completed"].contains(state)
          ? state
          : stalled ? "stalled-native-teardown-pending" : cancelled ? "cancelling" : state,
        frames: frames, presentationSeconds: seconds)
    }
  }
  var peakBytes: Int { lock.withLock { peak } }
  func commit(_ publish: () throws -> Void) throws {
    try lock.withLock {
      if cancelled {
        throw MediaError(.cancelled, stage: "committing", "Job cancelled before publication")
      }
      if stalled {
        throw MediaError(
          .noProgress, stage: "committing", "Native work exceeded the progress deadline")
      }
      state = "committing"
      try publish()
      committed = true
      state = "completed"
    }
  }
}
