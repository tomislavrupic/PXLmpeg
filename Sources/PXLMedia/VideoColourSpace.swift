public enum VideoColourSpace: String, Codable, Sendable {
  case bt709, hlg2020, pq2020
  public var isHDR: Bool { self != .bt709 }
}
