import AppKit
import PXLAnalysis
import PXLMedia
import PXLPlayback

public struct SearchResult: Identifiable {
  public let id = UUID()
  public let hit: SearchHit
  public var thumbnail: CGImage?
  public var thumbnailError: String?
  public var thumbnailTime: MediaTime?
}
public enum SearchPhase { case idle, opening, indexing, searching, thumbnails, saving }
public struct PlaybackJump {
  public let source: URL
  public let requestedSeconds: Double
  public let landedSeconds: Double
}

@MainActor public final class SearchWorkspace {
  public let playback = PlaybackSession()
  public var onChange: (() -> Void)?
  public private(set) var sources: [URL] = []
  public private(set) var index: SemanticIndex?
  public private(set) var results: [SearchResult] = []
  public private(set) var phase: SearchPhase = .idle
  public private(set) var status = "Choose footage or open an index"
  public private(set) var error: String?
  public private(set) var models: URL?
  public private(set) var computePolicy: SemanticComputePolicy
  public private(set) var selectedID: UUID?
  public private(set) var lastJump: PlaybackJump?
  public private(set) var colourPolicy: InputColourPolicy = .requireTagged
  public var isBusy: Bool { phase != .idle }
  public var canSearch: Bool {
    index != nil && ![SearchPhase.opening, .indexing, .saving].contains(phase)
  }
  var workTask: Task<Void, Never>?
  var playbackTask: Task<Void, Never>?
  private var ticket = UUID()
  private var playbackTicket = UUID()
  private var closed = false
  private var analyzer: SemanticAnalyzer?
  private let verifier = SemanticSourceVerifier()
  private let store = IndexStore()
  private let thumbnails = ThumbnailRenderer()

  public init(models: URL? = nil, computePolicy: SemanticComputePolicy = .cpuAndNeuralEngine) {
    self.models = models
    self.computePolicy = computePolicy
    playback.isMuted = true
  }
  public func chooseSources(_ urls: [URL], colourPolicy: InputColourPolicy) {
    cancel()
    stopPlayback()
    index = nil
    results = []
    sources = []
    guard (1...32).contains(urls.count), urls.allSatisfy(\.isFileURL),
      Set(urls.map(\.standardizedFileURL)).count == urls.count
    else {
      showError("Choose 1–32 distinct local video files.")
      return
    }
    sources = urls
    self.colourPolicy = colourPolicy
    status = "\(sources.count) clips selected · ready to index"
    error = nil
    changed()
  }
  public func configureModels(_ url: URL) {
    cancel()
    models = url
    discardAnalyzer()
    results = []
    stopPlayback()
    error = nil
    status = "Model folder selected · MobileCLIP-S2"
    changed()
  }
  public func configureComputePolicy(_ policy: SemanticComputePolicy) {
    cancel()
    computePolicy = policy
    discardAnalyzer()
    results = []
    stopPlayback()
    status =
      policy == .cpuOnly
      ? "CPU compatibility selected · inference excludes ANE/GPU" : "Neural Engine + CPU selected"
    changed()
  }
  private func engine() throws -> SemanticAnalyzer {
    if let analyzer { return analyzer }
    guard let models else {
      throw MediaError(
        .invalidRequest, stage: "search-ui", "Choose the downloaded MobileCLIP model folder first.")
    }
    let next = try SemanticAnalyzer(models: models, computePolicy: computePolicy)
    analyzer = next
    return next
  }
  public func buildIndex() {
    guard !sources.isEmpty else {
      showError("Choose footage first.")
      return
    }
    let worker: SemanticAnalyzer
    do { worker = try engine() } catch {
      showError(error.localizedDescription)
      return
    }
    let selected = sources
    let policy = colourPolicy
    stopPlayback()
    results = []
    let cap = min(256, 4096 / selected.count)
    schedule(
      .indexing, "Indexing \(selected.count) clips · first model load may take several seconds"
    ) { w, token in
      let value = try await worker.index(
        sources: selected,
        options: try SamplingOptions(intervalSeconds: 1, maximumSamplesPerSource: cap),
        colourPolicy: policy)
      try w.check(token)
      w.index = value
      w.status = w.indexSummary(value)
    }
  }
  public func openIndex(_ url: URL) {
    stopPlayback()
    results = []
    index = nil
    schedule(.opening, "Opening index…") { w, token in
      let value = try await w.store.read(url)
      try w.check(token)
      w.index = value
      w.sources = value.sources.map(\.url)
      w.colourPolicy = value.inputColourPolicy
      w.status = w.indexSummary(value)
    }
  }
  public func saveIndex(_ url: URL) {
    guard let index else {
      showError("Index footage first.")
      return
    }
    schedule(.saving, "Saving a new index…") { w, token in
      try await w.store.write(index, to: url)
      try w.check(token)
      w.status = "Index saved · \(url.lastPathComponent)"
    }
  }
  public func search(_ text: String) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let index, !text.isEmpty, text.utf8.count <= 8192 else {
      cancel()
      showError("Open an index and enter a short search phrase.")
      return
    }
    let worker: SemanticAnalyzer
    do { worker = try engine() } catch {
      showError(error.localizedDescription)
      return
    }
    stopPlayback()
    results = []
    schedule(.searching, "Checking source contents and searching…") { w, token in
      try await w.verifier.verify(index: index)
      try w.check(token)
      let hits = try await worker.query(text, index: index, limit: 100)
      try w.check(token)
      w.results = ResultSelection.candidates(hits).map { SearchResult(hit: $0) }
      w.phase = .thumbnails
      w.status = "\(w.results.count) sampled matches · loading thumbnails…"
      w.changed()
      for row in w.results {
        try w.check(token)
        do {
          let preview = try await w.thumbnails.image(source: row.hit.source, at: row.hit.actualTime)
          try w.check(token)
          if let i = w.results.firstIndex(where: { $0.id == row.id }) {
            w.results[i].thumbnail = preview.image
            w.results[i].thumbnailTime = preview.actualTime
          }
        } catch is CancellationError { throw CancellationError() } catch {
          try w.check(token)
          if let i = w.results.firstIndex(where: { $0.id == row.id }) {
            w.results[i].thumbnailError = error.localizedDescription
          }
        }
        w.changed()
      }
      let failed = w.results.filter { $0.thumbnail == nil }.count
      w.status =
        "\(w.results.count) sampled matches · click to play"
        + (failed > 0 ? " · \(failed) thumbnails unavailable" : "")
    }
  }
  public func select(_ id: UUID) {
    guard let row = results.first(where: { $0.id == id }), let index else {
      showError("This result is no longer available. Search again.")
      return
    }
    let prior = playbackTask
    prior?.cancel()
    playback.close()
    let token = UUID()
    playbackTicket = token
    selectedID = id
    lastJump = nil
    changed()
    playbackTask = Task { [weak self] in
      await prior?.value
      guard let self else { return }
      do {
        try self.checkPlayback(token)
        try await verifier.verify(source: row.hit.source, sha256: row.hit.sourceSHA256)
        try self.checkPlayback(token)
        try await playback.open(row.hit.source, colourPolicy: index.inputColourPolicy)
        try self.checkPlayback(token)
        try await playback.seek(to: row.hit.actualTime.seconds)
        try self.checkPlayback(token)
        lastJump = PlaybackJump(
          source: row.hit.source, requestedSeconds: row.hit.actualTime.seconds,
          landedSeconds: playback.snapshot.positionSeconds)
        playback.play()
        error = nil
        changed()
      } catch is CancellationError {} catch {
        guard playbackTicket == token, !closed else { return }
        playback.close()
        showError(error.localizedDescription)
      }
    }
  }
  public func cancel() {
    ticket = UUID()
    workTask?.cancel()
    phase = .idle
    status = "Cancelled"
    error = nil
    changed()
  }
  public func close() {
    closed = true
    cancel()
    stopPlayback()
    discardAnalyzer()
    onChange = nil
    playback.onChange = nil
  }
  private func discardAnalyzer() {
    let previous = analyzer
    analyzer = nil
    if let previous {
      Task.detached(priority: .utility) { withExtendedLifetime(previous) {} }
    }
  }
  private func stopPlayback() {
    playbackTicket = UUID()
    playbackTask?.cancel()
    playback.close()
    selectedID = nil
    lastJump = nil
  }
  private func checkPlayback(_ token: UUID) throws {
    try Task.checkCancellation()
    guard !closed, playbackTicket == token else { throw CancellationError() }
  }
  private func check(_ token: UUID) throws {
    try Task.checkCancellation()
    guard !closed, ticket == token else { throw CancellationError() }
  }
  private func schedule(
    _ phase: SearchPhase, _ message: String,
    operation: @escaping @MainActor (SearchWorkspace, UUID) async throws -> Void
  ) {
    guard !closed else { return }
    let previous = workTask
    previous?.cancel()
    let token = UUID()
    ticket = token
    self.phase = phase
    status = message
    error = nil
    changed()
    workTask = Task(priority: .utility) { [weak self] in
      await previous?.value
      guard let self else { return }
      do {
        try check(token)
        try await operation(self, token)
        try check(token)
        self.phase = .idle
        changed()
      } catch {
        guard ticket == token, !closed else { return }
        self.phase = .idle
        if error is CancellationError {
          status = "Cancelled"
          changed()
        } else {
          showError(error.localizedDescription)
        }
      }
    }
  }
  private func indexSummary(_ index: SemanticIndex) -> String {
    let truncated = index.sources.filter(\.truncated).count
    return "\(index.frames.count) sampled frames · \(index.sources.count) clips · ready to search"
      + (truncated > 0 ? " · \(truncated) clips only partially indexed" : "")
  }
  private func showError(_ message: String) {
    error = message
    status = message
    changed()
  }
  private func changed() { if !closed { onChange?() } }
}
