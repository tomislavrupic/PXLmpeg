import Foundation
import PXLMedia
import XCTest

@testable import PXLAppleMedia

final class DolbyVisionTests: XCTestCase {
  func testSupportedBaseLayerAndRPUSignallingRequireConsistentColour() throws {
    var bytes = [UInt8](repeating: 0, count: 24)
    bytes[0] = 1
    bytes[2] = 16
    bytes[3] = 0x35
    bytes[4] = 0x40
    XCTAssertTrue(try DolbyVisionConfiguration.validate(Data(bytes), colourSpace: .hlg2020))
    XCTAssertThrowsError(try DolbyVisionConfiguration.validate(Data(bytes), colourSpace: .pq2020))
    XCTAssertThrowsError(
      try DolbyVisionConfiguration.validate(Data(bytes.prefix(5)), colourSpace: .hlg2020))
    bytes[3] &= ~4
    XCTAssertFalse(try DolbyVisionConfiguration.validate(Data(bytes), colourSpace: .hlg2020))
    bytes[3] |= 2
    XCTAssertThrowsError(try DolbyVisionConfiguration.validate(Data(bytes), colourSpace: .hlg2020))
    bytes[3] = 5
    bytes[4] = 0x10
    XCTAssertTrue(try DolbyVisionConfiguration.validate(Data(bytes), colourSpace: .pq2020))
    bytes[2] = 10
    XCTAssertThrowsError(try DolbyVisionConfiguration.validate(Data(bytes), colourSpace: .pq2020))
  }
}
