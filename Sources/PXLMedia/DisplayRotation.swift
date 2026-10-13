public enum DisplayRotation: Int, Codable, Sendable {
  case none = 0
  case clockwise90 = 90
  case upsideDown = 180
  case clockwise270 = 270
  public var swapsAxes: Bool { self == .clockwise90 || self == .clockwise270 }
}
