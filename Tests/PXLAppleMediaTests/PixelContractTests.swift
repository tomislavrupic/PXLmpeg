import CoreMedia
import CoreVideo
import PXLMedia
import XCTest

@testable import PXLAppleMedia

final class PixelContractTests: XCTestCase {
  func testReusedSurfaceClearsAbsentMetadataAndCopiesOnlyWhitelistedAttachments() throws {
    let budget = MediaBudget(limit: 67_108_864)
    let a = try PixelBufferPool(width: 32, height: 32, budget: budget, bitDepth: 10)
    let b = try PixelBufferPool(width: 32, height: 32, budget: budget, bitDepth: 10)
    let input = try a.acquire(pts: .zero, duration: CMTime(value: 1, timescale: 24))
    let output = try b.acquire(pts: .zero, duration: input.duration)
    let metadata = [
      kCVImageBufferAmbientViewingEnvironmentKey as String: Data(repeating: 7, count: 8)
    ]
    PixelContract(bitDepth: 10, colourSpace: .hlg2020, staticMetadata: metadata).apply(
      to: input.pixel)
    CVBufferSetAttachment(
      input.pixel, "PXLTestDynamicMetadata" as CFString, "old RPU" as CFString, .shouldPropagate)
    PixelContract.propagate(from: input.pixel, to: output.pixel)
    XCTAssertEqual(
      CVBufferCopyAttachment(output.pixel, kCVImageBufferAmbientViewingEnvironmentKey, nil)
        as? Data, metadata.values.first)
    XCTAssertNil(CVBufferCopyAttachment(output.pixel, "PXLTestDynamicMetadata" as CFString, nil))
    PixelContract(bitDepth: 10, colourSpace: .bt709).apply(to: input.pixel)
    PixelContract.propagate(from: input.pixel, to: output.pixel)
    for (key, _) in PixelContract.metadataKeys {
      XCTAssertNil(CVBufferCopyAttachment(output.pixel, key, nil))
    }
    XCTAssertEqual(
      CVBufferCopyAttachment(output.pixel, kCVImageBufferTransferFunctionKey, nil) as? String,
      kCVImageBufferTransferFunction_ITU_R_709_2 as String)
    XCTAssertGreaterThan(
      PixelContract.storageBytes(width: 3840, height: 2160, bitDepth: 10),
      PixelContract.storageBytes(width: 3840, height: 2160, bitDepth: 8))
  }
}
