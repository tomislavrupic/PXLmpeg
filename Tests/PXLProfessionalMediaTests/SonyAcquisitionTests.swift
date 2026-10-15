import Foundation
import Darwin
import XCTest
@testable import PXLProfessionalMedia

final class SonyAcquisitionTests: XCTestCase {
  private let cameraKey: [UInt8] = [0x06,0x0e,0x2b,0x34,0x02,0x53,0x01,0x01,0x0c,0x02,0x01,0x01,0x02,0x01,0,0]
  private let ancKey: [UInt8] = [0x06,0x0e,0x2b,0x34,0x01,0x02,0x01,0x01,0x0d,0x01,0x03,0x01,0x17,0x01,0x02,0x01]
  private let gamma: [UInt8] = [0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x06,0x0e,0x06,0x04,0x01,0x01,0x01,0x06,0x05]
  private func klv(_ key: [UInt8], _ value: [UInt8]) -> [UInt8] {
    key + [0x83, UInt8((value.count >> 16) & 255), UInt8((value.count >> 8) & 255), UInt8(value.count & 255)] + value
  }
  private func packet(_ bytes: [UInt8], sequence: UInt8 = 1) -> [UInt8] {
    let count = bytes.count + 4
    // ST436: line, wrapping/coding, sample count, array count/item size, DID/SDID/DC/PSC.
    return [0,11,4,4,0,UInt8(count),0,0,0,UInt8(count),0,0,0,1,0x43,5,UInt8(bytes.count+1),sequence] + bytes
  }
  private func withFile(_ bytes: [UInt8], _ body: (URL) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mxf")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(bytes).write(to: url)
    try body(url)
  }
  func testEmbeddedCineGammaSelectsDefinedGamutWithoutXML() throws {
    let record = klv(cameraKey, [0x32,0x10,0,16] + gamma)
    try withFile(klv(ancKey, [0,1] + packet(record))) { url in
      let value = try XCTUnwrap(SonyMXFAcquisition.inspect(url))
      XCTAssertEqual(value.gamma, "s-log3-cine")
      XCTAssertEqual(value.gamut, "s-gamut3-cine")
      XCTAssertTrue(value.gamutFromGammaLabel)
      XCTAssertLessThan(value.bytesRead, 1024)
      let contract = try XCTUnwrap(CameraMetadataInspector.inspect(url))
      XCTAssertEqual(contract.labelNamespace, "Sony")
      XCTAssertNil(contract.cameraManufacturer)
      XCTAssertEqual(contract.captureGamma, "s-log3-cine")
      XCTAssertEqual(contract.evidence.first?.rawValue, "060e2b34040101060e06040101010605")
      XCTAssertEqual(contract.evidence.first?.source, url)
      XCTAssertNotNil(contract.evidence.last?.derivation)
      XCTAssertTrue(try contract.matchesSource(url))
      try Data([0]).write(to: url)
      XCTAssertFalse(try contract.matchesSource(url))
    }
  }
  func testCapturedLookAndExposureRemainSeparateFacts() throws {
    let record = klv(cameraKey, [0x32,0x10,0,16] + gamma + [0x81,0x15,0,2,3,32,0x81,0x0b,0,2,7,208])
    var privateKey = cameraKey; privateKey[12] = 0x7f
    let look = Array("SonyProf2:LC-709typA".utf8)
    let owner: [UInt8] = [0x96,0x69,0x08,0,0x46,0x78,3,0x1c,0x20,0x50,0,3,0xf0,0xc0,0x11,0x81]
    let privateSet = klv(privateKey, [0xe0,0,0,16] + owner + [0xe1,9,0,UInt8(look.count)] + look)
    try withFile(klv(ancKey, [0,1] + packet(record + privateSet))) { url in
      let value = try XCTUnwrap(SonyMXFAcquisition.inspect(url))
      XCTAssertEqual(value.monitoringLookName, "SonyProf2:LC-709typA")
      XCTAssertEqual(value.exposureIndex, 800)
      XCTAssertEqual(value.isoSensitivity, 2000)
      XCTAssertEqual(value.gamma, "s-log3-cine")
    }
  }
  func testLuminanceRangePreservesExplicitLegalAndUnknownValues() throws {
    for code: UInt8 in [0, 2, 6, 7, 255] {
      let record = klv(cameraKey, [0x32,0x10,0,16] + gamma + [0x81,0x20,0,1,code])
      try withFile(klv(ancKey, [0,1] + packet(record))) { url in
        let value = try XCTUnwrap(CameraMetadataInspector.inspect(url))
        XCTAssertEqual(value.luminanceCodeRange, Int(code))
        XCTAssertEqual(value.evidence.last?.field, "LuminanceCodeRange")
        XCTAssertEqual(value.evidence.last?.rawValue, String(code))
      }
    }
  }
  func testFragmentedCameraSetReassemblesOnlyInSequence() throws {
    let record = klv(cameraKey, [0x32,0x10,0,16] + gamma)
    let first = Array(record.prefix(27)), second = Array(record.dropFirst(27))
    try withFile(klv(ancKey, [0,2] + packet(first) + packet(second, sequence: 2))) { url in
      XCTAssertEqual(try SonyMXFAcquisition.inspect(url)?.gamut, "s-gamut3-cine")
    }
    try withFile(klv(ancKey, [0,2] + packet(first) + packet(second, sequence: 3))) { url in
      XCTAssertNil(try SonyMXFAcquisition.inspect(url))
    }
  }
  func testWrongCarrierUnknownGammaAndTruncationDoNotGuess() throws {
    let record = klv(cameraKey, [0x32,0x10,0,16] + gamma)
    var wrong = ancKey; wrong[12] = 0x15
    try withFile(klv(wrong, [0,1] + packet(record))) { XCTAssertNil(try SonyMXFAcquisition.inspect($0)) }
    var unknown = gamma; unknown[15] = 0xff
    try withFile(klv(ancKey, [0,1] + packet(klv(cameraKey, [0x32,0x10,0,16] + unknown)))) { XCTAssertNil(try SonyMXFAcquisition.inspect($0)) }
    let valid = klv(ancKey, [0,1] + packet(record))
    for length in 0..<valid.count {
      try withFile(Array(valid.prefix(length))) { XCTAssertNil(try SonyMXFAcquisition.inspect($0)) }
    }
  }
  func testRejectsNonRegularSourceBeforeOpening() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mxf")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: url) }
    XCTAssertThrowsError(try SonyMXFAcquisition.inspect(url))
  }
  func testRejectsFIFOWithoutBlocking() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mxf")
    XCTAssertEqual(mkfifo(url.path, 0o600), 0)
    defer { try? FileManager.default.removeItem(at: url) }
    XCTAssertThrowsError(try SonyMXFAcquisition.inspect(url))
  }
  func testSkipsLargePicturePayloadWithoutReadingIt() throws {
    var picture = ancKey; picture[12] = 0x15
    let prefix = klv(picture, Array(repeating: 0, count: 2 * 1024 * 1024))
    let record = klv(cameraKey, [0x32,0x10,0,16] + gamma)
    try withFile(prefix + klv(ancKey, [0,1] + packet(record))) { url in
      let value = try XCTUnwrap(SonyMXFAcquisition.inspect(url))
      XCTAssertGreaterThan(value.packetOffset, 2 * 1024 * 1024)
      XCTAssertLessThan(value.bytesRead, 1024)
    }
  }
}
