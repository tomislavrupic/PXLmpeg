import Metal
import XCTest

@testable import PXLMetal

final class MetalContextTests: XCTestCase {
  func testBundledShaderDispatches() throws {
    let context = try MetalContext()
    let input: [UInt8] = [0, 17, 255, 39]
    let a = try XCTUnwrap(context.device.makeBuffer(bytes: input, length: input.count))
    let b = try XCTUnwrap(context.device.makeBuffer(length: input.count))
    let state = try context.device.makeComputePipelineState(
      function: XCTUnwrap(context.library.makeFunction(name: "copy_bytes")))
    let command = try XCTUnwrap(context.commandQueue.makeCommandBuffer())
    let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
    encoder.setComputePipelineState(state)
    encoder.setBuffer(a, offset: 0, index: 0)
    encoder.setBuffer(b, offset: 0, index: 1)
    encoder.dispatchThreads(
      MTLSize(width: 4, height: 1, depth: 1),
      threadsPerThreadgroup: MTLSize(width: 4, height: 1, depth: 1))
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    XCTAssertNil(command.error)
    XCTAssertEqual(
      Array(UnsafeBufferPointer(start: b.contents().assumingMemoryBound(to: UInt8.self), count: 4)),
      input)
  }
  func testMissingLibraryIsFailure() throws {
    XCTAssertThrowsError(try MetalContext.libraryURL(candidates: []))
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    XCTAssertThrowsError(
      try MetalContext.loadLibrary(
        device: device, url: URL(fileURLWithPath: "/missing/PXL.metallib")))
  }
}
