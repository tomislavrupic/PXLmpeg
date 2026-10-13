import AppKit
import PXLMedia
import PXLPlayback

@MainActor final class PlayerApplication: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private let session = PlaybackSession()
  private var window: NSWindow!
  private let playButton = NSButton(title: "Play", target: nil, action: nil)
  private let timeline = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
  private let volume = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
  private let clock = NSTextField(labelWithString: "0:00 / 0:00")
  private let status = NSTextField(labelWithString: "Open a video to begin")
  private var operation: Task<Void, Never>?
  private var policy: InputColourPolicy = .requireTagged

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    installMenu()
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = "PXLmpeg · Native Playback Research"
    window.minSize = NSSize(width: 520, height: 360)
    window.delegate = self
    window.isReleasedWhenClosed = false
    let content = window.contentView!
    let video = PlaybackView(session: session)
    let open = NSButton(title: "Open…", target: self, action: #selector(openFile))
    playButton.target = self
    playButton.action = #selector(togglePlay)
    playButton.isEnabled = false
    timeline.target = self
    timeline.action = #selector(seek)
    timeline.isContinuous = false
    timeline.isEnabled = false
    timeline.setAccessibilityLabel("Playback position")
    volume.target = self
    volume.action = #selector(changeVolume)
    volume.setAccessibilityLabel("Volume")
    let mute = NSButton(checkboxWithTitle: "Mute", target: self, action: #selector(changeMute(_:)))
    clock.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    clock.setContentHuggingPriority(.required, for: .horizontal)
    status.font = .systemFont(ofSize: 12)
    status.textColor = .secondaryLabelColor
    status.lineBreakMode = .byTruncatingMiddle
    let controls = NSStackView(views: [open, playButton, timeline, clock, volume, mute])
    controls.orientation = .horizontal
    controls.spacing = 12
    for view in [video, controls, status] {
      view.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(view)
    }
    NSLayoutConstraint.activate([
      video.topAnchor.constraint(equalTo: content.topAnchor),
      video.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      video.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      video.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -12),
      controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
      controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
      controls.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
      status.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
      status.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
      status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
      volume.widthAnchor.constraint(equalToConstant: 80),
    ])
    session.onChange = { [weak self] snapshot in self?.update(snapshot) }
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    let args = CommandLine.arguments.dropFirst()
    if args.contains("--assume-bt709") { policy = .assumeBT709Limited }
    if let path = args.first(where: { !$0.hasPrefix("--") }) {
      load(URL(fileURLWithPath: path))
    }
  }

  @objc private func openFile() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    let assume = NSButton(
      checkboxWithTitle: "Interpret untagged SDR as Rec.709 limited", target: nil, action: nil)
    panel.accessoryView = assume
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let self, let source = panel.url else { return }
      self.policy = assume.state == .on ? .assumeBT709Limited : .requireTagged
      self.load(source)
    }
  }

  private func load(_ source: URL) {
    operation?.cancel()
    let selectedPolicy = policy
    operation = Task { [weak self] in
      guard let self else { return }
      do {
        try await session.open(source, colourPolicy: selectedPolicy)
        try Task.checkCancellation()
        window.title = "\(source.lastPathComponent) · PXLmpeg"
      } catch is CancellationError {} catch {
        status.stringValue = error.localizedDescription
      }
    }
  }

  @objc private func togglePlay() {
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
    // The session supersedes earlier seeks without clearing playback intent.
    operation = Task { [weak self] in
      guard let self else { return }
      do {
        try await session.seek(to: seconds)
        try Task.checkCancellation()
        if replay { session.play() }
      } catch is CancellationError {} catch { status.stringValue = error.localizedDescription }
    }
  }

  @objc private func changeVolume() { session.volume = volume.floatValue }
  @objc private func changeMute(_ sender: NSButton) { session.isMuted = sender.state == .on }

  private func update(_ snapshot: PlaybackSnapshot) {
    let available = snapshot.asset != nil && snapshot.state != .failed && snapshot.state != .loading
    playButton.isEnabled = available
    timeline.isEnabled = available
    playButton.title = snapshot.isPlaybackRequested ? "Pause" : "Play"
    timeline.maxValue = max(0.001, snapshot.durationSeconds)
    if !(timeline.cell?.isHighlighted ?? false) { timeline.doubleValue = snapshot.positionSeconds }
    clock.stringValue = "\(format(snapshot.positionSeconds)) / \(format(snapshot.durationSeconds))"
    status.stringValue =
      snapshot.error ?? snapshot.source.map {
        "\($0.lastPathComponent) · \(snapshot.state.rawValue)"
      } ?? "Open a video to begin"
  }

  private func format(_ seconds: Double) -> String {
    let whole = Int(max(0, seconds))
    return String(format: "%d:%02d", whole / 60, whole % 60)
  }

  private func installMenu() {
    let menu = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "Quit PXLmpeg Player", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    appItem.submenu = appMenu
    menu.addItem(appItem)
    let fileItem = NSMenuItem()
    let fileMenu = NSMenu(title: "File")
    let openItem = fileMenu.addItem(
      withTitle: "Open…", action: #selector(openFile), keyEquivalent: "o")
    openItem.target = self
    fileItem.submenu = fileMenu
    menu.addItem(fileItem)
    NSApp.mainMenu = menu
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func windowWillClose(_ notification: Notification) {
    operation?.cancel()
    session.close()
  }
  func applicationWillTerminate(_ notification: Notification) {
    operation?.cancel()
    session.close()
  }
}

let app = NSApplication.shared
let delegate = PlayerApplication()
app.delegate = delegate
app.run()
