import CoreMedia
import Foundation
import PXLAppleMedia
import PXLMedia

protocol ProfessionalSessionWorker: AnyObject, Sendable {
  func start(at: CMTime) throws
  func nextVideo(generation: UInt64, check: () throws -> Void) throws -> ProfessionalVideoFrame?
  func nextAudio(maximumFrames: Int, generation: UInt64, check: () throws -> Void) throws -> ProfessionalAudioChunk?
  func requireHealthy() throws
  func fail(_ error: Error)
  func close()
  func metrics() -> ProfessionalMediaMetrics
}
extension ProfessionalWorker: ProfessionalSessionWorker {}

/// Mutable decode/read cursors are confined to ProfessionalMediaSession.queue.
final class MXFWorker: ProfessionalSessionWorker, @unchecked Sendable {
  private var source: MXFSource?
  let options: ProfessionalMediaOptions, budget: MediaBudget
  private var decoder: ProResDecoder?
  private var videoIndex = 0, audioSample: Int64 = 0
  private var videoCount = 0, audioCount = 0
  private var failed: Error?, hardware = false
  init(source: MXFSource, options: ProfessionalMediaOptions, budget: MediaBudget) {
    self.source = source; self.options = options
    self.budget = budget
  }
  func start(at target: CMTime) throws {
    try requireHealthy()
    guard let source else { throw MediaError(.cancelled,stage:"mxf-read","Closed source") }
    try source.file.checkIdentity()
    if decoder == nil {
      decoder = try ProResDecoder(format:source.format,width:source.descriptor.width,height:source.descriptor.height,policy:options.hardwarePolicy)
      hardware = decoder!.hardware
    }
    videoIndex = min(source.entries.count,Int(CMTimeConvertScale(target,timescale:25,method:.roundTowardPositiveInfinity).value))
    audioSample = min(Int64(source.entries.count)*1920,CMTimeConvertScale(target,timescale:48000,method:.roundTowardPositiveInfinity).value)
  }
  func nextVideo(generation: UInt64, check: () throws -> Void) throws -> ProfessionalVideoFrame? {
    try requireHealthy(); try check()
    guard let source else { return nil }
    try source.file.checkIdentity()
    guard videoIndex < source.entries.count, let decoder else { return nil }
    let frameHold = try budget.reserve(bytes:decoder.reservedFrameBytes,kind:.frame)
    // Annex B input + AVCC output, then AVCC + Core Media copy. Fixed parser scratch allowance.
    let packetHold = try budget.reserve(bytes:ProfessionalLimits.packetBytes*2+1024*1024,kind:.bytes)
    defer { packetHold.release() }
    let frame = try source.picture(videoIndex)
    let sample = try frame.sample(format:source.format,index:videoIndex)
    let pixel = try decoder.decode(sample)
    try source.file.checkIdentity(); try check()
    let result = try ProfessionalVideoFrame(pixel:pixel,pts:CMTime(value:Int64(videoIndex),timescale:25),
      duration:CMTime(value:1,timescale:25),generation:generation,reservation:frameHold)
    videoIndex += 1; videoCount += 1
    return result
  }
  func nextAudio(maximumFrames: Int, generation: UInt64, check: () throws -> Void) throws -> ProfessionalAudioChunk? {
    try requireHealthy(); try check()
    guard let source else { return nil }
    try source.file.checkIdentity()
    guard audioSample < Int64(source.entries.count)*1920 else { return nil }
    let unit = Int(audioSample/1920), offset = Int(audioSample%1920), count = min(maximumFrames,1920-offset)
    let hold = try budget.reserve(bytes:count*8*4,kind:.bytes)
    let temporary = try budget.reserve(bytes:8*5760,kind:.bytes)
    defer { temporary.release() }
    let data = try MXFPCM.interleave(source.audioPlanes(unit),offset:offset,frames:count)
    try source.file.checkIdentity(); try check()
    let chunk = try ProfessionalAudioChunk(samples:data,frames:count,channels:8,
      pts:CMTime(value:audioSample,timescale:48000),generation:generation,reservation:hold)
    audioSample += Int64(count); audioCount += count
    return chunk
  }
  func requireHealthy() throws { if let failed { throw failed } }
  func fail(_ error: Error) { failed = error; close() }
  func close() { decoder = nil; source = nil }
  func metrics() -> ProfessionalMediaMetrics {
    ProfessionalMediaMetrics(decoderHardware:hardware,ownedMemoryBytes:budget.current,
      ownedMemoryPeakBytes:budget.peak,retainedVideoFrames:budget.frameCount,
      deliveredVideoFrames:videoCount,deliveredAudioFrames:audioCount)
  }
}
