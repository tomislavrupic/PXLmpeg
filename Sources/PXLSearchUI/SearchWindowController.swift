import AppKit
import PXLMedia
import PXLPlayback
import UniformTypeIdentifiers

@MainActor
public final class SearchWindowController: NSWindowController, NSWindowDelegate,
  NSMenuItemValidation, NSOpenSavePanelDelegate
{
  public let workspace: SearchWorkspace
  let queryField = NSSearchField()
  let searchButton = NSButton(title: "Search", target: nil, action: nil)
  private(set) var resultButtons: [NSButton] = []
  private let indexButton = NSButton(title: "Index Footage", target: nil, action: nil)
  private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  private let assume = NSButton(
    checkboxWithTitle: "Assume Rec.709 for untagged SDR", target: nil, action: nil)
  private let computeMenu = NSPopUpButton(frame: .zero, pullsDown: false)
  private let modelLabel = NSTextField(labelWithString: "Models needed")
  private let sourceLabel = NSTextField(labelWithString: "No footage selected")
  private let statusLabel = NSTextField(wrappingLabelWithString: "Choose footage or open an index")
  private let resultsStack = NSStackView()
  private let spinner = NSProgressIndicator()
  private let playButton = NSButton(title: "Play", target: nil, action: nil)
  private let timeline = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
  private let mute = NSButton(checkboxWithTitle: "Mute", target: nil, action: nil)
  private let clock = NSTextField(labelWithString: "00:00.000 / 00:00.000")
  private let previewLabel = NSTextField(labelWithString: "Select a result to preview")
  private var rowRevision: [String] = []
  private var seekTask: Task<Void, Never>?

  public init(workspace: SearchWorkspace) {
    self.workspace = workspace
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    super.init(window: window)
    window.title = "PXLmpeg Search · Early Research"
    window.minSize = NSSize(width: 920, height: 620)
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.appearance = NSAppearance(named: .darkAqua)
    buildContent(window.contentView!)
    workspace.onChange = { [weak self] in self?.render() }
    workspace.playback.onChange = { [weak self] snapshot in self?.renderPlayback(snapshot) }
    render()
    renderPlayback(workspace.playback.snapshot)
    window.center()
  }
  @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(workspace:)") }

  private func buildContent(_ content: NSView) {
    let title = NSTextField(labelWithString: "PXLmpeg Search")
    title.font = .systemFont(ofSize: 25, weight: .semibold)
    let subtitle = NSTextField(labelWithString: "Local footage. Find a moment, then play it.")
    subtitle.textColor = .secondaryLabelColor
    let heading = NSStackView(views: [title, subtitle])
    heading.orientation = .vertical
    heading.alignment = .leading
    heading.spacing = 4
    let models = NSButton(title: "Models…", target: self, action: #selector(chooseModels))
    modelLabel.font = .systemFont(ofSize: 11)
    modelLabel.textColor = .secondaryLabelColor
    computeMenu.addItems(withTitles: ["Neural Engine + CPU", "CPU compatibility"])
    computeMenu.controlSize = .small
    computeMenu.target = self
    computeMenu.action = #selector(changeCompute)
    computeMenu.setAccessibilityLabel("Inference device policy")
    let modelStack = NSStackView(views: [models, computeMenu, modelLabel])
    modelStack.orientation = .vertical
    modelStack.alignment = .trailing
    modelStack.spacing = 4
    let top = horizontal([heading, NSView(), modelStack])
    let add = NSButton(title: "Add Footage…", target: self, action: #selector(addFootage))
    indexButton.target = self
    indexButton.action = #selector(indexFootage)
    cancelButton.target = self
    cancelButton.action = #selector(cancelWork)
    assume.target = self
    assume.action = #selector(changeInterpretation)
    assume.font = .systemFont(ofSize: 11)
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    sourceLabel.font = .systemFont(ofSize: 12)
    sourceLabel.textColor = .secondaryLabelColor
    let toolbar = horizontal([add, indexButton, cancelButton, spinner, NSView(), sourceLabel])
    queryField.placeholderString = "Describe a scene, object or person…"
    queryField.target = self
    queryField.action = #selector(runSearch)
    queryField.sendsSearchStringImmediately = false
    queryField.sendsWholeSearchString = true
    queryField.setAccessibilityLabel("Search footage by visual description")
    searchButton.target = self
    searchButton.action = #selector(runSearch)
    searchButton.bezelStyle = .rounded
    let query = horizontal([queryField, searchButton])
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    let document = FlippedDocument()
    document.translatesAutoresizingMaskIntoConstraints = false
    resultsStack.orientation = .vertical
    resultsStack.alignment = .leading
    resultsStack.spacing = 8
    resultsStack.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(resultsStack)
    scroll.documentView = document
    NSLayoutConstraint.activate([
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      resultsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      resultsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
      resultsStack.topAnchor.constraint(equalTo: document.topAnchor),
      resultsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
      scroll.widthAnchor.constraint(equalToConstant: 390),
    ])
    let video = PlaybackView(session: workspace.playback)
    video.wantsLayer = true
    video.layer?.cornerRadius = 9
    video.layer?.masksToBounds = true
    playButton.target = self
    playButton.action = #selector(togglePlay)
    timeline.target = self
    timeline.action = #selector(seek)
    timeline.isContinuous = false
    timeline.setAccessibilityLabel("Playback position")
    mute.target = self
    mute.action = #selector(changeMute)
    mute.state = .on
    clock.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    clock.textColor = .secondaryLabelColor
    previewLabel.font = .systemFont(ofSize: 12, weight: .medium)
    previewLabel.lineBreakMode = .byTruncatingMiddle
    let controls = horizontal([playButton, timeline, mute])
    let preview = NSView()
    for view in [previewLabel, video, controls, clock] {
      view.translatesAutoresizingMaskIntoConstraints = false
      preview.addSubview(view)
    }
    NSLayoutConstraint.activate([
      previewLabel.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
      previewLabel.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
      previewLabel.topAnchor.constraint(equalTo: preview.topAnchor),
      video.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
      video.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
      video.topAnchor.constraint(equalTo: previewLabel.bottomAnchor, constant: 12),
      video.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -12),
      controls.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
      controls.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
      controls.bottomAnchor.constraint(equalTo: clock.topAnchor, constant: -8),
      clock.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
      clock.bottomAnchor.constraint(equalTo: preview.bottomAnchor),
      preview.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
    ])
    let body = NSView()
    for pane in [scroll, preview] {
      pane.translatesAutoresizingMaskIntoConstraints = false
      body.addSubview(pane)
    }
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor),
      scroll.topAnchor.constraint(equalTo: body.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: body.bottomAnchor),
      preview.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 20),
      preview.trailingAnchor.constraint(equalTo: body.trailingAnchor),
      preview.topAnchor.constraint(equalTo: body.topAnchor),
      preview.bottomAnchor.constraint(equalTo: body.bottomAnchor),
    ])
    statusLabel.font = .systemFont(ofSize: 12)
    statusLabel.maximumNumberOfLines = 2
    let note = NSTextField(
      labelWithString: "Early research · sampled visual matches · similarity is not certainty")
    note.font = .systemFont(ofSize: 11)
    note.textColor = .tertiaryLabelColor
    let rows: [NSView] = [top, toolbar, assume, query, body, statusLabel, note]
    for row in rows {
      row.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(row)
    }
    var constraints: [NSLayoutConstraint] = []
    for (i, row) in rows.enumerated() {
      constraints += [
        row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
        row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
        row.topAnchor.constraint(
          equalTo: i == 0 ? content.topAnchor : rows[i - 1].bottomAnchor, constant: i == 0 ? 20 : 12
        ),
      ]
    }
    constraints += [
      note.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
      statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
      body.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
    ]
    NSLayoutConstraint.activate(constraints)
  }
  private func horizontal(_ views: [NSView]) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 12
    return stack
  }
  private func render() {
    indexButton.isEnabled = !workspace.sources.isEmpty && !workspace.isBusy
    cancelButton.isEnabled = workspace.isBusy
    searchButton.isEnabled = workspace.canSearch
    queryField.isEnabled = workspace.canSearch
    assume.isEnabled = !workspace.isBusy
    if !workspace.sources.isEmpty {
      assume.state = workspace.colourPolicy == .assumeBT709Limited ? .on : .off
    }
    sourceLabel.stringValue =
      "\(workspace.sources.count) clips"
      + (workspace.index.map { " · \($0.frames.count) frames" } ?? "")
    sourceLabel.toolTip = workspace.sources.map(\.lastPathComponent).joined(separator: "\n")
    modelLabel.stringValue = workspace.models == nil ? "Models needed" : "MobileCLIP-S2 · local"
    computeMenu.selectItem(at: workspace.computePolicy == .cpuOnly ? 1 : 0)
    computeMenu.isEnabled = !workspace.isBusy
    modelLabel.toolTip = workspace.models?.path
    statusLabel.stringValue = workspace.error ?? workspace.status
    statusLabel.textColor = workspace.error == nil ? .secondaryLabelColor : .systemRed
    if workspace.isBusy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    let revision = workspace.results.map {
      "\($0.id)-\($0.thumbnail != nil)-\($0.thumbnailError != nil)-\($0.id == workspace.selectedID)"
    }
    if revision != rowRevision || resultsStack.arrangedSubviews.isEmpty {
      rowRevision = revision
      for view in resultsStack.arrangedSubviews {
        resultsStack.removeArrangedSubview(view)
        view.removeFromSuperview()
      }
      resultButtons = []
      if workspace.results.isEmpty {
        let empty = NSTextField(
          wrappingLabelWithString: workspace.index == nil
            ? "Add footage and index it, or open a saved index from the File menu."
            : "Try a visual description, such as “a guitar beside a plant”.")
        empty.font = .systemFont(ofSize: 14)
        empty.textColor = .secondaryLabelColor
        resultsStack.addArrangedSubview(empty)
        empty.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true
      }
      for result in workspace.results {
        let button = ResultButton(
          result: result, selected: workspace.selectedID == result.id,
          target: self, action: #selector(resultClicked(_:)))
        resultsStack.addArrangedSubview(button)
        button.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true
        resultButtons.append(button)
      }
    }
  }
  private func renderPlayback(_ snapshot: PlaybackSnapshot) {
    let available = snapshot.asset != nil && snapshot.state != .failed && snapshot.state != .loading
    playButton.isEnabled = available
    timeline.isEnabled = available
    playButton.title = snapshot.isPlaybackRequested ? "Pause" : "Play"
    timeline.maxValue = max(0.001, snapshot.durationSeconds)
    if !(timeline.cell?.isHighlighted ?? false) { timeline.doubleValue = snapshot.positionSeconds }
    clock.stringValue =
      "\(ResultButton.time(snapshot.positionSeconds)) / \(ResultButton.time(snapshot.durationSeconds)) · \(snapshot.state.rawValue)"
    previewLabel.stringValue =
      snapshot.error ?? snapshot.source?.lastPathComponent ?? "Select a result to preview"
    mute.state = workspace.playback.isMuted ? .on : .off
  }
  public func setQuery(_ text: String) { queryField.stringValue = text }
  public func search(_ text: String) {
    setQuery(text)
    workspace.search(text)
  }
  @objc private func runSearch() { workspace.search(queryField.stringValue) }
  @objc private func resultClicked(_ sender: ResultButton) { workspace.select(sender.resultID) }
  @objc private func indexFootage() { workspace.buildIndex() }
  @objc private func cancelWork() { workspace.cancel() }
  @objc private func changeInterpretation() {
    guard !workspace.sources.isEmpty else { return }
    workspace.chooseSources(
      workspace.sources, colourPolicy: assume.state == .on ? .assumeBT709Limited : .requireTagged)
  }
  @objc public func addFootage() { pickFootage(replace: false) }
  @objc public func replaceFootage() { pickFootage(replace: true) }
  private func pickFootage(replace: Bool) {
    guard let window else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.quickTimeMovie, .mpeg4Movie]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let self else { return }
      let urls = (replace ? [] : workspace.sources) + panel.urls
      var seen = Set<URL>()
      let unique = urls.filter { seen.insert($0.standardizedFileURL).inserted }
      workspace.chooseSources(
        unique, colourPolicy: assume.state == .on ? .assumeBT709Limited : .requireTagged)
    }
  }
  @objc private func changeCompute() {
    workspace.configureComputePolicy(
      computeMenu.indexOfSelectedItem == 1 ? .cpuOnly : .cpuAndNeuralEngine)
  }
  @objc private func chooseModels() {
    guard let window else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.message =
      "Choose the folder containing the fetched MobileCLIP models and download-manifest.json."
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let self, let url = panel.url else { return }
      UserDefaults.standard.set(url.path, forKey: "modelDirectory")
      workspace.configureModels(url)
    }
  }
  @objc public func openIndex() {
    guard let window else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      self?.workspace.openIndex(url)
    }
  }
  @objc public func saveIndex() {
    guard let window else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.title = "Save a new index"
    panel.nameFieldStringValue = "PXLmpeg-index.json"
    panel.delegate = self
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      self?.workspace.saveIndex(url)
    }
  }
  public func panel(_ sender: Any, validate url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      throw NSError(
        domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError,
        userInfo: [
          NSLocalizedDescriptionKey: "Choose a new filename; existing files are preserved."
        ])
    }
  }
  public func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if item.action == #selector(saveIndex) { return workspace.index != nil && !workspace.isBusy }
    return true
  }
  @objc private func togglePlay() {
    let session = workspace.playback
    if session.snapshot.isPlaybackRequested {
      session.pause()
    } else if session.snapshot.state == .ended {
      performSeek(0, replay: true)
    } else {
      session.play()
    }
  }
  @objc private func seek() { performSeek(timeline.doubleValue) }
  private func performSeek(_ seconds: Double, replay: Bool = false) {
    seekTask?.cancel()
    seekTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await workspace.playback.seek(to: seconds)
        try Task.checkCancellation()
        if replay { workspace.playback.play() }
      } catch is CancellationError {} catch {
        previewLabel.stringValue = error.localizedDescription
      }
    }
  }
  @objc private func changeMute() { workspace.playback.isMuted = mute.state == .on }
  public func windowWillClose(_ notification: Notification) {
    seekTask?.cancel()
    workspace.close()
  }
}

private final class FlippedDocument: NSView {
  override var isFlipped: Bool { true }
}
