import CoreMedia
import Foundation
import PXLMedia

// Read only the SPS prefix needed to prove the decoded surface contract. This is
// not a decoder. Container field/chroma/colour metadata is validated separately.
package enum H264Format {
  package static func validateDepthAndSubsampling(_ format: CMVideoFormatDescription) throws {
    var pointer: UnsafePointer<UInt8>?
    var size = 0
    guard
      CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        format, parameterSetIndex: 0,
        parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
      let pointer, size > 4, size <= 65536
    else { throw invalid() }
    try validateSPS(Array(UnsafeBufferPointer(start: pointer, count: size)))
  }
  package static func validateSPS(_ nal: [UInt8]) throws {
    guard nal.count >= 4, nal[0] & 0x1f == 7 else { throw invalid() }
    var bytes: [UInt8] = []
    var zeros = 0
    for byte in nal.dropFirst() {
      if zeros == 2 && byte == 3 {
        zeros = 0
        continue
      }
      bytes.append(byte)
      zeros = byte == 0 ? zeros + 1 : 0
    }
    var bits = Bits(bytes: bytes)
    let profile = try bits.read(8)
    _ = try bits.read(8)  // constraint flags
    _ = try bits.read(8)  // level
    guard try bits.ue() <= 31 else { throw invalid() }
    switch profile {
    case 66, 77, 88: break  // These profiles imply 8-bit 4:2:0.
    case 100:
      guard try bits.ue() == 1, try bits.ue() == 0, try bits.ue() == 0 else { throw invalid() }
    default: throw invalid()
    }
  }
  package struct StreamInfo: Equatable {
    package let width: Int, height: Int, maxReorderFrames: Int
    package let bitDepth: Int
    package init(width: Int, height: Int, maxReorderFrames: Int, bitDepth: Int = 8) {
      self.width = width
      self.height = height
      self.maxReorderFrames = maxReorderFrames
      self.bitDepth = bitDepth
    }
  }
  package static func streamInfo(format: CMVideoFormatDescription) throws -> StreamInfo {
    var count = 0
    guard
      CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        format, parameterSetIndex: 0,
        parameterSetPointerOut: nil, parameterSetSizeOut: nil,
        parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr,
      (1...64).contains(count)
    else { throw invalid() }
    var infos: [StreamInfo] = []
    for index in 0..<count {
      var pointer: UnsafePointer<UInt8>?
      var size = 0
      guard
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
          format, parameterSetIndex: index,
          parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
          parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
        let pointer, (1...65536).contains(size)
      else { throw invalid() }
      if pointer[0] & 31 == 7 {
        infos.append(try streamInfo(sps: Array(UnsafeBufferPointer(start: pointer, count: size))))
      }
    }
    guard let first = infos.first,
      infos.allSatisfy({ $0.width == first.width && $0.height == first.height })
    else { throw invalid() }
    return StreamInfo(
      width: first.width, height: first.height,
      maxReorderFrames: infos.map(\.maxReorderFrames).max()!)
  }
  // ITU-T H.264 7.3.2.1.1, E.1.1/E.2.1, Annex A. Original syntax reader,
  // bounded before loops/arithmetic; no entropy decoding or third-party source.
  package static func streamInfo(sps: [UInt8]) throws -> StreamInfo {
    try validateSPS(sps)
    var bytes: [UInt8] = []
    var zeros = 0
    for byte in sps.dropFirst() {
      if zeros == 2 && byte == 3 {
        zeros = 0
        continue
      }
      bytes.append(byte)
      zeros = byte == 0 ? zeros + 1 : 0
    }
    var b = Bits(bytes: bytes)
    let profile = try b.read(8)
    let constraints = try b.read(8)
    let level = try b.read(8)
    guard constraints & 3 == 0 else { throw invalid() }
    _ = try b.ue()
    if profile == 100 {
      _ = try b.ue()
      _ = try b.ue()
      _ = try b.ue()
      _ = try b.read(1)
      if try b.flag() {
        for i in 0..<8 {
          if try b.flag() {
            var last = 8
            var next = 8
            for _ in 0..<(i < 6 ? 16 : 64) {
              if next != 0 {
                next = (last + (try b.se()) + 256) % 256
                if next < 0 { next += 256 }
              }
              last = next == 0 ? last : next
            }
          }
        }
      }
    }
    guard try b.ue() <= 12 else { throw invalid() }
    switch try b.ue() {
    case 0: guard try b.ue() <= 12 else { throw invalid() }
    case 1:
      _ = try b.read(1)
      _ = try b.se()
      _ = try b.se()
      let cycle = try b.ue()
      guard cycle <= 255 else { throw invalid() }
      for _ in 0..<cycle { _ = try b.se() }
    case 2: break
    default: throw invalid()
    }
    let refs = Int(try b.ue())
    guard refs <= 16 else { throw invalid() }
    _ = try b.read(1)
    let wm = Int(try b.ue()) + 1
    let hm = Int(try b.ue()) + 1
    guard wm <= 256, hm <= 256, try b.flag() else { throw invalid() }
    _ = try b.read(1)  // direct_8x8_inference_flag
    var left = 0
    var right = 0
    var top = 0
    var bottom = 0
    if try b.flag() {
      left = Int(try b.ue())
      right = Int(try b.ue())
      top = Int(try b.ue())
      bottom = Int(try b.ue())
    }
    let width = wm * 16 - 2 * (left + right)
    let height = hm * 16 - 2 * (top + bottom)
    guard (16...4096).contains(width), (16...4096).contains(height) else { throw invalid() }
    let dpbMbs: Int
    switch level {
    case 9, 10: dpbMbs = 396
    case 11: dpbMbs = constraints & 16 != 0 && profile != 100 ? 396 : 900
    case 12, 13, 20: dpbMbs = 2376
    case 21: dpbMbs = 4752
    case 22, 30: dpbMbs = 8100
    case 31: dpbMbs = 18000
    case 32: dpbMbs = 20480
    case 40, 41: dpbMbs = 32768
    case 42: dpbMbs = 34816
    case 50: dpbMbs = 110400
    case 51, 52: dpbMbs = 184320
    case 60, 61, 62: dpbMbs = 696320
    default: throw invalid()
    }
    let maximum = min(16, dpbMbs / (wm * hm))
    guard maximum > 0, refs <= maximum else { throw invalid() }
    var reorder = profile == 66 || (profile == 100 && constraints & 16 != 0) ? 0 : maximum
    if try b.flag() {  // vui_parameters_present_flag
      if try b.flag() {
        if try b.read(8) == 255 {
          _ = try b.read(16)
          _ = try b.read(16)
        }
      }
      if try b.flag() { _ = try b.read(1) }
      if try b.flag() {
        _ = try b.read(3)
        _ = try b.read(1)
        if try b.flag() { _ = try b.read(24) }
      }
      if try b.flag() { guard try b.ue() <= 5, try b.ue() <= 5 else { throw invalid() } }
      if try b.flag() {
        _ = try b.read(32)
        _ = try b.read(32)
        _ = try b.read(1)
      }
      let nalHRD = try b.flag()
      if nalHRD { try b.hrd() }
      let vclHRD = try b.flag()
      if vclHRD { try b.hrd() }
      if nalHRD || vclHRD { _ = try b.read(1) }
      _ = try b.read(1)  // pic_struct_present_flag
      if try b.flag() {
        _ = try b.read(1)
        guard try b.ue() <= 16, try b.ue() <= 16, try b.ue() <= 16, try b.ue() <= 16 else {
          throw invalid()
        }
        reorder = Int(try b.ue())
        let buffering = Int(try b.ue())
        guard reorder <= buffering, buffering <= maximum, refs <= buffering,
          profile != 66 || reorder == 0
        else { throw invalid() }
      }
    }
    guard try b.flag() else { throw invalid() }  // rbsp_stop_one_bit
    while b.position < bytes.count * 8 { guard try b.read(1) == 0 else { throw invalid() } }
    return StreamInfo(width: width, height: height, maxReorderFrames: reorder)
  }
  private static func invalid() -> MediaError {
    MediaError(.unsupportedMedia, stage: "inspect", "SPS must prove supported 8-bit 4:2:0 H.264")
  }
  private struct Bits {
    let bytes: [UInt8]
    var position = 0
    mutating func read(_ count: Int) throws -> UInt32 {
      guard count <= 32, position + count <= bytes.count * 8 else { throw invalid() }
      var value: UInt32 = 0
      for _ in 0..<count {
        value = (value << 1) | UInt32((bytes[position / 8] >> (7 - position % 8)) & 1)
        position += 1
      }
      return value
    }
    mutating func flag() throws -> Bool { try read(1) == 1 }
    mutating func se() throws -> Int {
      let v = Int(try ue())
      return v % 2 == 0 ? -(v / 2) : (v + 1) / 2
    }
    mutating func hrd() throws {
      let count = try ue()
      guard count <= 31 else { throw invalid() }
      _ = try read(8)
      for _ in 0...count {
        _ = try ue()
        _ = try ue()
        _ = try read(1)
      }
      _ = try read(20)
    }
    mutating func ue() throws -> UInt32 {
      var zeros = 0
      while try read(1) == 0 {
        zeros += 1
        if zeros > 16 { throw invalid() }
      }
      return (UInt32(1) << zeros) - 1 + (try read(zeros))
    }
  }
}
