import Foundation
import CoreVideo
import CoreMedia
import PXLMedia
import XCTest
@testable import PXLProfessionalMedia

final class MXFTests: XCTestCase {
  func testBERBoundsAndIndefiniteLength() throws {
    XCTAssertEqual(try MXFBinary.ber([0x83, 0x12, 0x34, 0x56]).length, 0x123456)
    XCTAssertEqual(try MXFBinary.ber([0x7f]).length, 127)
    for bad: [UInt8] in [[0x80], [0x89], [0x83, 1], [0x88, 255,255,255,255,255,255,255,255]] {
      XCTAssertThrowsError(try MXFBinary.ber(bad))
    }
  }
  func testLocalSetsRejectDuplicatesAndTruncation() throws {
    XCTAssertEqual(try MXFBinary.fields(Data([0x30,1,0,1,42]))[0x3001], Data([42]))
    for b: [UInt8] in [[0x30], [0x30,1,0,2,42], [0x30,1,0,0,0x30,1,0,0]] {
      XCTAssertThrowsError(try MXFBinary.fields(Data(b)))
    }
  }
  func testIntraIndexRejectsTemporalOverlappingAndOutOfBoundsRows() throws {
    func integer(_ value: UInt64, _ bytes: Int) -> Data {
      Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded:value >> ($0*8)) })
    }
    func row(_ offset: UInt64, _ flags: UInt8 = 0xc4, _ temporal: UInt8 = 0) -> Data {
      Data([temporal,0,flags])+integer(offset,8)+integer(1024,4)
    }
    let header = integer(2,4)+integer(15,4)
    let good = header+row(0)+row(51200)
    let rows = try MXFIndex.rows(good,remaining:2,bodyBytes:103000,previous:nil)
    XCTAssertEqual(rows.map(\.offset),[0,51200])
    func table(_ first: Data, _ second: Data) -> Data {
      var value = header; value.append(first); value.append(second); return value
    }
    var wrongStride = good; wrongStride[7] = 14
    let badTables: [Data] = [table(row(0,0x44),row(51200)),table(row(0,0xc4,1),row(51200)),
                            table(row(0),row(UInt64.max)),table(row(0),row(50000)),
                            table(row(1),row(51200)),wrongStride]
    for bad in badTables {
      XCTAssertThrowsError(try MXFIndex.rows(bad,remaining:2,bodyBytes:103000,previous:nil))
    }
    XCTAssertThrowsError(try MXFIndex.rows(good,remaining:1,bodyBytes:103000,previous:nil))
  }
  func testPCM24SignExtensionAndChannelOrder() throws {
    let planes = [Data([0,0,0x80, 255,255,0x7f]), Data([0,0,0, 0,0,0x40])]
    let result = try MXFPCM.interleave(planes, offset: 0, frames: 2)
    let floats = result.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    XCTAssertEqual(floats, [-1, 0, Float(8388607)/8388608, 0.5])
    XCTAssertThrowsError(try MXFPCM.interleave([Data([1])], offset: 0, frames: 1))
  }
  func testAnnexBRejectsNonIntraAndMissingParameterSets() throws {
    XCTAssertThrowsError(try XAVCFrame.parse(Data([0,0,1,0x41,0x80])))
    XCTAssertThrowsError(try XAVCFrame.parse(Data([0,0,1,0x65,0x80])))
    XCTAssertThrowsError(try XAVCFrame.parse(Data([1,2,3,4])))
  }
  func testXAVCParameterContractAndSamplePackaging() throws {
    // Parameter-set syntax only; no source image data. High 422 Intra, 3840x2160.
    let sps = MXFBinary.hex("277a1033b6cf00f0010fb011000012c00003a98084")
    let pps = MXFBinary.hex("28ce3133881136b88c251905016822c2dc2983683a8280b411616e14c1b41d088249ae4f5ffe23f8cfc31f0e7820e231110130")
    func annex(_ units: [Data]) -> Data { units.reduce(Data()) { $0+Data([0,0,0,1])+$1 } }
    let picture = try XAVCFrame.parse(annex([sps,pps,Data([0x65,0xb8])]))
    let format = try picture.format(width:3840,height:2160)
    XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(format).width,3840)
    XCTAssertNil(try XAVCFrame.validateSPS(sps,width:3840,height:2160).colourSpace, "Unspecified VUI color must not be reported as declared BT.709")
    let sample = try picture.sample(format:format,index:14853)
    XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample),CMTime(value:14853,timescale:25))
    XCTAssertEqual(CMSampleBufferGetDuration(sample),CMTime(value:1,timescale:25))
    XCTAssertThrowsError(try picture.format(width:1920,height:1080))
    var unsupported = sps; unsupported[1] = 100
    XCTAssertThrowsError(try XAVCFrame.parse(annex([unsupported,pps,Data([0x65,0xb8])])).format(width:3840,height:2160))
    XCTAssertThrowsError(try XAVCFrame.parse(annex([sps,sps,pps,Data([0x65,0xb8])])))
    XCTAssertThrowsError(try XAVCFrame.parse(annex([sps,pps,Data([0x65,0xb8]),Data([0x65,0xb8])])))
    XCTAssertThrowsError(try XAVCFrame.parse(annex(Array(repeating:Data([0x09,0x10]),count:257))))
  }
  func testLowMXFBudgetRejectsBeforeOpeningSource() async throws {
    do {
      _ = try await ProfessionalMediaSession.open(URL(fileURLWithPath:"/nonexistent/never-opened.mxf"),
        options:ProfessionalMediaOptions(memoryBudgetBytes:4*1024*1024))
      XCTFail("Inadequate budget admitted")
    } catch let error as PXLMedia.MediaError { XCTAssertEqual(error.code,.invalidRequest) }
  }
  func testExplicitVUIColorCannotSilentlyChangeMatrixOrPixels() throws {
    func sps(sar: Int = 1, matrix: Int = 1) -> Data {
      var bits = ""
      func fixed(_ value: Int,_ width: Int) {
        for shift in (0..<width).reversed() { bits += value & (1<<shift) == 0 ? "0" : "1" }
      }
      func ue(_ value: Int) { let b = String(value+1,radix:2); bits += String(repeating:"0",count:b.count-1)+b }
      fixed(122,8); fixed(16,8); fixed(51,8)
      ue(0); ue(2); ue(2); ue(2); fixed(0,2)
      ue(0); ue(2); ue(0); fixed(0,1); ue(9); ue(5)
      fixed(1,1); fixed(1,1); fixed(0,1); fixed(1,1)
      fixed(1,1); fixed(sar,8); fixed(0,1)
      fixed(1,1); fixed(5,3); fixed(0,1); fixed(1,1)
      fixed(1,8); fixed(1,8); fixed(matrix,8)
      fixed(0,1); fixed(1,1); fixed(4800,32); fixed(240000,32); fixed(1,1)
      fixed(0,4); fixed(1,1)
      while bits.count%8 != 0 { bits += "0" }
      let chars = Array(bits)
      var data = Data([0x67])
      for i in stride(from:0,to:chars.count,by:8) { data.append(UInt8(String(chars[i..<i+8]),radix:2)!) }
      // H.264 emulation prevention, including timing fields containing zeros.
      var escaped = Data([0x67]), zeros = 0
      for b in data.dropFirst() { if zeros == 2 && b <= 3 { escaped.append(3); zeros = 0 }; escaped.append(b); zeros = b == 0 ? zeros+1 : 0 }
      return escaped
    }
    XCTAssertEqual(try XAVCFrame.validateSPS(sps(),width:160,height:96).colourSpace,.bt709)
    XCTAssertThrowsError(try XAVCFrame.validateSPS(sps(sar:2),width:160,height:96))
    XCTAssertThrowsError(try XAVCFrame.validateSPS(sps(matrix:9),width:160,height:96))
  }
  func testKLVBoundsAndSourceReplacement() throws {
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString+".mxf")
    defer { try? FileManager.default.removeItem(at:url) }
    let bytes = Data(repeating:0,count:16)+Data([0x83,0,0,3,1,2,3])
    try bytes.write(to:url)
    let file = try MXFFile(url)
    let k = try file.klv(0,end:UInt64(bytes.count))
    XCTAssertEqual(k.value,20); XCTAssertEqual(k.length,3)
    XCTAssertThrowsError(try file.klv(0,end:22))
    XCTAssertThrowsError(try file.read(UInt64.max,1,maximum:1))
    XCTAssertThrowsError(try file.read(0,100,maximum:100))
    try Data([1,2,3]).write(to:url,options:.atomic)
    XCTAssertThrowsError(try file.checkIdentity())
  }

}

extension MXFTests {
  func testRealXAVCNativeHardwareAndDistantSeeks() async throws {
    guard let path = ProcessInfo.processInfo.environment["PXL_TEST_XAVC_SOURCE"] else { throw XCTSkip("Run this test through safe-dev probe with a staged XAVC copy") }
    guard ProcessInfo.processInfo.environment["PXL_SAFE_DEV_ACTIVE"] == "probe",
      ProcessInfo.processInfo.environment["PXL_DISPOSABLE_SOURCE"] == path else {
      XCTFail("Real media tests require guarded disposable input"); return
    }
    let url = URL(fileURLWithPath:path)
    let session = try await ProfessionalMediaSession.open(url)
    do {
      XCTAssertEqual(session.descriptor.codec,"XAVC Intra")
      XCTAssertEqual(session.descriptor.audioChannels,8)
      let totalFrames = Int((session.descriptor.videoDuration.seconds*25).rounded())
      XCTAssertGreaterThan(totalFrames,1)
      for i in 0..<min(120,totalFrames) {
        let next = try await session.nextVideoFrame()
        let frame = try XCTUnwrap(next)
        XCTAssertEqual(frame.presentationTime.seconds,Double(i)/25,accuracy:0.000001)
      }
      var samples = 0
      let audioLimit = min(48000*30,totalFrames*1920)
      while samples < audioLimit {
        let next = try await session.nextAudioChunk(maximumFrames:min(8192,audioLimit-samples))
        let chunk = try XCTUnwrap(next)
        XCTAssertEqual(chunk.channels,8)
        XCTAssertEqual(chunk.presentationTime.seconds,Double(samples)/48000,accuracy:0.000001)
        XCTAssertEqual(chunk.samples.count,chunk.frameCount*32)
        samples += chunk.frameCount
      }
      let middle = Double(totalFrames/2)/25
      for seconds in [middle,Double(totalFrames-1)/25,0.02] {
        let target = try PXLMedia.MediaTime(value:Int64((seconds*48000).rounded()),timescale:48000)
        let gen = try await session.seek(to:target)
        let next = try await session.nextVideoFrame()
        let frame = try XCTUnwrap(next)
        XCTAssertEqual(frame.generation,gen)
        XCTAssertGreaterThanOrEqual(frame.presentationTime,target)
        XCTAssertLessThan(frame.presentationTime.seconds-target.seconds,0.040001)
        let audio = try await session.nextAudioChunk(maximumFrames:123)
        let chunk = try XCTUnwrap(audio)
        XCTAssertEqual(chunk.presentationTime,target)
        if seconds == middle {
          if let directory = ProcessInfo.processInfo.environment["PXL_TEST_PCM_REFERENCE_DIRECTORY"] {
            for channel in 0..<8 {
              let reference = try Data(contentsOf:URL(fileURLWithPath:directory).appendingPathComponent("ch\(channel).f32"))
              XCTAssertGreaterThanOrEqual(reference.count,123*4)
              for i in 0..<123 {
                XCTAssertEqual(chunk.samples.subdata(in:(i*8+channel)*4..<(i*8+channel+1)*4),reference.subdata(in:i*4..<(i+1)*4))
              }
            }
          }
          if let referencePath = ProcessInfo.processInfo.environment["PXL_TEST_XAVC_FRAME_REFERENCE"] {
            let reference = try Data(contentsOf:URL(fileURLWithPath:referencePath))
            let pixel = frame.pixelBuffer, width = session.descriptor.width, height = session.descriptor.height
            XCTAssertEqual(reference.count,width*height*4)
            CVPixelBufferLockBaseAddress(pixel,.readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixel,.readOnly) }
            let base = CVPixelBufferGetBaseAddressOfPlane(pixel,0)!.assumingMemoryBound(to:UInt16.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel,0)/2
            for (x,y) in [(100,100),(width/2,height/2),(width/3,height/3),(width-100,height-100),(100,height/2)] {
              let position = (y*width+x)*2
              let expected = Int(reference[position]) | Int(reference[position+1])<<8
              XCTAssertEqual(Int(base[y*stride+x] >> 6),expected)
            }
          }
        }
      }
      let metrics = await session.metrics()
      XCTAssertTrue(metrics.decoderHardware)
      XCTAssertLessThanOrEqual(metrics.ownedMemoryPeakBytes,128*1024*1024)
      print("Native XAVC: \(metrics.deliveredVideoFrames) pictures, \(metrics.deliveredAudioFrames) PCM frames, hardware=\(metrics.decoderHardware), owned peak=\(metrics.ownedMemoryPeakBytes)")
      await session.close()
      let closed = await session.metrics()
      XCTAssertEqual(closed.ownedMemoryBytes,0)
    } catch { await session.close(); throw error }
  }
}
