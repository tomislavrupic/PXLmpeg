import CoreMedia
import Foundation
import PXLMedia

// Original bounded HEVC SPS prefix reader. H.265 7.3.2.2.1 / 7.3.3:
// only Main/Main10 progressive 4:2:0 is admitted; no third-party codec source.
package enum HEVCFormat {
  package static func streamInfo(format: CMVideoFormatDescription) throws -> H264Format.StreamInfo {
    var count = 0
    guard
      CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
        format, parameterSetIndex: 0,
        parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count,
        nalUnitHeaderLengthOut: nil) == noErr, (1...64).contains(count)
    else { throw invalid() }
    var infos: [H264Format.StreamInfo] = []
    for i in 0..<count {
      var pointer: UnsafePointer<UInt8>?
      var size = 0
      guard
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
          format, parameterSetIndex: i,
          parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
          parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
        let pointer, (2...65536).contains(size)
      else { throw invalid() }
      if (pointer[0] >> 1) & 63 == 33 {
        infos.append(try streamInfo(sps: Array(UnsafeBufferPointer(start: pointer, count: size))))
      }
    }
    guard let first = infos.first,
      infos.allSatisfy({
        $0.width == first.width && $0.height == first.height && $0.bitDepth == first.bitDepth
      })
    else { throw invalid() }
    return H264Format.StreamInfo(
      width: first.width, height: first.height,
      maxReorderFrames: infos.map(\.maxReorderFrames).max()!, bitDepth: first.bitDepth)
  }
  package static func streamInfo(sps: [UInt8]) throws -> H264Format.StreamInfo {
    guard (3...65536).contains(sps.count), sps[0] == 0x42, sps[1] == 1 else { throw invalid() }
    var bytes: [UInt8] = []
    var zeros = 0
    for byte in sps.dropFirst(2) {
      if zeros == 2 && byte == 3 {
        zeros = 0
        continue
      }
      bytes.append(byte)
      zeros = byte == 0 ? zeros + 1 : 0
    }
    var b = Bits(bytes: bytes)
    _ = try b.read(4)
    let layers = Int(try b.read(3))
    guard layers <= 6 else { throw invalid() }
    _ = try b.read(1)
    guard try b.read(2) == 0 else { throw invalid() }  // general_profile_space
    _ = try b.read(1)
    let generalProfile = try b.read(5)
    guard generalProfile == 1 || generalProfile == 2 else { throw invalid() }
    _ = try b.read(32)  // profile compatibility
    let progressive = try b.read(1)
    let interlaced = try b.read(1)
    _ = try b.read(1)
    let frameOnly = try b.read(1)
    guard progressive == 1, interlaced == 0, frameOnly == 1 else { throw invalid() }
    _ = try b.read(32)
    _ = try b.read(12)
    _ = try b.read(8)
    var profile: [Bool] = []
    var level: [Bool] = []
    for _ in 0..<layers {
      profile.append(try b.read(1) == 1)
      level.append(try b.read(1) == 1)
    }
    if layers > 0 { for _ in layers..<8 { guard try b.read(2) == 0 else { throw invalid() } } }
    for i in 0..<layers {
      if profile[i] {
        _ = try b.read(32)
        _ = try b.read(32)
        _ = try b.read(24)
      }
      if level[i] { _ = try b.read(8) }
    }
    guard try b.ue() <= 15, try b.ue() == 1 else { throw invalid() }
    let codedWidth = Int(try b.ue())
    let codedHeight = Int(try b.ue())
    guard (16...4096).contains(codedWidth), (16...4096).contains(codedHeight) else {
      throw invalid()
    }
    var left = 0
    var right = 0
    var top = 0
    var bottom = 0
    if try b.read(1) == 1 {
      left = Int(try b.ue())
      right = Int(try b.ue())
      top = Int(try b.ue())
      bottom = Int(try b.ue())
    }
    let width = codedWidth - 2 * (left + right)
    let height = codedHeight - 2 * (top + bottom)
    let lumaDepth = try b.ue()
    let chromaDepth = try b.ue()
    guard (16...4096).contains(width), (16...4096).contains(height), width % 2 == 0,
      height % 2 == 0, lumaDepth == chromaDepth,
      (generalProfile == 1 && lumaDepth == 0)
        || (generalProfile == 2 && (lumaDepth == 0 || lumaDepth == 2)),
      try b.ue() <= 12
    else { throw invalid() }
    let allLayers = try b.read(1) == 1
    var maximum = 0
    var previousBuffer = 0
    var previousReorder = 0
    for _ in (allLayers ? 0 : layers)...layers {
      let buffer = Int(try b.ue()) + 1
      let reorder = Int(try b.ue())
      _ = try b.ue()  // max_latency_increase_plus1
      guard buffer <= 16, reorder < buffer, buffer >= previousBuffer,
        reorder >= previousReorder
      else { throw invalid() }
      previousBuffer = buffer
      previousReorder = reorder
      maximum = max(maximum, reorder)
    }
    return H264Format.StreamInfo(
      width: width, height: height, maxReorderFrames: maximum, bitDepth: Int(lumaDepth) + 8)
  }
  private static func invalid() -> MediaError {
    MediaError(
      .unsupportedMedia, stage: "inspect",
      "HEVC SPS must prove Main/Main10 progressive 4:2:0 and bounded picture ordering")
  }
  private struct Bits {
    let bytes: [UInt8]
    var position = 0
    mutating func read(_ n: Int) throws -> UInt32 {
      guard (0...32).contains(n), position + n <= bytes.count * 8 else { throw invalid() }
      var value: UInt32 = 0
      for _ in 0..<n {
        value = (value << 1) | UInt32((bytes[position / 8] >> (7 - position % 8)) & 1)
        position += 1
      }
      return value
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
