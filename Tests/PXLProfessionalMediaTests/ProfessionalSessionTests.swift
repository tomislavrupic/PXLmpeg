import CoreVideo
import Foundation
import PXLMedia
import PXLTestSupport
import XCTest

@testable import PXLProfessionalMedia

final class ProfessionalSessionTests: XCTestCase {
  func fixture(frames: Int = 12, start: Int = 0) throws -> (URL, URL) {
    let dir = try FixtureFactory.directory()
    let url = dir.appendingPathComponent("hq.mov")
    try FixtureFactory.make(
      at: url, width: 160, height: 96, frames: frames, audio: true,
      startFrame: start, codec: .proRes422HQ, bitDepth: 10, audioPCM: true)
    return (dir, url)
  }
  func testNative422FramesAndPCMValues() async throws {
    let (dir, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = try await ProfessionalMediaSession.open(url)
    let frameValue = try await session.nextVideoFrame()
    let frame = try XCTUnwrap(frameValue)
    XCTAssertEqual(frame.presentationTime, try MediaTime(value: 0, timescale: 24))
    XCTAssertEqual(frame.duration, try MediaTime(value: 1, timescale: 24))
    let pixel = frame.pixelBuffer
    XCTAssertEqual(
      CVPixelBufferGetPixelFormatType(pixel), kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
    XCTAssertEqual(CVPixelBufferGetHeightOfPlane(pixel, 1), 96)
    XCTAssertEqual(
      CVBufferCopyAttachment(pixel, kCVImageBufferColorPrimariesKey, nil) as? String, "ITU_R_709_2")
    XCTAssertEqual(
      CVBufferCopyAttachment(pixel, kCVImageBufferYCbCrMatrixKey, nil) as? String, "ITU_R_709_2")
    CVPixelBufferLockBaseAddress(pixel, .readOnly)
    let uv = CVPixelBufferGetBaseAddressOfPlane(pixel, 1)!.assumingMemoryBound(to: UInt16.self)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 1) / 2
    XCTAssertGreaterThan(Int(uv[stride]) - Int(uv[0]), 20000, "vertical chroma was subsampled")
    let y = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt16.self)
    XCTAssertTrue(
      (0..<160).contains { y[$0] & 0xC0 != 0 }, "luma was reduced to eight-bit precision")
    CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
    let chunkValue = try await session.nextAudioChunk(maximumFrames: 127)
    let chunk = try XCTUnwrap(chunkValue)
    XCTAssertEqual(chunk.frameCount, 127)
    XCTAssertEqual(chunk.channels, 2)
    XCTAssertEqual(chunk.samples.count, 127 * 2 * 4)
    let values = chunk.samples.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    XCTAssertEqual(values[2], Float(sin(2 * .pi * 440 / 48000) * 0.2), accuracy: 0.000001)
    XCTAssertEqual(values[3], -values[2], accuracy: 0.000001)
    let secondValue = try await session.nextAudioChunk(maximumFrames: 127)
    let second = try XCTUnwrap(secondValue)
    XCTAssertEqual(second.presentationTime, try MediaTime(value: 127, timescale: 48000))
    let metrics = await session.metrics()
    XCTAssertTrue(metrics.decoderHardware, "hardware-required default was bypassed")
    await session.close()
    XCTAssertFalse(session.isCurrent(generation: frame.generation))
  }
  func testRetainedFrameBudgetDoesNotConsumeNextSample() async throws {
    let (dir, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = try await ProfessionalMediaSession.open(
      url,
      options: ProfessionalMediaOptions(maximumRetainedVideoFrames: 1))
    var frame = try await session.nextVideoFrame()
    XCTAssertNotNil(frame)
    do {
      _ = try await session.nextVideoFrame()
      XCTFail("retained frame limit exceeded")
    } catch let error as MediaError { XCTAssertEqual(error.code, .resourceLimit) }
    frame = nil
    let nextValue = try await session.nextVideoFrame()
    let next = try XCTUnwrap(nextValue)
    XCTAssertEqual(next.presentationTime, try MediaTime(value: 1, timescale: 24))
    await session.close()
  }
  func testSeekTrimsAudioInvalidatesGenerationAndRestartsAfterEOF() async throws {
    let (dir, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = try await ProfessionalMediaSession.open(url)
    var firstValue = try await session.nextVideoFrame()
    let oldGeneration = try XCTUnwrap(firstValue).generation
    let target = try MediaTime(value: 10001, timescale: 48000)
    let generation = try await session.seek(to: target)
    XCTAssertFalse(session.isCurrent(generation: oldGeneration))
    firstValue = nil
    do {
      let soughtValue = try await session.nextVideoFrame()
      let sought = try XCTUnwrap(soughtValue)
      XCTAssertEqual(sought.generation, generation)
      XCTAssertEqual(sought.presentationTime, try MediaTime(value: 6, timescale: 24))
    }
    let audioValue = try await session.nextAudioChunk(maximumFrames: 333)
    let audio = try XCTUnwrap(audioValue)
    XCTAssertGreaterThanOrEqual(audio.presentationTime, target)
    XCTAssertLessThan(audio.presentationTime.seconds - target.seconds, 1.0 / 48000)
    while let frame = try await session.nextVideoFrame() {
      XCTAssertGreaterThanOrEqual(frame.presentationTime, target)
    }
    let end = try await session.nextVideoFrame()
    XCTAssertNil(end)
    _ = try await session.seek(to: MediaTime(value: 0, timescale: 1))
    let restarted = try await session.nextVideoFrame()
    XCTAssertNotNil(restarted)
    await session.close()
    await session.close()
  }
  func testSourceStartAndAudioContinuity() async throws {
    let (dir, url) = try fixture(frames: 4, start: 2)
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = try await ProfessionalMediaSession.open(url)
    let frameValue = try await session.nextVideoFrame()
    let frame = try XCTUnwrap(frameValue)
    XCTAssertEqual(frame.presentationTime, try MediaTime(value: 2, timescale: 24))
    var total = 0
    while let audio = try await session.nextAudioChunk(maximumFrames: 701) {
      XCTAssertEqual(audio.presentationTime, try MediaTime(value: Int64(total), timescale: 48000))
      total += audio.frameCount
    }
    XCTAssertEqual(total, 8000)
    await session.close()
  }
  func testInvalidSeekAndCancellationAreExplicit() async throws {
    let (dir, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = try await ProfessionalMediaSession.open(url)
    for target in [try MediaTime(value: -1, timescale: 1), try MediaTime(value: 100, timescale: 1)]
    {
      do {
        _ = try await session.seek(to: target)
        XCTFail("invalid seek accepted")
      } catch let error as MediaError { XCTAssertEqual(error.code, .invalidRequest) }
    }
    session.cancel()
    do {
      _ = try await session.nextVideoFrame()
      XCTFail("cancelled session emitted a frame")
    } catch let error as MediaError { XCTAssertEqual(error.code, .cancelled) }
    await session.close()
  }
  func testBoundedAdmissionDoesNotInvalidateSeekOnResourcePressure() throws {
    let fence = SessionFence()
    var tickets: [UInt64] = []
    for _ in 0..<8 { try fence.schedule(advancing: false) { tickets.append($0) } }
    XCTAssertThrowsError(
      try fence.schedule(advancing: true) { _ in XCTFail("unbounded admission") }
    ) {
      XCTAssertEqual(($0 as? MediaError)?.code, .resourceLimit)
    }
    XCTAssertTrue(fence.isCurrent(1), "failed seek invalidated the working generation")
    fence.finished()
    try fence.schedule(advancing: true) { tickets.append($0) }
    XCTAssertEqual(tickets.last, 2)
    XCTAssertFalse(fence.isCurrent(1))
  }

  func testSourceReplacementFailsBeforeDelivery() async throws {
    let (dir, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = try await ProfessionalMediaSession.open(url)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 123)], ofItemAtPath: url.path)
    do {
      _ = try await session.nextVideoFrame()
      XCTFail("changed source delivered")
    } catch let error as MediaError { XCTAssertEqual(error.code, .sourceChanged) }
    await session.close()
  }

  func testConcurrentSeeksOnlyAdmitCurrentGeneration() async throws {
    let (dir, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let session = try await ProfessionalMediaSession.open(url)
    await withTaskGroup(of: Void.self) { group in
      for i in 0..<16 {
        group.addTask {
          do {
            let generation = try await session.seek(
              to: MediaTime(value: Int64(i % 8), timescale: 24))
            if let frame = try await session.nextVideoFrame(),
              session.isCurrent(generation: frame.generation)
            {
              XCTAssertGreaterThanOrEqual(frame.generation, generation)
            }
          } catch let error as MediaError {
            XCTAssertTrue([.cancelled, .resourceLimit].contains(error.code))
          } catch { XCTFail("unexpected transport failure: \(error)") }
        }
      }
    }
    _ = try await session.seek(to: MediaTime(value: 7, timescale: 24))
    let frameValue = try await session.nextVideoFrame()
    XCTAssertEqual(
      try XCTUnwrap(frameValue).presentationTime, try MediaTime(value: 7, timescale: 24))
    await session.close()
  }

  func testDelayedPCMContentAndSeekPreserveTimeline() async throws {
    let dir = try FixtureFactory.directory()
    let url = dir.appendingPathComponent("offset.mov")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FixtureFactory.make(
      at: url, width: 160, height: 96, frames: 8, audio: true,
      codec: .proRes422HQ, bitDepth: 10, audioPCM: true, audioStartSample: 6000)
    let session = try await ProfessionalMediaSession.open(url)
    let first = try await session.nextAudioChunk(maximumFrames: 123)
    XCTAssertEqual(
      try XCTUnwrap(first).presentationTime, try MediaTime(value: 0, timescale: 48000))
    // AVAssetWriter represents this delayed PCM source with initial timeline silence.
    let initialValues = try XCTUnwrap(first).samples.withUnsafeBytes {
      Array($0.bindMemory(to: Float.self))
    }
    XCTAssertTrue(initialValues.allSatisfy { $0 == 0 })
    _ = try await session.seek(to: MediaTime(value: 8001, timescale: 48000))
    let sought = try await session.nextAudioChunk(maximumFrames: 321)
    XCTAssertEqual(
      try XCTUnwrap(sought).presentationTime, try MediaTime(value: 8001, timescale: 48000))
    let soughtValues = try XCTUnwrap(sought).samples.withUnsafeBytes {
      Array($0.bindMemory(to: Float.self))
    }
    XCTAssertEqual(
      soughtValues[0], Float(sin(Double(8001) * 2 * .pi * 440 / 48000) * 0.2), accuracy: 0.000001)
    await session.close()
  }

}
