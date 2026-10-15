import Foundation

/// ST 377-1 index rows for this admitted intra profile. Offsets are validated
/// before any UInt64 addition, indexed seek or compressed picture allocation.
enum MXFIndex {
  static func rows(_ data: Data, remaining: Int, bodyBytes: UInt64,
                   previous: MXFEditUnit?) throws -> [MXFEditUnit] {
    let values = try MXFBinary.batch(data,entrySize:15,maximum:65536)
    guard !values.isEmpty, remaining >= 0, values.count <= remaining else {
      throw mxfUnsupported("Incomplete/excess index entries")
    }
    var result: [MXFEditUnit] = [], last = previous
    result.reserveCapacity(values.count)
    for row in values {
      let offset = try MXFBinary.uint(row,3,8), slice = try MXFBinary.uint(row,11,4)
      guard row[0] == 0, row[1] == 0, row[2] == 0xc4, offset < bodyBytes,
        slice > 512, slice+49152 < bodyBytes-offset,
        last.map({ offset > $0.offset && UInt64($0.slice)+49152 < offset-$0.offset }) ?? (offset == 0) else {
        throw mxfUnsupported("Invalid/non-intra/overlapping index entry")
      }
      let unit = MXFEditUnit(offset:offset,slice:UInt32(slice))
      result.append(unit); last = unit
    }
    return result
  }
}
