import CoreMedia
import Foundation
import PXLAppleMedia
import PXLMedia
import PXLMetal

// Sole ownership transfers from worker to actor at continuation completion.
// The worker performs no further mutation of the transaction after returning it.
final class ProducedOutput: @unchecked Sendable {
  let transaction: OutputTransaction
  var receipt: JobReceipt
  init(transaction: OutputTransaction, receipt: JobReceipt) {
    self.transaction = transaction
    self.receipt = receipt
  }
}
enum JobRunner {
  static func run(_ job: PreparedJob, input: AssetInput, control: JobControl) async throws
    -> ProducedOutput
  {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue(label: "PXLmpeg.job.\(job.id)", qos: .userInitiated).async {
        do {
          continuation.resume(returning: try process(job, input: input, control: control))
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
  private static func process(_ job: PreparedJob, input: AssetInput, control: JobControl) throws
    -> ProducedOutput
  {
    try control.check()
    let transaction = try OutputTransaction(
      destination: job.request.destination, source: job.request.source, jobID: job.id,
      container: job.request.outputContainer)
    var outputTransferred = false
    defer { if !outputTransferred { transaction.abort() } }
    let depth = input.descriptor.maxReorderFrames ?? 16
    let budget = MediaBudget(limit: job.request.memoryBudgetBytes, frameLimit: depth + 1)
    let context = try MetalContext()
    let scaler = try PlaneScaler(context: context)
    let rotation = input.descriptor.rotation ?? .none
    let orienter = rotation == .none ? nil : try PlaneOrienter(context: context)
    let orientedPool =
      rotation == .none
      ? nil
      : try PixelBufferPool(
        width: input.descriptor.displayWidth, height: input.descriptor.displayHeight,
        budget: budget, bitDepth: input.contract.bitDepth
      )
    let reader = try SampleReader(input: input, audioPolicy: job.request.audioPolicy)
    defer { reader.cancel() }
    let decoder = try VideoDecoder(format: input.videoFormat, contract: input.contract)
    let video = try OrderedVideoReader(
      reader: reader, decoder: decoder, budget: budget, reorderDepth: depth)
    defer { video.cancel() }
    let encoder = try VideoEncoder(
      width: job.geometry.width, height: job.geometry.height, bitrate: job.request.videoBitrate,
      codec: job.request.outputCodec, contract: input.contract)
    let outputPool = try PixelBufferPool(
      width: job.geometry.width, height: job.geometry.height, budget: budget,
      bitDepth: input.contract.bitDepth)
    var writer: ContainerWriter?
    defer {
      writer?.cancel()
      withExtendedLifetime(transaction) {}
    }
    var frames = 0
    var audioPackets = 0
    var footprint = MemoryFootprint.current()
    var pendingAudio = try reader.nextAudio()
    var audioReservation = try pendingAudio.map {
      try budget.reserve(bytes: $0.bytes, kind: .packet)
    }
    // Service whichever mux input is ready without blocking the other track.
    func pumpAudio(until end: CMTime? = nil) throws {
      guard let writer else { return }
      while let audio = pendingAudio, end == nil || audio.pts < end! {
        try control.check()
        guard try writer.tryAppendAudio(audio) else { break }
        audioPackets += 1
        control.heartbeat()
        pendingAudio = nil
        audioReservation = nil
        pendingAudio = try reader.nextAudio()
        audioReservation = try pendingAudio.map {
          try budget.reserve(bytes: $0.bytes, kind: .packet)
        }
      }
      if pendingAudio == nil { writer.finishAudio() }
    }
    control.setState("running")
    while try autoreleasepool(invoking: { () throws -> Bool in
      try control.check()
      guard let decoded = try video.next(check: control.check) else { return false }
      try control.check()
      control.heartbeat()
      let output = try outputPool.acquire(pts: decoded.pts, duration: decoded.duration)
      let oriented = try orientedPool?.acquire(pts: decoded.pts, duration: decoded.duration)
      if let orienter, let oriented {
        try orienter.orient(decoded, into: oriented, rotation: rotation)
      }
      try control.check()
      try scaler.scale(oriented ?? decoded, into: output, budget: budget)
      try control.check()
      control.heartbeat()
      let encoded = try encoder.encode(output)
      let encodedReservation = try budget.reserve(bytes: encoded.bytes, kind: .packet)
      defer { encodedReservation.release() }
      try control.check()
      control.heartbeat()
      if writer == nil {
        guard let format = CMSampleBufferGetFormatDescription(encoded.buffer) else {
          throw MediaError(.codecFailure, stage: "mux", "Missing encoder format")
        }
        writer = try ContainerWriter(
          temporaryURL: transaction.temporaryURL, videoFormat: format,
          audioFormat: job.request.audioPolicy == .copy ? input.audioFormat : nil,
          container: job.request.outputContainer, videoTimeScale: input.videoTimeScale)
      }
      if pendingAudio == nil { writer!.finishAudio() }
      try writer!.appendVideo(encoded) {
        try control.check()
        try pumpAudio()
      }
      if let current = MemoryFootprint.current() { footprint = max(footprint ?? 0, current) }
      frames += 1
      control.advance(frames: frames, seconds: decoded.pts.seconds, peak: budget.peak)
      try pumpAudio(until: CMTimeAdd(decoded.pts, decoded.duration))
      withExtendedLifetime(audioReservation) {}
      return true
    }) {}
    guard let writer, frames > 0 else {
      throw MediaError(.unsupportedMedia, stage: "read", "No video frames")
    }
    writer.finishVideo()
    while let audio = pendingAudio {
      try writer.appendAudio(audio, check: control.check)
      audioPackets += 1
      control.heartbeat()
      pendingAudio = nil
      audioReservation = nil
      pendingAudio = try reader.nextAudio()
      audioReservation = try pendingAudio.map { try budget.reserve(bytes: $0.bytes, kind: .packet) }
    }
    control.setState("draining")
    try writer.finish(check: control.check)
    var receipt = JobReceipt(jobID: job.id, requestDigest: job.requestDigest, state: "verifying")
    receipt.frames = frames
    receipt.audioPackets = audioPackets
    receipt.decoderHardware = decoder.hardware
    receipt.encoderHardware = encoder.hardware
    receipt.acceptedBitrate = encoder.acceptedBitrate
    receipt.metalDevice = context.device.name
    receipt.ownedMemoryPeak = budget.peak
    receipt.processFootprintPeakBytes = footprint
    receipt.notes = [
      "Timed metadata tracks discarded: \(input.descriptor.timedMetadataTracks ?? 0), policy=\(job.request.timedMetadataPolicy.rawValue).",
      "Preserved \(input.contract.bitDepth)-bit \(input.contract.colourSpace.rawValue); supplied static/ambient metadata verified before publication.",
      input.contract.colourSpace.isHDR
        ? "HDR encoder policy: Auto metadata insertion, PreserveDynamicHDRMetadata=false; source RPU not copied. Output.hasDynamicHDR reports encoder RPU signalling, not Dolby certification."
        : "SDR pipeline; no HDR conversion requested.",
      "Display rotation baked into pixels: \(rotation.rawValue) degrees; output codec: \(job.request.outputCodec.rawValue).",
      "Input colour policy: \(job.request.inputColourPolicy.rawValue); \(input.descriptor.colour).",
      "Synchronous hardware decode in decode order; SPS-bounded display window \(depth), peak retained \(video.retainedFramesPeak) frames.",
      "Owned budget excludes opaque macOS/codec allocations.",
      "NV12/P010 shared surface mapping; new output and floating-point intermediate textures for resizing.",
    ]
    outputTransferred = true
    return ProducedOutput(transaction: transaction, receipt: receipt)
  }
}
