import CoreMedia
import XCTest

@testable import PXLAppleMedia

final class PresentationBufferTests: XCTestCase {
  func testEncodedSampleUsesTrackOutputTimeRatherThanMediaTime() throws {
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 24),
      presentationTimeStamp: CMTime(value: 2, timescale: 24), decodeTimeStamp: .zero)
    var sample: CMSampleBuffer?
    XCTAssertEqual(
      CMSampleBufferCreate(
        allocator: nil, dataBuffer: nil, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: nil, sampleCount: 1,
        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
        sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
    let buffer = try XCTUnwrap(sample)
    XCTAssertEqual(CMSampleBufferSetOutputPresentationTimeStamp(buffer, newValue: .zero), noErr)
    let packet = EncodedSample(buffer: buffer, sequence: 0)
    XCTAssertEqual(packet.pts, .zero)
  }
  func testBoundedPermutationAndEOFDrain() throws {
    let queue = try PresentationBuffer<Int>(reorderDepth: 2)
    var output: [Int] = []
    for value in [0, 3, 1, 2, 6, 4, 5, 7] {
      try queue.insert(value, pts: CMTime(value: Int64(value), timescale: 24))
      XCTAssertLessThanOrEqual(queue.count, 3)
      if let ready = try queue.pop() { output.append(ready) }
    }
    while let ready = try queue.pop(atEOF: true) { output.append(ready) }
    XCTAssertEqual(output, Array(0..<8))
    XCTAssertEqual(queue.count, 0)
  }
  func testThousandSeededBoundedPermutations() throws {
    var seed: UInt64 = 0x50_584C_6D70_6567
    func next(_ limit: Int) -> Int {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int(seed >> 32) % limit
    }
    for _ in 0..<1000 {
      let depth = next(17)
      let queue = try PresentationBuffer<Int>(reorderDepth: depth)
      var input = Array(0..<64)
      var output: [Int] = []
      for start in stride(from: 0, to: input.count, by: depth + 1) {
        let end = min(start + depth + 1, input.count)
        for i in start..<end { input.swapAt(i, start + next(end - start)) }
      }
      for value in input {
        try queue.insert(value, pts: CMTime(value: Int64(value), timescale: 24))
        XCTAssertLessThanOrEqual(queue.count, depth + 1)
        if let value = try queue.pop() { output.append(value) }
      }
      while let value = try queue.pop(atEOF: true) { output.append(value) }
      XCTAssertEqual(output, Array(0..<64))
    }
  }
  func testDuplicateLateAndExcessiveAdmissionFail() throws {
    let queue = try PresentationBuffer<Int>(reorderDepth: 1)
    try queue.insert(1, pts: CMTime(value: 1, timescale: 24))
    XCTAssertThrowsError(try queue.insert(2, pts: CMTime(value: 1, timescale: 24)))
    try queue.insert(2, pts: CMTime(value: 2, timescale: 24))
    XCTAssertThrowsError(try queue.insert(3, pts: CMTime(value: 3, timescale: 24)))
    XCTAssertEqual(try queue.pop(), 1)
    XCTAssertThrowsError(try queue.insert(0, pts: .zero))
    queue.removeAll()
    XCTAssertEqual(queue.count, 0)
  }
  func testQueuedOwnersReleaseOnCancellation() throws {
    let budget = MediaBudget(limit: 1024)
    let queue = try PresentationBuffer<Reservation>(reorderDepth: 2)
    for i in 0..<2 {
      try queue.insert(
        budget.reserve(bytes: 100, kind: .frame), pts: CMTime(value: Int64(i), timescale: 24))
    }
    XCTAssertEqual(budget.current, 200)
    queue.removeAll()
    XCTAssertEqual(budget.current, 0)
    XCTAssertEqual(budget.frameCount, 0)
  }
}
