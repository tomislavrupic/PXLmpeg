import AVFoundation
import AudioToolbox
import CoreVideo
import PXLAppleMedia
import PXLMedia
import PXLTestSupport
import XCTest
import VideoToolbox

@testable import PXLProfessionalMedia

final class ProfessionalMediaTests: XCTestCase {
  func testDecoderAvailabilityIsDistinctFromCorruptMedia() throws {
    for status in [kVTCouldNotFindVideoDecoderErr, kVTVideoDecoderNotAvailableNowErr] {
      XCTAssertThrowsError(try ProResDecoder.checkCreationStatus(status)) { error in
        XCTAssertEqual((error as? MediaError)?.code, .hardwareUnavailable)
      }
    }
    for status in [kVTVideoDecoderBadDataErr, kVTParameterErr] {
      XCTAssertThrowsError(try ProResDecoder.checkCreationStatus(status)) { error in
        XCTAssertEqual((error as? MediaError)?.code, .codecFailure)
      }
    }
    XCTAssertNoThrow(try ProResDecoder.checkCreationStatus(noErr))
  }
  func testHQAndLTAdmissionPreservesProfessionalContract() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    for codec: AVVideoCodecType in [.proRes422HQ, .proRes422LT, .proRes422, .proRes422Proxy] {
      let url = dir.appendingPathComponent("\(codec.rawValue).mov")
      try FixtureFactory.make(
        at: url, width: 160, height: 96, frames: 4, audio: true,
        codec: codec, bitDepth: 10, audioPCM: true)
      let info = try await ProfessionalMedia.inspect(url)
      XCTAssertEqual(info.width, 160)
      XCTAssertEqual(info.height, 96)
      XCTAssertEqual(info.codec, codec.rawValue)
      XCTAssertEqual(info.bitDepth, 10)
      XCTAssertEqual(info.chromaSubsampling, "4:2:2")
      XCTAssertEqual(info.audioChannels, 2)
      XCTAssertEqual(info.audioSampleRate, 48000)
      XCTAssertEqual(info.audioBitDepth, 24)
      XCTAssertEqual(info.colourSpace, .bt709)
      let session = try await ProfessionalMediaSession.open(url)
      let frame = try await session.nextVideoFrame()
      XCTAssertEqual(
        CVPixelBufferGetPixelFormatType(try XCTUnwrap(frame).pixelBuffer),
        kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
      let metrics = await session.metrics()
      XCTAssertTrue(metrics.decoderHardware)
      await session.close()
      do {
        _ = try await AssetInput.open(url)
        XCTFail("processing recipe silently broadened")
      } catch let error as MediaError { XCTAssertEqual(error.code, .unsupportedMedia) }
    }
  }

  func testRejectsDeliveryCodecAndBrokenMOV() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("delivery.mov")
    try FixtureFactory.make(at: url, width: 160, height: 96, frames: 1)
    do {
      _ = try await ProfessionalMedia.inspect(url)
      XCTFail("H264 accepted by ProRes contract")
    } catch let error as MediaError { XCTAssertEqual(error.code, .unsupportedMedia) }
    let broken = dir.appendingPathComponent("broken.mov")
    try Data([1, 2, 3]).write(to: broken)
    do {
      _ = try await ProfessionalMedia.inspect(broken)
      XCTFail("broken MOV accepted")
    } catch {}
  }
  func testRejects4444AndNonPCMCompanion() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    for (codec, pcm) in [(AVVideoCodecType.proRes4444, true), (.proRes422HQ, false)] {
      let url = dir.appendingPathComponent("\(codec.rawValue).mov")
      try FixtureFactory.make(
        at: url, width: 160, height: 96, frames: 2, audio: true,
        codec: codec, bitDepth: 10, audioPCM: pcm)
      do {
        _ = try await ProfessionalMedia.inspect(url)
        XCTFail("unsupported precision/audio admitted")
      } catch let error as MediaError { XCTAssertEqual(error.code, .unsupportedMedia) }
    }
  }

  func testCustomPCMLayoutIsRejectedBeforeDecode() async throws {
    let dir = try FixtureFactory.directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("discrete.mov")
    try FixtureFactory.make(
      at: url, width: 160, height: 96, frames: 2, audio: true,
      codec: .proRes422HQ, bitDepth: 10, audioPCM: true,
      audioChannelLayoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 2)
    do {
      _ = try await ProfessionalMedia.inspect(url)
      XCTFail("ambiguous channel identity admitted")
    } catch let error as MediaError { XCTAssertEqual(error.code, .unsupportedMedia) }
  }

  func testUnsignedIntegerPCMIsNotAdmitted() {
    var format = AudioStreamBasicDescription(
      mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
      mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
    XCTAssertFalse(ProfessionalSource.acceptsPCM(format))
    format.mFormatFlags |= kAudioFormatFlagIsSignedInteger
    XCTAssertTrue(ProfessionalSource.acceptsPCM(format))
  }

}
