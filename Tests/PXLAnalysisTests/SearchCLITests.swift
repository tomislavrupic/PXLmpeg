import Darwin
import Foundation
import XCTest

final class SearchCLITests: XCTestCase {
  func testHelpAndInvalidArgumentsDoNotLoadModels() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let binary = root.appendingPathComponent(".build/debug/pxl-search")
    for args in [
      ["help"], ["index", "--unknown"],
      ["query", "--models", "/missing", "--index", "/missing", "--limit", "nan", "a cat"],
    ] {
      let p = Process()
      let out = Pipe()
      let err = Pipe()
      p.executableURL = binary
      p.arguments = args
      p.standardOutput = out
      p.standardError = err
      try p.run()
      p.waitUntilExit()
      if args == ["help"] {
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertTrue(
          String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains(
            "pxl-search index"))
      } else {
        XCTAssertEqual(p.terminationStatus, 2)
      }
    }
  }
  func testNonregularSourceCannotBlockHashing() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let fifo = dir.appendingPathComponent("input.mov")
    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
    for command in ["index", "query"] {
      let p = Process()
      p.executableURL = root.appendingPathComponent(".build/debug/pxl-search")
      let models = root.appendingPathComponent(".work/semantic/models").path
      p.arguments =
        command == "index"
        ? [
          "index", "--models", models, "--output", dir.appendingPathComponent("out.json").path,
          fifo.path,
        ] : ["query", "--models", models, "--index", fifo.path, "a cat"]
      p.standardOutput = Pipe()
      p.standardError = Pipe()
      try p.run()
      let deadline = Date().addingTimeInterval(3)
      while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
      if p.isRunning {
        kill(p.processIdentifier, SIGKILL)
        XCTFail("FIFO blocked \(command)")
      }
      p.waitUntilExit()
      XCTAssertEqual(p.terminationStatus, 2)
    }
  }

}
