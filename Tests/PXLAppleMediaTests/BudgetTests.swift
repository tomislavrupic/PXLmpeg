import CoreMedia
import XCTest

@testable import PXLAppleMedia

final class BudgetTests: XCTestCase {
  func testReservationsAreBoundedAndReleaseOnce() throws {
    let budget = MediaBudget(limit: 100)
    let a = try budget.reserve(bytes: 80, kind: .bytes)
    XCTAssertThrowsError(try budget.reserve(bytes: 21, kind: .bytes))
    a.release()
    a.release()
    XCTAssertEqual(budget.current, 0)
    XCTAssertEqual(budget.peak, 80)
    var frames: [Reservation] = []
    for _ in 0..<4 { frames.append(try budget.reserve(bytes: 0, kind: .frame)) }
    XCTAssertThrowsError(try budget.reserve(bytes: 0, kind: .frame))
    frames.removeAll()
    XCTAssertEqual(budget.frameCount, 0)
  }
  func testPoolKeepsItsStorageChargedAndExclusive() throws {
    let budget = MediaBudget(limit: 64 * 1024 * 1024)
    var pool: PixelBufferPool? = try PixelBufferPool(width: 64, height: 32, budget: budget)
    let bytes = budget.current
    XCTAssertGreaterThanOrEqual(bytes, 64 * 32 * 3 / 2)
    var frame: MediaLease? = try pool!.acquire(
      pts: .zero, duration: CMTime(value: 1, timescale: 24))
    XCTAssertThrowsError(try pool!.acquire(pts: .zero, duration: .zero))
    XCTAssertNotNil(frame)
    frame = nil
    XCTAssertEqual(budget.current, bytes)
    pool = nil
    XCTAssertEqual(budget.current, 0)
  }
}
