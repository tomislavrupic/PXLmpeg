import XCTest

@testable import PXLmpegCLI

final class CommandLineTests: XCTestCase {
  func testExplicitGrammarAndPaths() throws {
    XCTAssertEqual(try CLICommand.parse(["capabilities", "--json"]), .capabilities)
    XCTAssertEqual(
      try CLICommand.parse(["inspect", "my č file.mov", "--json"]), .inspect("my č file.mov"))
    XCTAssertEqual(try CLICommand.parse(["plan", "job.json", "--json"]), .plan("job.json"))
    XCTAssertEqual(try CLICommand.parse(["run", "job.json", "--json"]), .run("job.json"))
    XCTAssertEqual(try CLICommand.parse(["plan-remux", "copy.json"]), .planRemux("copy.json"))
    XCTAssertEqual(try CLICommand.parse(["remux", "copy.json", "--json"]), .remux("copy.json"))
    XCTAssertThrowsError(try CLICommand.parse(["run"]))
    XCTAssertThrowsError(try CLICommand.parse(["run", "job.json", "--overwrite"]))
    XCTAssertThrowsError(try CLICommand.parse(["delete", "file.mov"]))
  }
}
