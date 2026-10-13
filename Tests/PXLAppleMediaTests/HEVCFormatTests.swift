import XCTest

@testable import PXLAppleMedia

final class HEVCFormatTests: XCTestCase {
  func testMainEightBitGeometryAndSublayerBound() throws {
    let info = try HEVCFormat.streamInfo(sps: sps())
    XCTAssertEqual(info.width, 320)
    XCTAssertEqual(info.height, 192)
    XCTAssertEqual(info.maxReorderFrames, 2)
    XCTAssertEqual(try HEVCFormat.streamInfo(sps: sps(profile: 2, depth: 2)).bitDepth, 10)
    XCTAssertThrowsError(try HEVCFormat.streamInfo(sps: sps(profile: 3)))
    XCTAssertThrowsError(try HEVCFormat.streamInfo(sps: sps(depth: 2)))
    XCTAssertThrowsError(try HEVCFormat.streamInfo(sps: sps(reorder: 5)))
    XCTAssertThrowsError(try HEVCFormat.streamInfo(sps: sps(progressive: false)))
    let bytes = sps()
    for end in 0..<(bytes.count - 1) {
      XCTAssertThrowsError(try HEVCFormat.streamInfo(sps: Array(bytes.prefix(end))))
    }
  }
  func testSublayerProfileSkippingAndMonotonicPictureBounds() throws {
    XCTAssertEqual(try HEVCFormat.streamInfo(sps: sps(layers: 2)).maxReorderFrames, 2)
    XCTAssertEqual(
      try HEVCFormat.streamInfo(sps: sps(layers: 2, orders: [(2, 0), (3, 1), (4, 3)]))
        .maxReorderFrames, 3)
    XCTAssertThrowsError(
      try HEVCFormat.streamInfo(sps: sps(layers: 2, orders: [(3, 0), (2, 1), (4, 2)])))
    XCTAssertThrowsError(
      try HEVCFormat.streamInfo(sps: sps(layers: 2, orders: [(3, 1), (4, 0), (4, 2)])))
  }
  private func sps(
    profile: Int = 1, depth: Int = 0, reorder: Int = 2, progressive: Bool = true, layers: Int = 0,
    orders: [(Int, Int)]? = nil
  )
    -> [UInt8]
  {
    var bits: [Bool] = []
    func write(_ value: Int, _ count: Int) {
      for i in (0..<count).reversed() { bits.append(value >> i & 1 != 0) }
    }
    func ue(_ value: Int) {
      let n = value + 1
      let width = Int.bitWidth - n.leadingZeroBitCount
      write(0, width - 1)
      write(n, width)
    }
    write(0, 4)
    write(layers, 3)
    write(1, 1)
    write(0, 2)
    write(0, 1)
    write(profile, 5)
    write(0, 32)
    write(progressive ? 1 : 0, 1)
    write(progressive ? 0 : 1, 1)
    write(0, 1)
    write(1, 1)
    write(0, 32)
    write(0, 12)
    write(120, 8)
    for i in 0..<layers {
      write(i % 2 == 0 ? 1 : 0, 1)
      write(i % 2 == 1 ? 1 : 0, 1)
    }
    if layers > 0 { for _ in layers..<8 { write(0, 2) } }
    for i in 0..<layers {
      if i % 2 == 0 {
        write(0, 32)
        write(0, 32)
        write(0, 24)
      }
      if i % 2 == 1 { write(120, 8) }
    }
    ue(0)
    ue(1)
    ue(320)
    ue(192)
    write(0, 1)
    ue(depth)
    ue(depth)
    ue(4)
    write(orders == nil ? 0 : 1, 1)
    for (buffer, count) in orders ?? [(4, reorder)] {
      ue(buffer - 1)
      ue(count)
      ue(0)
    }
    write(1, 1)
    var bytes = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
    for (i, bit) in bits.enumerated() { if bit { bytes[i / 8] |= 1 << (7 - i % 8) } }
    // SPS NAL, layer 0, temporal_id_plus1 1; escape payload just as an encoder does.
    var escaped: [UInt8] = [0x42, 1]
    var zeros = 0
    for byte in bytes {
      if zeros == 2 && byte <= 3 {
        escaped.append(3)
        zeros = 0
      }
      escaped.append(byte)
      zeros = byte == 0 ? zeros + 1 : 0
    }
    return escaped
  }
}
