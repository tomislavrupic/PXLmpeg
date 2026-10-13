import CoreMedia
import Foundation
import XCTest

@testable import PXLAppleMedia

final class H264StreamTests: XCTestCase {
  func testExplicitAndInferredReorderBounds() throws {
    let info = try H264Format.streamInfo(sps: sps(reorder: 2, buffering: 3))
    XCTAssertEqual(info.maxReorderFrames, 2)
    XCTAssertEqual(info.width, 160)
    XCTAssertEqual(info.height, 96)
    XCTAssertEqual(try H264Format.streamInfo(sps: sps(reorder: nil)).maxReorderFrames, 16)
    XCTAssertEqual(
      try H264Format.streamInfo(sps: sps(reorder: 0, buffering: 3)).maxReorderFrames, 0)
  }
  func testMalformedUnsupportedAndInconsistentBounds() throws {
    XCTAssertThrowsError(try H264Format.streamInfo(sps: sps(reorder: 4, buffering: 3)))
    XCTAssertThrowsError(try H264Format.streamInfo(sps: sps(reorder: 17, buffering: 17)))
    XCTAssertThrowsError(try H264Format.streamInfo(sps: sps(reorder: 2, progressive: false)))
    let valid = sps(reorder: 2)
    for end in 0..<(valid.count - 1) {
      XCTAssertThrowsError(try H264Format.streamInfo(sps: Array(valid.prefix(end))))
    }
  }
  func testNegotiatedCreditsAreBounded() throws {
    let budget = MediaBudget(limit: 1024, frameLimit: 2)
    var leases = [
      try budget.reserve(bytes: 100, kind: .frame), try budget.reserve(bytes: 100, kind: .frame),
    ]
    XCTAssertThrowsError(try budget.reserve(bytes: 100, kind: .frame))
    leases.removeAll()
    XCTAssertEqual(budget.current, 0)
    XCTAssertEqual(budget.frameCount, 0)
  }
  private func sps(reorder: Int?, buffering: Int = 3, progressive: Bool = true) -> [UInt8] {
    var b = BitWriter()
    b.write(100, 8)
    b.write(0, 8)
    b.write(40, 8)
    b.ue(0)
    b.ue(1)
    b.ue(0)
    b.ue(0)
    b.bit(false)
    b.bit(false)
    b.ue(0)
    b.ue(0)
    b.ue(0)
    b.ue(3)
    b.bit(false)
    b.ue(9)
    b.ue(5)
    b.bit(progressive)
    if !progressive { b.bit(false) }
    b.bit(true)
    b.bit(false)
    b.bit(true)
    b.bit(false)
    b.bit(false)
    b.bit(false)
    b.bit(false)
    b.bit(false)
    b.bit(false)
    b.bit(false)
    b.bit(false)
    b.bit(reorder != nil)
    if let reorder {
      b.bit(true)
      b.ue(0)
      b.ue(0)
      b.ue(0)
      b.ue(0)
      b.ue(reorder)
      b.ue(buffering)
    }
    b.bit(true)
    return [0x67] + b.bytes
  }
}
private struct BitWriter {
  var bits: [Bool] = []
  mutating func bit(_ value: Bool) { bits.append(value) }
  mutating func write(_ value: Int, _ count: Int) {
    for i in (0..<count).reversed() { bit((value >> i) & 1 != 0) }
  }
  mutating func ue(_ value: Int) {
    let n = value + 1
    let width = Int.bitWidth - n.leadingZeroBitCount
    for _ in 0..<(width - 1) { bit(false) }
    write(n, width)
  }
  var bytes: [UInt8] {
    stride(from: 0, to: bits.count, by: 8).map { start in
      (0..<8).reduce(UInt8(0)) { ($0 << 1) | (start + $1 < bits.count && bits[start + $1] ? 1 : 0) }
    }
  }
}
