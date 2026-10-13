import Foundation

public struct MediaTime: Codable, Sendable, Comparable {
  public let value: Int64
  public let timescale: Int32
  public init(value: Int64, timescale: Int32) throws {
    guard timescale > 0 else {
      throw MediaError(.invalidRequest, stage: "time", "Timescale must be positive")
    }
    self.value = value
    self.timescale = timescale
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      value: c.decode(Int64.self, forKey: .value),
      timescale: c.decode(Int32.self, forKey: .timescale))
  }
  public static func == (l: Self, r: Self) -> Bool {
    let a = l.value.multipliedFullWidth(by: Int64(r.timescale))
    let b = r.value.multipliedFullWidth(by: Int64(l.timescale))
    return a.high == b.high && a.low == b.low
  }
  public static func < (l: Self, r: Self) -> Bool {
    let a = l.value.multipliedFullWidth(by: Int64(r.timescale))
    let b = r.value.multipliedFullWidth(by: Int64(l.timescale))
    return a.high == b.high ? a.low < b.low : a.high < b.high
  }
  public var seconds: Double { Double(value) / Double(timescale) }
}
