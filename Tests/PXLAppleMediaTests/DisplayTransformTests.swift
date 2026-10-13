import CoreGraphics
import PXLMedia
import XCTest

@testable import PXLAppleMedia

final class DisplayTransformTests: XCTestCase {
  func testQuarterTurnsAndTranslatedBounds() throws {
    for degrees in [0, 90, 180, 270] {
      let t = CGAffineTransform(rotationAngle: Double(degrees) * .pi / 180)
      XCTAssertEqual(try DisplayTransform.rotation(t, width: 320, height: 192).rawValue, degrees)
    }
    XCTAssertEqual(
      try DisplayTransform.rotation(
        CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 192, ty: 0), width: 320, height: 192),
      .clockwise90)
    XCTAssertThrowsError(
      try DisplayTransform.rotation(CGAffineTransform(scaleX: -1, y: 1), width: 320, height: 192))
    XCTAssertThrowsError(
      try DisplayTransform.rotation(
        CGAffineTransform(rotationAngle: .pi / 4), width: 320, height: 192))
    XCTAssertThrowsError(
      try DisplayTransform.rotation(
        CGAffineTransform(translationX: 123, y: 0), width: 320, height: 192))
  }
}
