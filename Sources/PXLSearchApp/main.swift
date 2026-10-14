import AppKit
import Foundation
import PXLAnalysis
import PXLSearchUI

struct LaunchOptions {
  var compute: SemanticComputePolicy = .cpuAndNeuralEngine
  var models: URL?
  var index: URL?
  var query: String?
  var sources: [URL] = []
  var assumeBT709 = false
  init(_ arguments: [String]) throws {
    var i = 0
    var seen = Set<String>()
    while i < arguments.count {
      let argument = arguments[i]
      if argument == "--assume-bt709" {
        guard seen.insert(argument).inserted else { throw CocoaError(.validationMultipleErrors) }
        assumeBT709 = true
      } else if ["--models", "--index", "--query", "--compute"].contains(argument) {
        guard seen.insert(argument).inserted, i + 1 < arguments.count else {
          throw CocoaError(.validationMultipleErrors)
        }
        i += 1
        guard !arguments[i].hasPrefix("--") else { throw CocoaError(.validationMultipleErrors) }
        switch argument {
        case "--models": models = URL(fileURLWithPath: arguments[i])
        case "--index": index = URL(fileURLWithPath: arguments[i])
        case "--compute":
          guard let policy = SemanticComputePolicy(rawValue: arguments[i]), policy != .all else {
            throw CocoaError(.validationMultipleErrors)
          }
          compute = policy
        default: query = arguments[i]
        }
      } else if argument.hasPrefix("--") {
        throw CocoaError(.validationMultipleErrors)
      } else {
        sources.append(URL(fileURLWithPath: argument))
      }
      i += 1
    }
    guard sources.count <= 32, index == nil || sources.isEmpty, query == nil || index != nil else {
      throw CocoaError(.validationMultipleErrors)
    }
    if models == nil {
      let path =
        ProcessInfo.processInfo.environment["PXL_SEMANTIC_MODELS"]
        ?? UserDefaults.standard.string(forKey: "modelDirectory")
        ?? Bundle.main.object(forInfoDictionaryKey: "PXLDefaultModelDirectory") as? String
      if let path {
        models = URL(fileURLWithPath: path)
      } else {
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
          .appendingPathComponent(".work/semantic/models")
        if FileManager.default.fileExists(
          atPath: local.appendingPathComponent("manifest.json").path)
        {
          models = local
        }
      }
    }
  }
}

@MainActor final class SearchApplication: NSObject, NSApplicationDelegate {
  let options: LaunchOptions
  var controller: SearchWindowController?
  init(options: LaunchOptions) { self.options = options }
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    let workspace = SearchWorkspace(models: options.models, computePolicy: options.compute)
    let ui = SearchWindowController(workspace: workspace)
    controller = ui
    installMenu(ui)
    ui.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    if let index = options.index {
      workspace.openIndex(index)
      if let query = options.query { ui.setQuery(query) }
    } else if !options.sources.isEmpty {
      workspace.chooseSources(
        options.sources, colourPolicy: options.assumeBT709 ? .assumeBT709Limited : .requireTagged)
    }
  }
  private func installMenu(_ ui: SearchWindowController) {
    let menu = NSMenu()
    let app = NSMenuItem()
    app.submenu = NSMenu()
    app.submenu?.addItem(
      withTitle: "About PXLmpeg Search", action: #selector(showAbout), keyEquivalent: "")
    app.submenu?.addItem(.separator())
    app.submenu?.addItem(
      withTitle: "Quit PXLmpeg Search", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    menu.addItem(app)
    let file = NSMenuItem()
    let fileMenu = NSMenu(title: "File")
    for (title, action, key) in [
      ("Add Footage…", #selector(SearchWindowController.addFootage), "o"),
      ("Replace Footage…", #selector(SearchWindowController.replaceFootage), ""),
      ("Open Index…", #selector(SearchWindowController.openIndex), "O"),
      ("Save Index As…", #selector(SearchWindowController.saveIndex), "s"),
    ] {
      let item = fileMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
      item.target = ui
    }
    file.submenu = fileMenu
    menu.addItem(file)
    let edit = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    edit.submenu = editMenu
    menu.addItem(edit)
    NSApp.mainMenu = menu
  }
  @objc private func showAbout() {
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: "PXLmpeg Search",
      .applicationVersion: "0.8 · Early research",
      .credits: NSAttributedString(
        string:
          "Native footage search for Apple Silicon.\nSwift · Core ML · Metal\n\nExperimental research build by Pixel Records."
      ),
    ])
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationWillTerminate(_ notification: Notification) { controller?.workspace.close() }
}

let args = Array(CommandLine.arguments.dropFirst())
if args == ["--help"] {
  print(
    """
    PXLmpeg Search · native research app
    pxl-search-app [--models DIR] [--compute cpuOnly|cpuAndNeuralEngine] [--assume-bt709] SOURCE.mov ...
    pxl-search-app [--models DIR] --index INDEX.json [--query "a guitar beside a plant"]
    --query prefills the field; press Search to start inference.
    Model assets remain external; use Scripts/fetch-semantic-model.py first.
    """)
} else {
  do {
    let options = try LaunchOptions(args)
    let app = NSApplication.shared
    let delegate = SearchApplication(options: options)
    app.delegate = delegate
    app.run()
  } catch {
    FileHandle.standardError.write(
      Data("Invalid launch arguments. Use pxl-search-app --help.\n".utf8))
    exit(2)
  }
}
