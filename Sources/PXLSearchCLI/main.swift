import Darwin
import Foundation
import PXLAnalysis
import PXLMedia

@main enum SearchCommand {
  static func main() async {
    signal(SIGINT, SIG_IGN)
    signal(SIGPIPE, SIG_IGN)
    let work = Task { () -> Int32 in
      do {
        try await run(Array(CommandLine.arguments.dropFirst()))
        return 0
      } catch is CancellationError { return 130 } catch {
        let message = ["error": error.localizedDescription]
        if let data = try? JSONEncoder().encode(message) {
          try? FileHandle.standardError.write(contentsOf: data + Data([10]))
        }
        if let m = error as? MediaError,
          [.invalidRequest, .unsupportedMedia, .destinationExists, .engineBusy].contains(m.code)
        {
          return 2
        }
        return 3
      }
    }
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler { work.cancel() }
    interrupt.resume()
    let result = await work.value
    interrupt.cancel()
    exit(result)
  }
  private static func emit<T: Encodable>(_ value: T) throws {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    try FileHandle.standardOutput.write(contentsOf: e.encode(value) + Data([10]))
  }
  private static func run(_ args: [String]) async throws {
    guard let command = args.first else { throw invalid("Use pxl-search help") }
    if command == "help" || command == "--help" {
      print(
        """
        PXLmpeg semantic search research prototype
        pxl-search index --models DIR --output NEW.json [--interval 1] [--max-samples 256] [--assume-bt709] SOURCE.mov ...
        pxl-search query --models DIR --index INDEX.json [--limit 10] "a person beside a car"
        pxl-search plan --models DIR [--variant s2] [--compute cpuAndNeuralEngine]
        pxl-search profile --models DIR [--variant s2] [--compute cpuAndNeuralEngine] [--repetitions 100] [--assume-bt709] SOURCE.mov
        All commands accept --variant s0|s2 and --compute cpuOnly|cpuAndNeuralEngine|all.
        Assets are explicitly fetched with Scripts/fetch-semantic-model.py; no runtime download.
        Results are sampled visual candidates, not verified captions/actions. Source files remain read-only.
        """)
      return
    }
    let specific: [String: Set<String>] = [
      "index": ["--output", "--interval", "--max-samples", "--assume-bt709"],
      "query": ["--index", "--limit"], "plan": [],
      "profile": ["--repetitions", "--assume-bt709", "--attach-delay"],
    ]
    guard let allowed = specific[command] else { throw invalid("Unknown command") }
    var options: [String: String] = [:]
    var positionals: [String] = []
    var i = 1
    var parsing = true
    while i < args.count {
      let arg = args[i]
      if arg == "--" && parsing {
        parsing = false
        i += 1
        continue
      }
      if arg.hasPrefix("--") && parsing {
        guard allowed.contains(arg) || ["--models", "--variant", "--compute"].contains(arg),
          options[arg] == nil
        else {
          throw invalid("Unknown or repeated option \(arg)")
        }
        if arg == "--assume-bt709" {
          options[arg] = "true"
        } else {
          i += 1
          guard i < args.count, !args[i].hasPrefix("--") else {
            throw invalid("Missing value for \(arg)")
          }
          options[arg] = args[i]
        }
      } else {
        positionals.append(arg)
      }
      i += 1
    }
    guard let path = options["--models"],
      let compute = SemanticComputePolicy(rawValue: options["--compute"] ?? "cpuAndNeuralEngine")
    else {
      throw invalid("Local --models directory and valid --compute are required")
    }
    func integer(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
      guard let n = Int(options[key] ?? String(fallback)), range.contains(n) else {
        throw invalid("Invalid \(key)")
      }
      return n
    }
    let variant = options["--variant"] ?? "s2"
    let models = URL(fileURLWithPath: path)
    let policy: InputColourPolicy =
      options["--assume-bt709"] == nil ? .requireTagged : .assumeBT709Limited
    switch command {
    case "index":
      guard !positionals.isEmpty, let output = options["--output"],
        let interval = Double(options["--interval"] ?? "1")
      else { throw invalid("Index needs sources, --output and valid --interval") }
      let destination = URL(fileURLWithPath: output)
      guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw MediaError(.destinationExists, stage: "semantic", "Destination exists")
      }
      let sampling = try SamplingOptions(
        intervalSeconds: interval,
        maximumSamplesPerSource: integer("--max-samples", default: 256, range: 1...4096))
      let analyzer = try SemanticAnalyzer(models: models, variant: variant, computePolicy: compute)
      let index = try await analyzer.index(
        sources: positionals.map { URL(fileURLWithPath: $0) }, options: sampling,
        colourPolicy: policy)
      try Task.checkCancellation()
      try index.write(to: destination)
      struct Receipt: Encodable {
        let output: URL
        let sources: Int
        let frames: Int
        let modelID: String
        let elapsedMilliseconds: Double
      }
      try emit(
        Receipt(
          output: destination, sources: index.sources.count, frames: index.frames.count,
          modelID: index.modelID, elapsedMilliseconds: index.elapsedMilliseconds))
    case "query":
      guard !positionals.isEmpty, let path = options["--index"] else {
        throw invalid("Query needs --index and text")
      }
      let limit = try integer("--limit", default: 10, range: 1...100)
      let index = try SemanticIndex.read(from: URL(fileURLWithPath: path))
      let analyzer = try SemanticAnalyzer(models: models, variant: variant, computePolicy: compute)
      try emit(await analyzer.query(positionals.joined(separator: " "), index: index, limit: limit))
    case "plan":
      guard positionals.isEmpty else { throw invalid("Plan has no positional arguments") }
      let analyzer = try SemanticAnalyzer(models: models, variant: variant, computePolicy: compute)
      try emit(await analyzer.computePlan())
    case "profile":
      guard positionals.count == 1 else { throw invalid("Profile needs one local source") }
      let repeats = try integer("--repetitions", default: 100, range: 1...1000)
      let analyzer = try SemanticAnalyzer(models: models, variant: variant, computePolicy: compute)
      let plan = try await analyzer.computePlan()
      let attachDelay = try integer("--attach-delay", default: 0, range: 0...30)
      if attachDelay > 0 {
        _ = try await analyzer.benchmark(
          source: URL(fileURLWithPath: positionals[0]), repetitions: 1, colourPolicy: policy)
        try FileHandle.standardError.write(contentsOf: Data("{\"profileReady\":true}\n".utf8))
        try await Task.sleep(for: .seconds(attachDelay))
      }
      let benchmark = try await analyzer.benchmark(
        source: URL(fileURLWithPath: positionals[0]), repetitions: repeats, colourPolicy: policy)
      struct Report: Encodable {
        let plan: ModelComputeReport
        let benchmark: SemanticBenchmark
        let prewarmedForTrace: Bool
      }
      try emit(Report(plan: plan, benchmark: benchmark, prewarmedForTrace: attachDelay > 0))
    default: throw invalid("Unknown command")
    }
  }
  private static func invalid(_ message: String) -> MediaError {
    MediaError(.invalidRequest, stage: "semantic-cli", message)
  }
}
