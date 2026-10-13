import Foundation
import PXLMedia

enum CLICommand: Equatable {
  case capabilities
  case inspect(String)
  case plan(String)
  case run(String)
  case planRemux(String)
  case remux(String)
  case help
  static func parse(_ arguments: [String]) throws -> Self {
    if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] { return .help }
    var args = arguments
    if args.last == "--json" { args.removeLast() }
    if args == ["capabilities"] { return .capabilities }
    guard args.count == 2, !args[1].hasPrefix("--") else { throw invalid() }
    switch args[0] {
    case "inspect": return .inspect(args[1])
    case "plan": return .plan(args[1])
    case "run": return .run(args[1])
    case "plan-remux": return .planRemux(args[1])
    case "remux": return .remux(args[1])
    default: throw invalid()
    }
  }
  private static func invalid() -> MediaError {
    MediaError(
      .invalidRequest, stage: "cli",
      "Use capabilities, inspect FILE, plan JOB.json, run JOB.json, plan-remux COPY.json, or remux COPY.json; optional --json"
    )
  }
}
