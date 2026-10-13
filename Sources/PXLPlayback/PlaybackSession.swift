import AVFoundation
import Foundation
import PXLAppleMedia
import PXLMedia

public enum PlaybackState: String, Sendable {
  case idle, loading, ready, playing, paused, seeking, buffering, ended, failed
}

public struct PlaybackSnapshot: Sendable {
  public var state: PlaybackState = .idle
  public var source: URL?
  public var asset: AssetDescriptor?
  public var positionSeconds: Double = 0
  public var durationSeconds: Double = 0
  public var error: String?
  public var isPlaybackRequested = false
  /// AVPlayer owns synchronization and opaque decoder buffers. This is not the transcode backend.
  public let backend = "apple-avplayer"
  public init() {}
}

/// One local playback item. Host retains security-scoped access until close/replacement.
/// All controls and the coalesced snapshot callback run on the main actor.
@MainActor public final class PlaybackSession {
  public private(set) var snapshot = PlaybackSnapshot()
  public var onChange: (@MainActor (PlaybackSnapshot) -> Void)?
  public var volume: Float {
    get { player.volume }
    set { player.volume = newValue.isFinite ? min(1, max(0, newValue)) : 1 }
  }
  public var isMuted: Bool {
    get { player.isMuted }
    set { player.isMuted = newValue }
  }
  internal let player = AVPlayer()
  private var generation = UUID()
  private var seekID: UUID?
  private var seekResult: Bool?
  private var wantsPlayback = false
  private var assetID: UUID?
  private var lastPublished: ObservationKey?
  private var isPublishing = false
  private var publicationQueued = false

  private struct ObservationKey: Equatable {
    let state: PlaybackState
    let source: URL?
    let asset: UUID?
    let position: Double
    let duration: Double
    let error: String?
    let playRequested: Bool
  }
  private var loadingTask: Task<Void, Never>?
  private var loaded: Result<AssetInput, any Error>?
  private var monitor: Task<Void, Never>?
  private let timeout: Duration = .seconds(15)

  public init() {}

  deinit {
    loadingTask?.cancel()
    monitor?.cancel()
  }

  public func open(_ source: URL, colourPolicy: InputColourPolicy = .requireTagged) async throws {
    try Task.checkCancellation()
    reset()
    let token = generation
    snapshot = PlaybackSnapshot()
    snapshot.source = source
    snapshot.state = .loading
    do {
      publish()
      try check(token)
      // Do not make the caller wait for a superseded native metadata load. Cancellation is
      // advisory to AVFoundation; the token also prevents its eventual result from being used.
      loadingTask = Task { [weak self] in
        let result: Result<AssetInput, any Error>
        do {
          result = .success(try await AssetInput.open(source, colourPolicy: colourPolicy))
        } catch { result = .failure(error) }
        guard let self, self.generation == token, !Task.isCancelled else { return }
        self.loaded = result
      }
      let deadline = ContinuousClock.now + timeout
      while loaded == nil {
        try check(token)
        try checkDeadline(deadline)
        try await Task.sleep(for: .milliseconds(20))
      }
      try check(token)
      let input = try loaded!.get()
      loaded = nil
      loadingTask = nil
      let item = AVPlayerItem(asset: input.asset)
      player.replaceCurrentItem(with: item)
      while item.status != .readyToPlay {
        try check(token)
        if item.status == .failed { throw nativeFailure(item.error) }
        try checkDeadline(deadline)
        try await Task.sleep(for: .milliseconds(20))
      }
      try check(token)
      snapshot.asset = input.descriptor
      assetID = UUID()
      snapshot.durationSeconds =
        item.duration.isNumeric
        ? item.duration.seconds : input.descriptor.duration.seconds
      snapshot.state = .ready
      startMonitor(token)
      publish()
      try check(token)
    } catch {
      guard generation == token else { throw CancellationError() }
      reset()
      if error is CancellationError {
        snapshot = PlaybackSnapshot()
      } else {
        snapshot.state = .failed
        snapshot.error = error.localizedDescription
      }
      publish()
      throw error
    }
  }

  public func play() {
    guard snapshot.asset != nil, snapshot.state != .failed, snapshot.state != .ended else { return }
    wantsPlayback = true
    if seekID == nil {
      player.play()
      refresh()
    }
  }

  public func pause() {
    wantsPlayback = false
    player.pause()
    if seekID == nil, snapshot.asset != nil, snapshot.state != .failed {
      refresh()
    }
  }

  /// Zero-tolerance native seek. A new seek/open/close cancels the previous logical operation.
  /// Native presentation is still limited by the source's sample timing.
  public func seek(to seconds: Double) async throws {
    try Task.checkCancellation()
    guard snapshot.asset != nil, snapshot.state != .failed,
      seconds.isFinite, seconds >= 0, seconds <= snapshot.durationSeconds
    else {
      throw MediaError(
        .invalidRequest, stage: "playback",
        "Seek requires an open item and a time within its duration")
    }
    let token = generation
    let operation = UUID()
    player.currentItem?.cancelPendingSeeks()
    seekID = operation
    seekResult = nil
    player.pause()
    snapshot.state = .seeking
    var completedOwnSeek = false
    do {
      publish()
      try check(token, seek: operation)
      player.seek(
        to: CMTime(seconds: seconds, preferredTimescale: 600_000),
        toleranceBefore: .zero, toleranceAfter: .zero
      ) { [weak self] finished in
        Task { @MainActor [weak self] in
          guard let self, self.generation == token, self.seekID == operation else { return }
          self.seekResult = finished
        }
      }
      let deadline = ContinuousClock.now + timeout
      while seekResult == nil {
        try check(token, seek: operation)
        try checkDeadline(deadline)
        try await Task.sleep(for: .milliseconds(10))
      }
      try check(token, seek: operation)
      let finished = seekResult == true
      if !finished { throw nativeFailure(player.currentItem?.error) }
      completedOwnSeek = true
      seekID = nil
      seekResult = nil
      if wantsPlayback { player.play() }
      refresh()
      try check(token)
    } catch {
      if generation == token,
        seekID == operation || (completedOwnSeek && seekID == nil)
      {
        seekID = nil
        seekResult = nil
        player.currentItem?.cancelPendingSeeks()
        wantsPlayback = false
        player.pause()
        refresh()
      }
      throw error
    }
  }

  public func close() {
    reset()
    snapshot = PlaybackSnapshot()
    publish()
  }

  private func reset() {
    generation = UUID()
    assetID = nil
    seekID = nil
    seekResult = nil
    wantsPlayback = false
    loadingTask?.cancel()
    loadingTask = nil
    loaded = nil
    monitor?.cancel()
    monitor = nil
    player.pause()
    player.currentItem?.cancelPendingSeeks()
    player.replaceCurrentItem(with: nil)
  }

  private func check(_ token: UUID, seek: UUID? = nil) throws {
    try Task.checkCancellation()
    guard generation == token, seek == nil || seekID == seek else { throw CancellationError() }
  }

  private func checkDeadline(_ deadline: ContinuousClock.Instant) throws {
    guard ContinuousClock.now < deadline else {
      throw MediaError(.noProgress, stage: "playback", "Native open or seek exceeded 15 seconds")
    }
  }

  private func nativeFailure(_ error: (any Error)?) -> MediaError {
    MediaError(
      .codecFailure, stage: "playback", error?.localizedDescription ?? "Native playback failed")
  }

  private func startMonitor(_ token: UUID) {
    monitor = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        guard let self, self.generation == token else { return }
        self.refresh()
      }
    }
  }

  private func refresh() {
    guard let item = player.currentItem, snapshot.asset != nil else { return }
    if item.status == .failed {
      wantsPlayback = false
      player.pause()
      snapshot.state = .failed
      snapshot.error = nativeFailure(item.error).localizedDescription
    } else {
      let time = player.currentTime()
      if time.isNumeric { snapshot.positionSeconds = max(0, time.seconds) }
      if seekID != nil {
        snapshot.state = .seeking
      } else if snapshot.positionSeconds >= snapshot.durationSeconds - 0.001,
        player.rate == 0
      {
        wantsPlayback = false
        snapshot.state = .ended
      } else if wantsPlayback {
        snapshot.state = player.timeControlStatus == .playing ? .playing : .buffering
      } else if snapshot.state != .ready {
        snapshot.state = .paused
      }
    }
    publish()
  }

  private func publish() {
    snapshot.isPlaybackRequested = wantsPlayback
    let key = ObservationKey(
      state: snapshot.state, source: snapshot.source, asset: assetID,
      position: snapshot.positionSeconds, duration: snapshot.durationSeconds,
      error: snapshot.error, playRequested: wantsPlayback)
    guard key != lastPublished else { return }
    // An observer may issue controls. Deliver at most one later notification for
    // nested changes; never recursively call host code on the same stack.
    if isPublishing {
      if !publicationQueued {
        publicationQueued = true
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.publicationQueued = false
          self.publish()
        }
      }
      return
    }
    lastPublished = key
    isPublishing = true
    defer { isPublishing = false }
    onChange?(snapshot)
  }
}
