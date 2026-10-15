import CoreMedia
import Foundation
import PXLMedia

/// Original H.264 syntax reader for the separate High 4:2:2 Intra contract.
/// Delivery H.264 admission elsewhere remains 8-bit 4:2:0.
struct XAVCFrame {
  let avcc: Data, sps: Data, pps: Data
  static func parse(_ data: Data) throws -> Self {
    guard !data.isEmpty, data.count <= ProfessionalLimits.packetBytes else { throw mxfUnsupported("Invalid XAVC picture size") }
    var starts: [(Int,Int)] = []
    data.withUnsafeBytes { raw in
      let b = raw.bindMemory(to: UInt8.self); var i = 0
      while i+2 < b.count {
        if b[i] == 0, b[i+1] == 0, b[i+2] == 1 { starts.append((i,i+3)); i += 3 }
        else if i+3 < b.count, b[i] == 0, b[i+1] == 0, b[i+2] == 0, b[i+3] == 1 {
          starts.append((i,i+4)); i += 4
        } else { i += 1 }
        if starts.count > 256 { break }
      }
    }
    guard let first = starts.first, data.prefix(first.0).allSatisfy({ $0 == 0 }), starts.count <= 256 else {
      throw mxfUnsupported("Missing/excessive Annex B NAL units")
    }
    var result = Data(), sps: Data?, pps: Data?, slices = 0, lastMB = -1
    result.reserveCapacity(data.count + starts.count * 4)
    for i in starts.indices {
      let begin = starts[i].1
      var end = i+1 < starts.count ? starts[i+1].0 : data.count
      while end > begin, data[end-1] == 0 { end -= 1 }
      guard end > begin, data[begin] & 128 == 0 else { throw mxfUnsupported("Invalid NAL header") }
      let type = data[begin] & 31
      switch type {
      case 7:
        guard sps == nil, end-begin <= 65536 else { throw mxfUnsupported("Repeated/large SPS") }; sps = data.subdata(in:begin..<end)
      case 8:
        guard pps == nil, end-begin <= 65536 else { throw mxfUnsupported("Repeated/large PPS") }; pps = data.subdata(in:begin..<end)
      case 5:
        guard sps != nil, pps != nil, data[begin] & 0x60 != 0 else { throw mxfUnsupported("IDR parameters must precede slices") }
        var bits = XAVCBits(data.subdata(in:begin..<min(end,begin+256)))
        let mb = Int(try bits.ue()), sliceType = try bits.ue(), ppsID = try bits.ue()
        guard (slices == 0 ? mb == 0 : mb > lastMB), [2,7].contains(sliceType), ppsID == 0 else {
          throw mxfUnsupported("Requires one ordered intra picture with PPS 0")
        }
        lastMB = mb; slices += 1
      case 6,9,12: break
      default: throw mxfUnsupported("Only independent IDR XAVC pictures are admitted")
      }
      let n = UInt32(end-begin)
      result.append(contentsOf: [UInt8(n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)])
      data.withUnsafeBytes { raw in
        result.append(raw.bindMemory(to:UInt8.self).baseAddress!.advanced(by:begin),count:end-begin)
      }
    }
    guard let sps, let pps, slices > 0, result.count <= ProfessionalLimits.packetBytes else { throw mxfUnsupported("Missing picture parameters/slices") }
    var p = XAVCBits(pps)
    guard try p.ue() == 0, try p.ue() == 0 else { throw mxfUnsupported("Requires PPS/SPS ID 0") }
    return Self(avcc: result, sps: sps, pps: pps)
  }
  func format(width: Int, height: Int) throws -> CMVideoFormatDescription {
    _ = try Self.validateSPS(sps, width: width, height: height)
    var format: CMVideoFormatDescription?
    let status = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
      var pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
      var sizes = [sps.count, pps.count]
      return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2,
        parameterSetPointers: &pointers, parameterSetSizes: &sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
    } }
    guard status == noErr, let format else { throw mxfUnsupported("Cannot create XAVC format (\(status))") }
    let d = CMVideoFormatDescriptionGetDimensions(format)
    guard Int(d.width) == width, Int(d.height) == height else { throw mxfUnsupported("SPS/descriptor dimensions disagree") }
    return format
  }
  struct SPSInfo { let chromaLocation: String?; let colourSpace: VideoColourSpace? }
  static func validateSPS(_ nal: Data, width: Int, height: Int) throws -> SPSInfo {
    var b = XAVCBits(nal)
    guard try b.read(8) == 122, try b.read(8) == 0x10, try b.read(8) <= 52,
      try b.ue() == 0, try b.ue() == 2, try b.ue() == 2, try b.ue() == 2 else {
      throw mxfUnsupported("Requires High 4:2:2 Intra 10-bit SPS")
    }
    guard try b.read(1) == 0 else { throw mxfUnsupported("Transform bypass unsupported") }
    if try b.read(1) == 1 {
      for i in 0..<8 where try b.read(1) == 1 {
        var last = 8, next = 8
        for _ in 0..<(i < 6 ? 16 : 64) {
          if next != 0 { let v = try b.ue(); let delta = v % 2 == 0 ? -Int(v/2) : Int((v+1)/2); next = ((last+delta)%256+256)%256 }
          if next != 0 { last = next }
        }
      }
    }
    guard try b.ue() <= 12 else { throw mxfUnsupported("Invalid frame number size") }
    let poc = try b.ue()
    if poc == 0 { guard try b.ue() <= 12 else { throw mxfUnsupported("Invalid POC size") } }
    else if poc != 2 { throw mxfUnsupported("Unsupported intra POC mode") }
    guard try b.ue() <= 1, try b.read(1) == 0 else { throw mxfUnsupported("Invalid intra reference contract") }
    let wm = Int(try b.ue())+1, hm = Int(try b.ue())+1
    guard wm <= 256, hm <= 256, try b.read(1) == 1 else { throw mxfUnsupported("Progressive dimensions required") }
    _ = try b.read(1)
    var left = 0, right = 0, top = 0, bottom = 0
    if try b.read(1) == 1 { left = Int(try b.ue()); right = Int(try b.ue()); top = Int(try b.ue()); bottom = Int(try b.ue()) }
    guard wm*16-2*(left+right) == width, hm*16-(top+bottom) == height else { throw mxfUnsupported("SPS aperture mismatch") }
    guard try b.read(1) == 1 else { throw mxfUnsupported("Explicit XAVC VUI required") }
    if try b.read(1) == 1 {
      let aspect = try b.read(8)
      if aspect == 255 {
        let h = try b.read(16), v = try b.read(16)
        guard h > 0, h == v else { throw mxfUnsupported("Non-square VUI pixels") }
      } else if aspect != 1 { throw mxfUnsupported("Non-square/unspecified VUI pixels") }
    }
    if try b.read(1) == 1 { _ = try b.read(1) }
    var declaredColour: VideoColourSpace?
    if try b.read(1) == 1 {
      _ = try b.read(3)
      guard try b.read(1) == 0 else { throw mxfUnsupported("Explicit full-range VUI needs separate validation") }
      if try b.read(1) == 1 {
        guard try b.read(8) == 1, try b.read(8) == 1, try b.read(8) == 1 else {
          throw mxfUnsupported("Non-BT.709 VUI color declaration")
        }
        declaredColour = .bt709
      }
    }
    var chroma: String?
    if try b.read(1) == 1 {
      guard try b.ue() == 0, try b.ue() == 0 else { throw mxfUnsupported("Unsupported VUI chroma location") }
      chroma = "Left"
    }
    guard try b.read(1) == 1 else { throw mxfUnsupported("Explicit picture timing required") }
    let units = try b.read(32), scale = try b.read(32)
    guard units > 0, UInt64(units)*50 == UInt64(scale), try b.read(1) == 1 else { throw mxfUnsupported("VUI/index frame rates disagree") }
    guard try b.read(1) == 0, try b.read(1) == 0, try b.read(1) == 0 else { throw mxfUnsupported("HRD/picture structure variant needs separate validation") }
    if try b.read(1) == 1 {
      _ = try b.read(1)
      for _ in 0..<4 { guard try b.ue() <= 16 else { throw mxfUnsupported("Invalid VUI restriction") } }
      guard try b.ue() == 0, try b.ue() <= 1 else { throw mxfUnsupported("Intra frame reordering unsupported") }
    }
    guard try b.read(1) == 1 else { throw mxfUnsupported("Invalid SPS trailing bits") }
    while b.position < b.bytes.count*8 { guard try b.read(1) == 0 else { throw mxfUnsupported("Unexpected SPS extension") } }
    return SPSInfo(chromaLocation:chroma,colourSpace:declaredColour)

  }
  func sample(format: CMVideoFormatDescription, index: Int) throws -> CMSampleBuffer {
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avcc.count,
      blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0,
      blockBufferOut: &block) == noErr, let block else { throw mxfUnsupported("Cannot allocate picture block") }
    let status = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
    guard status == noErr else { throw mxfUnsupported("Cannot populate picture block") }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1,timescale: 25), presentationTimeStamp: CMTime(value: Int64(index),timescale: 25), decodeTimeStamp: .invalid)
    var size = avcc.count, sample: CMSampleBuffer?
    guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
      sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
      sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { throw mxfUnsupported("Cannot create picture sample") }
    return sample
  }
}
private struct XAVCBits {
  let bytes: [UInt8]; var position = 0
  init(_ nal: Data) {
    var result: [UInt8] = [], zeros = 0
    // Only the bounded syntax prefix is needed, not a multi-megabyte slice payload.
    for byte in nal.dropFirst().prefix(65536) {
      if zeros == 2, byte == 3 { zeros = 0; continue }
      result.append(byte); zeros = byte == 0 ? zeros+1 : 0
    }
    bytes = result
  }
  mutating func read(_ n: Int) throws -> UInt32 {
    guard n <= 32, position+n <= bytes.count*8 else { throw mxfUnsupported("Truncated H.264 syntax") }
    var v: UInt32 = 0
    for _ in 0..<n { v = v << 1 | UInt32((bytes[position/8] >> (7-position%8)) & 1); position += 1 }
    return v
  }
  mutating func ue() throws -> UInt32 {
    var n = 0
    while try read(1) == 0 { n += 1; guard n <= 16 else { throw mxfUnsupported("Oversized Exp-Golomb syntax") } }
    return (1 << n)-1 + (try read(n))
  }
}
enum MXFPCM {
  static func interleave(_ planes: [Data], offset: Int, frames: Int) throws -> Data {
    guard (1...8).contains(planes.count), offset >= 0, (1...8192).contains(frames),
      planes.allSatisfy({ $0.count % 3 == 0 && offset <= $0.count/3 && frames <= $0.count/3-offset }) else {
      throw mxfUnsupported("Invalid PCM plane/chunk bounds")
    }
    var result = Data(count: frames*planes.count*4)
    result.withUnsafeMutableBytes { output in
      let dst = output.bindMemory(to: Float.self)
      for (c,plane) in planes.enumerated() {
        plane.withUnsafeBytes { raw in
          let b = raw.bindMemory(to: UInt8.self)
          for i in 0..<frames {
            let j = (offset+i)*3, code = UInt32(b[j]) | UInt32(b[j+1])<<8 | UInt32(b[j+2])<<16
            let signed = Int32(bitPattern: code << 8) >> 8
            dst[i*planes.count+c] = Float(signed)/8388608
          }
        }
      }
    }
    return result
  }
}
