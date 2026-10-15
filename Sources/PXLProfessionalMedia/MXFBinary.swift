import Foundation
import PXLMedia

func mxfUnsupported(_ message: String) -> MediaError {
  MediaError(.unsupportedMedia, stage: "mxf-read", message)
}
// ST 377-1 BER and two-byte local-set lengths. No unbounded allocation from input.
enum MXFBinary {
  static func ber(_ b: [UInt8]) throws -> (length: Int, bytes: Int) {
    guard let first = b.first else { throw mxfUnsupported("Missing BER length") }
    if first < 128 { return (Int(first), 1) }
    let n = Int(first & 127)
    guard (1...8).contains(n), b.count >= n + 1 else { throw mxfUnsupported("Invalid BER length") }
    var value: UInt64 = 0
    for byte in b[1...n] { value = value << 8 | UInt64(byte) }
    guard value <= UInt64(Int.max) else { throw mxfUnsupported("BER length overflow") }
    return (Int(value), n + 1)
  }
  static func uint(_ b: Data, _ offset: Int = 0, _ count: Int? = nil) throws -> UInt64 {
    let n = count ?? b.count
    guard (1...8).contains(n), offset >= 0, offset <= b.count, n <= b.count-offset else {
      throw mxfUnsupported("Truncated integer")
    }
    return b[offset..<offset+n].reduce(0) { $0 << 8 | UInt64($1) }
  }
  static func fields(_ b: Data) throws -> [UInt16: Data] {
    var fields: [UInt16: Data] = [:], i = 0
    while i < b.count {
      let tag = UInt16(try uint(b, i, 2)), n = Int(try uint(b, i+2, 2)); i += 4
      guard n <= b.count-i, fields[tag] == nil else { throw mxfUnsupported("Truncated/duplicate local property") }
      fields[tag] = b.subdata(in: i..<i+n); i += n
    }
    return fields
  }
  static func batch(_ b: Data, entrySize: Int, maximum: Int) throws -> [Data] {
    let count = Int(try uint(b, 0, 4)), stride = Int(try uint(b, 4, 4))
    guard count <= maximum, stride == entrySize, b.count == 8 + count * stride else {
      throw mxfUnsupported("Invalid batch dimensions")
    }
    return (0..<count).map { b.subdata(in: 8+$0*stride..<8+($0+1)*stride) }
  }
  static func hex(_ s: String) -> Data {
    let b = Array(s.utf8)
    return Data(stride(from: 0, to: b.count, by: 2).map {
      UInt8(String(bytes: b[$0..<$0+2], encoding: .utf8)!, radix: 16)!
    })
  }
}
struct MXFKLV {
  let key: Data, value: UInt64, length: Int
  var end: UInt64 { value + UInt64(length) }
}
/// Confined to the source-opening call or session queue; never shared concurrently.
final class MXFFile {
  let handle: FileHandle, url: URL, identity: ProfessionalSourceIdentity
  var size: UInt64 { identity.size }
  init(_ url: URL) throws {
    guard url.isFileURL else { throw mxfUnsupported("Local MXF required") }
    identity = try ProfessionalSourceIdentity.read(url); self.url = url
    handle = try FileHandle(forReadingFrom: url)
    try checkIdentity()
  }
  func checkIdentity() throws {
    guard try ProfessionalSourceIdentity.read(url) == identity else {
      throw MediaError(.sourceChanged, stage: "mxf-read", "Source identity/size/mtime changed")
    }
    // Also verify the opened file, not only the current path (replacement race).
    var info = stat()
    guard fstat(handle.fileDescriptor, &info) == 0,
      UInt64(info.st_ino) == identity.inode, UInt64(info.st_dev) == identity.device,
      info.st_size >= 0, UInt64(info.st_size) == identity.size else {
      throw MediaError(.sourceChanged, stage: "mxf-read", "Opened source identity changed")
    }
  }
  func read(_ offset: UInt64, _ count: Int, maximum: Int) throws -> Data {
    guard count >= 0, count <= maximum, offset <= size, UInt64(count) <= size-offset else {
      throw mxfUnsupported("Read exceeds bounded source region")
    }
    try handle.seek(toOffset: offset)
    guard let data = try handle.read(upToCount: count), data.count == count else {
      throw MediaError(.ioFailure, stage: "mxf-read", "Truncated file read")
    }
    return data
  }
  func klv(_ offset: UInt64, end: UInt64) throws -> MXFKLV {
    guard end <= size, offset <= end, end-offset >= 17 else { throw mxfUnsupported("Truncated KLV") }
    let head = try read(offset, Int(min(25,end-offset)), maximum: 25)
    let length = try MXFBinary.ber(Array(head.dropFirst(16)))
    let value = offset + 16 + UInt64(length.bytes)
    guard value <= end, UInt64(length.length) <= end-value else { throw mxfUnsupported("KLV exceeds region") }
    return MXFKLV(key: head.prefix(16), value: value, length: length.length)
  }
  deinit { try? handle.close() }
}
