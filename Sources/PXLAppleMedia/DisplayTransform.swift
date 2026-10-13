import CoreGraphics
import PXLMedia

package enum DisplayTransform {
  package static func rotation(_ t: CGAffineTransform, width: Int, height: Int) throws
    -> DisplayRotation
  {
    let epsilon = 0.00001
    let values = [t.a, t.b, t.c, t.d, t.tx, t.ty]
    guard values.allSatisfy({ $0.isFinite }) else { throw invalid() }
    let candidates: [(DisplayRotation, [Double], Double, Double)] = [
      (.none, [1, 0, 0, 1], 0, 0), (.clockwise90, [0, 1, -1, 0], Double(height), 0),
      (.upsideDown, [-1, 0, 0, -1], Double(width), Double(height)),
      (.clockwise270, [0, -1, 1, 0], 0, Double(width)),
    ]
    for (rotation, linear, x, y) in candidates {
      if zip([t.a, t.b, t.c, t.d], linear).allSatisfy({ abs($0 - $1) <= epsilon }),
        (abs(t.tx) <= epsilon && abs(t.ty) <= epsilon)
          || (abs(t.tx - x) <= epsilon && abs(t.ty - y) <= epsilon)
      {
        return rotation
      }
    }
    throw invalid()
  }
  private static func invalid() -> MediaError {
    MediaError(
      .unsupportedMedia, stage: "inspect",
      "Only proper 0/90/180/270 degree display transforms are supported")
  }
}
