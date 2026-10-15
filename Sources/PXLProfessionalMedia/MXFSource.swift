import CoreMedia
import Foundation
import PXLMedia
import PXLAppleMedia

struct MXFEditUnit: Sendable {
  let offset: UInt64
  let slice: UInt32
}
/// Deliberately narrow ST 377-1 / ST 381-3 frame-wrapped XAVC Intra OP-1a reader.
/// Header/index reads are capped at 16 MiB; packet reads at 32 MiB. No essence scan.
final class MXFSource: @unchecked Sendable {
  private let storageHold: Reservation?
  let file: MXFFile
  let descriptor: ProfessionalAssetDescriptor
  let entries: [MXFEditUnit]
  let body: UInt64, footer: UInt64
  let format: CMVideoFormatDescription, sps: Data, pps: Data
  var storageBytes: Int { entries.count * MemoryLayout<MXFEditUnit>.stride + 196608 }
  private static let filler = MXFBinary.hex("060e2b34010101020301021001000000")
  private static let indexKey = MXFBinary.hex("060e2b34025301010d01020101100100")
  private static let essencePrefix = MXFBinary.hex("060e2b34010201010d010301")
  private static let propertyULs: [UInt16: String] = [
    0x3210: "060e2b34010101020401020101010200",
    0x3001: "060e2b34010101010406010100000000",
    0x3002: "060e2b34010101010406010200000000",
    0x3004: "060e2b34010101020601010401020000",
    0x3006: "060e2b34010101050601010305000000",
    0x3201: "060e2b34010101020401060100000000",
    0x3202: "060e2b34010101010401050201000000",
    0x3203: "060e2b34010101010401050202000000",
    0x3204: "060e2b34010101010401050107000000",
    0x3205: "060e2b34010101010401050108000000",
    0x3206: "060e2b34010101010401050109000000",
    0x3207: "060e2b3401010101040105010a000000",
    0x3208: "060e2b3401010101040105010b000000",
    0x3209: "060e2b3401010101040105010c000000",
    0x320a: "060e2b3401010101040105010d000000",
    0x320b: "060e2b3401010101040105010e000000",
    0x320c: "060e2b34010101010401030104000000",
    0x320e: "060e2b34010101010401010101000000",
    0x3301: "060e2b3401010102040105030a000000",
    0x3302: "060e2b34010101010401050105000000",
    0x3308: "060e2b34010101020401050110000000",
    0x3d03: "060e2b34010101050402030101010000",
    0x3d07: "060e2b34010101050402010104000000",
    0x3d01: "060e2b34010101040402030304000000",
    0x3d06: "060e2b34010101020402040200000000",
    0x3d0a: "060e2b34010101050402030201000000",
    0x4801: "060e2b34010101020107010100000000",
    0x4804: "060e2b34010101020104010300000000",
    0x4803: "060e2b34010101020601010402040000",
    0x4403: "060e2b34010101020601010406050000",
    0x4701: "060e2b34010101020601010402030000",
    0x3c0a: "060e2b34010101010101150200000000",
    0x3f01: "060e2b340101010406010104060b0000",
    0x4b01: "060e2b34010101020530040500000000",
    0x4b02: "060e2b34010101020702010301030000",
  ]
  init(_ url: URL, budget: MediaBudget? = nil) throws {
    let admissionBudget = budget ?? MediaBudget(limit:128*1024*1024,frameLimit:1)
    let metadataHold = try admissionBudget.reserve(bytes:16*1024*1024,kind:.bytes)
    defer { metadataHold.release() }
    file = try MXFFile(url)
    let pack = try file.klv(0, end: file.size)
    guard pack.key == MXFBinary.hex("060e2b34020501010d01020101020400"), (88...4096).contains(pack.length) else {
      throw mxfUnsupported("Requires closed complete OP-1a header at byte zero")
    }
    let p = try file.read(pack.value,pack.length,maximum:4096)
    let kag = try MXFBinary.uint(p,4,4), headerBytes = try MXFBinary.uint(p,32,8), indexBytes = try MXFBinary.uint(p,40,8)
    guard kag > 0, kag <= 65536, headerBytes <= 8*1024*1024, indexBytes > 0, indexBytes <= 8*1024*1024,
      try MXFBinary.uint(p,8,8) == 0, try MXFBinary.uint(p,16,8) == 0,
      try MXFBinary.uint(p,48,4) == 1, try MXFBinary.uint(p,52,8) == 0,
      try MXFBinary.uint(p,60,4) == 2,
      p.subdata(in:64..<80) == MXFBinary.hex("060e2b34040101010d01020101010900") else {
      throw mxfUnsupported("Unsupported partition/index/body layout")
    }
    footer = try MXFBinary.uint(p,24,8)
    let metadataStart = (pack.end+kag-1)/kag*kag
    let indexStart = metadataStart+headerBytes
    body = indexStart+indexBytes
    guard body < footer, footer < file.size else { throw mxfUnsupported("Invalid partition bounds") }
    let endPack = try file.klv(footer,end:file.size)
    guard endPack.key == MXFBinary.hex("060e2b34020501010d01020101040400"), endPack.length == pack.length else {
      throw mxfUnsupported("Closed complete footer required")
    }
    let fp = try file.read(endPack.value,endPack.length,maximum:4096)
    guard try MXFBinary.uint(fp,8,8) == footer, try MXFBinary.uint(fp,16,8) == 0,
      try MXFBinary.uint(fp,24,8) == footer, try MXFBinary.uint(fp,32,8) == 0,
      try MXFBinary.uint(fp,40,8) == 0, try MXFBinary.uint(fp,60,4) == 0 else {
      throw mxfUnsupported("Multiple/incomplete body partitions unsupported")
    }
    // RIP corroborates that this is a single contiguous body stream.
    let ripSize = Int(try MXFBinary.uint(file.read(file.size-4,4,maximum:4)))
    guard ripSize == 48 else { throw mxfUnsupported("Single-body RIP required") }
    let rip = try file.klv(file.size-48,end:file.size)
    let rb = try file.read(rip.value,rip.length,maximum:48)
    guard rip.key == MXFBinary.hex("060e2b34020501010d01020101110100"), rb.count == 28,
      try MXFBinary.uint(rb,0,4) == 2, try MXFBinary.uint(rb,4,8) == 0,
      try MXFBinary.uint(rb,12,4) == 0, try MXFBinary.uint(rb,16,8) == footer else {
      throw mxfUnsupported("RIP/partition disagreement")
    }
    var cursor = metadataStart, primer: [UInt16: UInt16] = [:]
    var sets: [(UInt8,[UInt16:Data])] = []
    let byUL = Dictionary(uniqueKeysWithValues: Self.propertyULs.map { (MXFBinary.hex($0.value),$0.key) })
    while cursor < indexStart {
      let k = try file.klv(cursor,end:indexStart); cursor = k.end
      if k.key == Self.filler { continue }
      guard k.length <= 1024*1024 else { throw mxfUnsupported("Oversized metadata set") }
      let bytes = try file.read(k.value,k.length,maximum:1024*1024)
      if k.key == MXFBinary.hex("060e2b34020501010d01020101050100") {
        guard primer.isEmpty else { throw mxfUnsupported("Duplicate primer") }
        var seen = Set<UInt16>(), seenUL = Set<Data>()
        for item in try MXFBinary.batch(bytes,entrySize:18,maximum:4096) {
          let tag = UInt16(try MXFBinary.uint(item,0,2)), ul = item.subdata(in:2..<18)
          guard seen.insert(tag).inserted, seenUL.insert(ul).inserted else { throw mxfUnsupported("Duplicate primer mapping") }
          if let canonical = byUL[ul] { primer[tag] = canonical }
        }
      } else {
        guard !primer.isEmpty, k.key.prefix(8) == MXFBinary.hex("060e2b3402530101") else { throw mxfUnsupported("Unexpected header metadata encoding") }
        let raw = try MXFBinary.fields(bytes)
        var mapped: [UInt16:Data] = [:]
        for (tag,value) in raw { if let key = primer[tag] { mapped[key] = value } }
        if k.key.prefix(14) == MXFBinary.hex("060e2b34025301010d0101010101") { sets.append((k.key[14],mapped)) }
        guard sets.count <= 4096 else { throw mxfUnsupported("Too many metadata sets") }
      }
    }
    func field(_ set: [UInt16:Data], _ tag: UInt16, _ size: Int? = nil) throws -> Data {
      guard let value = set[tag], size.map({ value.count == $0 }) ?? true else { throw mxfUnsupported("Missing/invalid property \(String(tag,radix:16))") }
      return value
    }
    func number(_ set: [UInt16:Data], _ tag: UInt16, _ size: Int) throws -> UInt64 { try MXFBinary.uint(field(set,tag,size)) }
    let videos = sets.filter { $0.0 == 0x28 }, audios = sets.filter { $0.0 == 0x47 }
    guard videos.count == 1, audios.count == 8 else { throw mxfUnsupported("Requires one CDCI picture and eight mono PCM descriptors") }
    let v = videos[0].1
    let width = Int(try number(v,0x3203,4)), height = Int(try number(v,0x3202,4))
    guard (16...4096).contains(width), (16...4096).contains(height), width%2 == 0, height%2 == 0,
      try field(v,0x3001,8) == MXFBinary.hex("0000001900000001"),
      try field(v,0x3201,16) == MXFBinary.hex("060e2b340401010a0401020201323001"),
      try field(v,0x3004,16) == MXFBinary.hex("060e2b340401010a0d01030102106001"),
      try number(v,0x320c,1) == 0, try number(v,0x3301,4) == 10,
      try number(v,0x3302,4) == 2, try number(v,0x3308,4) == 1,
      try field(v,0x3210,16) == MXFBinary.hex("060e2b34040101010401010101020000"),
      try number(v,0x3006,4) == 2 else { throw mxfUnsupported("Requires progressive 25p XAVC High 4:2:2 Intra 10-bit") }
    for (tag,expected) in [(UInt16(0x3204),height),(0x3205,width),(0x3208,height),(0x3209,width),(0x3206,0),(0x3207,0),(0x320a,0),(0x320b,0)] {
      guard try number(v,tag,4) == expected else { throw mxfUnsupported("Cropped/offset aperture unsupported") }
    }
    let aspect = try field(v,0x320e,8)
    guard try MXFBinary.uint(aspect,0,4) > 0, try MXFBinary.uint(aspect,4,4) > 0,
      try MXFBinary.uint(aspect,0,4) * UInt64(height) == MXFBinary.uint(aspect,4,4) * UInt64(width) else { throw mxfUnsupported("Square pixels required") }
    let count = try number(v,0x3002,8)
    guard count > 0, count <= 500000 else { throw mxfUnsupported("Duration exceeds bounded index") }
    // Resolve the source package, its descriptor list and track references, rather
    // than accidentally accepting material-package tracks with the same track IDs.
    let packages = sets.filter { $0.0 == 0x37 }, multiples = sets.filter { $0.0 == 0x44 }
    guard packages.count == 1, multiples.count == 1,
      try field(packages[0].1,0x4701,16) == field(multiples[0].1,0x3c0a,16) else { throw mxfUnsupported("Ambiguous source package") }
    let descriptorRefs = try MXFBinary.batch(field(multiples[0].1,0x3f01),entrySize:16,maximum:16)
    guard descriptorRefs.count == 10, Set(descriptorRefs).count == 10,
      try descriptorRefs.contains(field(v,0x3c0a,16)) else { throw mxfUnsupported("Source descriptor graph mismatch") }
    let trackRefs = try MXFBinary.batch(field(packages[0].1,0x4403),entrySize:16,maximum:16)
    guard trackRefs.count == 11, Set(trackRefs).count == 11 else { throw mxfUnsupported("Unsupported source track graph") }
    let allTracks = sets.filter { $0.0 == 0x3b }
    var trackNumbers: [UInt64:UInt64] = [:]
    for ref in trackRefs {
      let matches = allTracks.filter { $0.1[0x3c0a] == ref }
      guard matches.count == 1 else { throw mxfUnsupported("Missing/duplicate source track") }
      let track = matches[0].1
      guard try field(track,0x4b01,8) == MXFBinary.hex("0000001900000001"), try number(track,0x4b02,8) == 0 else { throw mxfUnsupported("Track edit rate/origin unsupported") }
      let id = try number(track,0x4801,4), tn = try number(track,0x4804,4)
      guard trackNumbers.updateValue(tn,forKey:id) == nil else { throw mxfUnsupported("Duplicate source track ID") }
    }
    guard trackNumbers[1] == 0, trackNumbers[2] == 0x15010500, trackNumbers[11] == 0x17010201 else { throw mxfUnsupported("Unsupported picture/system/ANC track identity") }
    var audioIDs = Set<UInt64>()
    for (_,a) in audios {
      let id = try number(a,0x3006,4)
      guard (3...10).contains(id), audioIDs.insert(id).inserted, trackNumbers[id] == 0x16080300 + id-3,
        try descriptorRefs.contains(field(a,0x3c0a,16)),
        try field(a,0x3d03,8) == MXFBinary.hex("0000bb8000000001"), try number(a,0x3d07,4) == 1,
        try number(a,0x3d01,4) == 24, try number(a,0x3d0a,2) == 3,
        try field(a,0x3d06,16) == MXFBinary.hex("060e2b340401010a0402020101000000"),
        try field(a,0x3004,16) == MXFBinary.hex("060e2b34040101010d01030102060300") else { throw mxfUnsupported("Requires eight mapped signed PCM24LE 48 kHz tracks") }
    }
    storageHold = try admissionBudget.reserve(bytes:Int(count)*MemoryLayout<MXFEditUnit>.stride+196608,kind:.bytes)
    var index: [MXFEditUnit] = []; index.reserveCapacity(Int(count)); cursor = indexStart
    while cursor < body {
      let k = try file.klv(cursor,end:body); cursor = k.end
      if k.key == Self.filler { continue }
      guard k.key == Self.indexKey, k.length <= 1024*1024 else { throw mxfUnsupported("Unexpected/large index set") }
      let fields = try MXFBinary.fields(file.read(k.value,k.length,maximum:1024*1024))
      guard try field(fields,0x3f0b,8) == MXFBinary.hex("0000001900000001"),
        try number(fields,0x3f0c,8) == index.count,
        try number(fields,0x3f05,4) == 0, try number(fields,0x3f06,4) == 1,
        try number(fields,0x3f07,4) == 2, try number(fields,0x3f08,1) == 1 else { throw mxfUnsupported("Unsupported VBE index layout") }
      let deltas = try MXFBinary.batch(field(fields,0x3f09),entrySize:6,maximum:16)
      guard deltas.count == 11 else { throw mxfUnsupported("Unexpected index element count") }
      for (i,d) in deltas.enumerated() {
        let slice: UInt8 = i < 2 ? 0 : 1
        let delta = i == 0 ? 0 : i == 1 ? 512 : (i-2)*6144
        guard d[0] == 0, d[1] == slice, try MXFBinary.uint(d,2,4) == delta else { throw mxfUnsupported("Unsupported index element mapping") }
      }
      let rows = try MXFIndex.rows(field(fields,0x3f0a),remaining:Int(count)-index.count,
                                   bodyBytes:footer-body,previous:index.last)
      guard try number(fields,0x3f0d,8) == rows.count else { throw mxfUnsupported("Index segment duration mismatch") }
      index.append(contentsOf:rows)
    }
    guard index.count == Int(count) else { throw mxfUnsupported("Index does not cover picture duration") }
    entries = index
    let packetHold = try admissionBudget.reserve(bytes:ProfessionalLimits.packetBytes*2+1024*1024,kind:.bytes)
    defer { packetHold.release() }
    let first = try Self.picture(file:file,entries:index,body:body,footer:footer,index:0)
    sps = first.sps; pps = first.pps; format = try first.format(width:width,height:height)
    let spsInfo = try XAVCFrame.validateSPS(first.sps,width:width,height:height)
    let duration = try MediaTime(value:Int64(count),timescale:25)
    // Generic coded BT.709 declaration is separate from RDD18 capture gamma/gamut.
    // The camera metadata inspector preserves those facts for monitoring transforms.
    descriptor = ProfessionalAssetDescriptor(width:width,height:height,codec:"XAVC Intra",bitDepth:10,chromaSubsampling:"4:2:2",
      colourSpace:spsInfo.colourSpace,sourceChromaLocation:spsInfo.chromaLocation,rotation:.none,videoStart:try MediaTime(value:0,timescale:25),videoDuration:duration,
      audioSampleRate:48000,audioChannels:8,audioBitDepth:24,audioStart:try MediaTime(value:0,timescale:48000),audioDuration:duration,
      audioChannelLayout:nil,timecodeTracks:1)
    try file.checkIdentity()
  }
  private static func picture(file: MXFFile, entries: [MXFEditUnit], body: UInt64, footer: UInt64, index: Int) throws -> XAVCFrame {
    let row = entries[index], unit = body+row.offset, end = index+1 < entries.count ? body+entries[index+1].offset : footer
    let k = try file.klv(unit+512,end:unit+UInt64(row.slice))
    guard k.key == essencePrefix+MXFBinary.hex("15010500"), k.end <= end, k.length <= ProfessionalLimits.packetBytes else { throw mxfUnsupported("Indexed picture key/size mismatch") }
    return try XAVCFrame.parse(file.read(k.value,k.length,maximum:ProfessionalLimits.packetBytes))
  }
  func picture(_ index: Int) throws -> XAVCFrame {
    let frame = try Self.picture(file:file,entries:entries,body:body,footer:footer,index:index)
    guard frame.sps == sps, frame.pps == pps else { throw mxfUnsupported("Changing picture parameter sets unsupported") }
    return frame
  }
  func audioPlanes(_ index: Int) throws -> [Data] {
    let row = entries[index], begin = body+row.offset+UInt64(row.slice)
    let end = index+1 < entries.count ? body+entries[index+1].offset : footer
    return try (0..<8).map { channel in
      let offset = begin+UInt64(channel*6144), k = try file.klv(offset,end:min(end,offset+6144))
      guard k.key == Self.essencePrefix+Data([0x16,8,3,UInt8(channel)]), k.length == 1920*3 else { throw mxfUnsupported("Indexed PCM key/cadence mismatch") }
      return try file.read(k.value,k.length,maximum:5760)
    }
  }
}
