import CoreMedia
import Foundation
import PXLMedia

// Atomically assigns generations AND queues operations. A new-generation read cannot
// overtake its seek. Admission is checked before advancing the working generation.
final class SessionFence: @unchecked Sendable {
  private let lock = NSLock()
  private var generation: UInt64 = 1
  private var cancelled = false
  private var pending = 0
  func schedule(advancing: Bool, submit: (UInt64) -> Void) throws {
    try lock.withLock {
      try validate(generation)
      guard pending < 8 else {
        throw MediaError(
          .resourceLimit, stage: "professional-session", "At most eight pending native operations")
      }
      if advancing { generation += 1 }
      pending += 1
      submit(generation)
    }
  }
  func finished() { lock.withLock { pending -= 1 } }
  @discardableResult func cancel() -> Bool {
    lock.withLock {
      let first = !cancelled
      cancelled = true
      return first
    }
  }
  func isCurrent(_ value: UInt64) -> Bool { lock.withLock { !cancelled && generation == value } }
  func check(_ value: UInt64) throws { try lock.withLock { try validate(value) } }
  private func validate(_ value: UInt64) throws {
    guard !cancelled, generation == value else {
      throw MediaError(
        .cancelled, stage: "professional-session",
        "Closed/cancelled session or superseded seek generation")
    }
  }
}

/// Pull-based ingest, not a player clock or output renderer. Native calls run on a dedicated queue.
/// A cancelled read cancels the whole session. Cancellation cannot preempt a blocked OS/driver call.
public final class ProfessionalMediaSession: @unchecked Sendable {
  public let descriptor: ProfessionalAssetDescriptor
  private let queue = DispatchQueue(
    label: "studio.pixelrecords.pxlmpeg.professional", qos: .userInitiated)
  private let fence = SessionFence()
  private let worker: ProfessionalWorker
  private init(source: ProfessionalSource, options: ProfessionalMediaOptions) {
    descriptor = source.descriptor
    worker = ProfessionalWorker(source: source, options: options)
  }
  public static func open(
    _ url: URL, options: ProfessionalMediaOptions = ProfessionalMediaOptions()
  ) async throws -> ProfessionalMediaSession {
    try options.validate()
    try Task.checkCancellation()
    let source = try await ProfessionalSource.open(url)
    try Task.checkCancellation()
    let session = ProfessionalMediaSession(source: source, options: options)
    try await session.perform { worker, _ in try worker.start(at: .zero) }
    return session
  }
  public func nextVideoFrame() async throws -> ProfessionalVideoFrame? {
    try await perform { [fence] worker, generation in
      try worker.nextVideo(generation: generation, check: { try fence.check(generation) })
    }
  }
  public func nextAudioChunk(maximumFrames: Int = 1024) async throws -> ProfessionalAudioChunk? {
    guard (1...8192).contains(maximumFrames) else {
      throw MediaError(.invalidRequest, stage: "pcm-read", "Chunk size must be 1–8192 frames")
    }
    return try await perform { [fence] worker, generation in
      try worker.nextAudio(
        maximumFrames: maximumFrames, generation: generation,
        check: { try fence.check(generation) })
    }
  }
  /// First video PTS >= target; audio starts at the first 48 kHz sample >= target.
  /// Host discards already-delivered older generations and flushes its own renderer/audio queue.
  @discardableResult public func seek(to target: MediaTime) async throws -> UInt64 {
    let cm = CMTime(value: target.value, timescale: target.timescale)
    let end = CMTimeAdd(
      CMTime(value: descriptor.videoStart.value, timescale: descriptor.videoStart.timescale),
      CMTime(value: descriptor.videoDuration.value, timescale: descriptor.videoDuration.timescale))
    guard cm >= .zero, cm <= end else {
      throw MediaError(
        .invalidRequest, stage: "professional-seek", "Seek must be within source video end")
    }
    return try await perform(advancingGeneration: true) { worker, generation in
      try worker.requireHealthy()
      try worker.start(at: cm)
      return generation
    }
  }
  public func isCurrent(generation: UInt64) -> Bool { fence.isCurrent(generation) }
  /// Immediate generation fence; native teardown follows queued work.
  public func cancel() { if fence.cancel() { queue.async { [worker] in worker.close() } } }
  public func close() async {
    fence.cancel()
    await withCheckedContinuation { continuation in
      queue.async { [worker] in
        worker.close()
        continuation.resume()
      }
    }
  }
  public func metrics() async -> ProfessionalMediaMetrics {
    await withCheckedContinuation { continuation in
      queue.async { [worker] in continuation.resume(returning: worker.metrics()) }
    }
  }
  private func perform<T: Sendable>(
    advancingGeneration: Bool = false,
    _ operation: @escaping @Sendable (ProfessionalWorker, UInt64) throws -> T
  ) async throws -> T {
    try await withTaskCancellationHandler {
      if Task.isCancelled { cancel() }
      return try await withCheckedThrowingContinuation { continuation in
        do {
          try fence.schedule(advancing: advancingGeneration) { ticket in
            queue.async { [worker, fence] in
              defer { fence.finished() }
              do {
                try fence.check(ticket)
                let value = try autoreleasepool { try operation(worker, ticket) }
                try fence.check(ticket)
                continuation.resume(returning: value)
              } catch {
                // Resource pressure and superseded reads are retryable; native/data failures are terminal.
                if let e = error as? MediaError,
                  [.resourceLimit, .cancelled, .invalidRequest].contains(e.code)
                {
                } else {
                  worker.fail(error)
                }
                continuation.resume(throwing: error)
              }
            }
          }
        } catch { continuation.resume(throwing: error) }
      }
    } onCancel: { [self] in
      cancel()
    }
  }
  deinit {
    fence.cancel()
    queue.async { [worker] in worker.close() }
  }
}
