import Darwin
import Foundation
import PXLMedia
import PXLTestSupport
import XCTest

final class ProcessTests: XCTestCase {
  func testSIGINTAndBrokenPipeCleanNativeJob() throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appendingPathComponent("in.mov")
    try FixtureFactory.make(at: source, width: 1920, height: 1080, frames: 240)
    let binary = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(".build/debug/pxlmpeg")
    for brokenPipe in [false, true] {
      let target = dir.appendingPathComponent("out.mov")
      let request = try JobRequest(source: source, destination: target, videoBitrate: 4_000_000)
      let path = dir.appendingPathComponent("job č.json")
      try request.normalizedData().write(to: path)
      let process = Process()
      let output = Pipe()
      let errors = Pipe()
      process.executableURL = binary
      process.arguments = ["run", path.path]
      process.standardOutput = output
      process.standardError = errors
      try process.run()
      // Read a complete event before signalling so native processing is active.
      var first = Data()
      while first.last != 10 {
        let byte = try output.fileHandleForReading.read(upToCount: 1) ?? Data()
        guard !byte.isEmpty else {
          XCTFail("CLI ended before progress")
          return
        }
        first.append(byte)
      }
      if brokenPipe {
        try output.fileHandleForReading.close()
      } else {
        XCTAssertEqual(kill(process.processIdentifier, SIGINT), 0)
      }
      let deadline = Date().addingTimeInterval(10)
      while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        XCTFail("CLI did not cancel")
      }
      process.waitUntilExit()
      XCTAssertEqual(process.terminationStatus, 130)
      if !brokenPipe {
        first.append(output.fileHandleForReading.readDataToEndOfFile())
        let events = try String(decoding: first, as: UTF8.self).split(separator: "\n").map {
          try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        XCTAssertEqual(events.last?["type"] as? String, "cancelled")
        XCTAssertEqual(events.filter { $0["type"] as? String == "cancelled" }.count, 1)
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
      XCTAssertFalse(
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
          .contains { $0.hasPrefix(".pxlmpeg-") })
    }
  }
}
