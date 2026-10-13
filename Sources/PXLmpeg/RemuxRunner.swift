import CoreMedia
import Foundation
import PXLAppleMedia
import PXLMedia

// Compressed packets stay in decode order. No VT session, Metal device, decoded
// surface or codec transform exists on this path. One pending buffer per input.
enum RemuxRunner {
  static func run(_ job: PreparedRemux, input: AssetInput, control: JobControl) async throws
    -> ProducedOutput
  {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue(label: "PXLmpeg.remux.\(job.id)", qos: .userInitiated).async {
        do {
          continuation.resume(returning: try process(job, input: input, control: control))
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
  private static func process(_ job: PreparedRemux, input: AssetInput, control: JobControl) throws
    -> ProducedOutput
  {
    try control.check()
    let request = job.request
    let transaction = try OutputTransaction(
      destination: request.destination, source: request.source, jobID: job.id,
      container: request.outputContainer)
    var outputTransferred = false
    defer { if !outputTransferred { transaction.abort() } }
    let budget = MediaBudget(limit: request.memoryBudgetBytes)
    let reader = try SampleReader(input: input, audioPolicy: request.audioPolicy)
    defer { reader.cancel() }
    let writer = try ContainerWriter(
      temporaryURL: transaction.temporaryURL, videoFormat: input.videoFormat,
      audioFormat: request.audioPolicy == .copy ? input.audioFormat : nil,
      container: request.outputContainer, transform: input.displayTransform,
      videoTimeScale: input.videoTimeScale)
    defer {
      writer.cancel()
      withExtendedLifetime(transaction) {}
    }
    var frames = 0
    var audioGroups = 0
    var footprint = MemoryFootprint.current()
    var pendingAudio = try reader.nextAudio()
    var audioReservation = try pendingAudio.map {
      try budget.reserve(bytes: $0.bytes, kind: .packet)
    }
    func pumpAudio(until end: CMTime? = nil) throws {
      while let packet = pendingAudio, end == nil || packet.pts < end! {
        try control.check()
        guard try writer.tryAppendAudio(packet) else { break }
        audioGroups += 1
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
    if pendingAudio == nil { writer.finishAudio() }
    control.setState("running")
    while try autoreleasepool(invoking: { () throws -> Bool in
      try control.check()
      guard let packet = try reader.nextVideo() else { return false }
      let reservation = try budget.reserve(bytes: packet.bytes, kind: .packet)
      defer { reservation.release() }
      try writer.appendVideo(packet.mappingOutputVideoTiming()) {
        try control.check()
        try pumpAudio()
      }
      frames += 1
      control.advance(frames: frames, seconds: packet.pts.seconds, peak: budget.peak)
      try pumpAudio(until: CMTimeAdd(packet.pts, packet.duration))
      if let current = MemoryFootprint.current() { footprint = max(footprint ?? 0, current) }
      withExtendedLifetime(audioReservation) {}
      return true
    }) {}
    guard frames > 0 else {
      throw MediaError(.unsupportedMedia, stage: "read", "No compressed video samples")
    }
    writer.finishVideo()
    while let packet = pendingAudio {
      try writer.appendAudio(packet, check: control.check)
      audioGroups += 1
      control.heartbeat()
      pendingAudio = nil
      audioReservation = nil
      pendingAudio = try reader.nextAudio()
      audioReservation = try pendingAudio.map { try budget.reserve(bytes: $0.bytes, kind: .packet) }
    }
    control.setState("draining")
    try writer.finish(check: control.check)
    var receipt = JobReceipt(jobID: job.id, requestDigest: job.requestDigest, state: "verifying")
    receipt.operation = .remux
    receipt.outputContainer = request.outputContainer
    receipt.frames = frames
    receipt.audioPackets = audioGroups
    receipt.ownedMemoryPeak = budget.peak
    receipt.processFootprintPeakBytes = footprint
    receipt.notes = [
      "Compressed video copied in decode order without re-encoding; decoder, GPU and encoder not used.",
      "Source coded dimensions and display transform retained; HDR/RPU compressed data is copied, not regenerated.",
      "AAC policy: \(request.audioPolicy.rawValue); audioPackets counts sample-buffer groups, not individual access units.",
      "Timed metadata tracks discarded: \(input.descriptor.timedMetadataTracks ?? 0), policy=\(request.timedMetadataPolicy.rawValue).",
      "Container: \(request.outputContainer.rawValue); MP4 fast-start enabled when selected.",
      "Owned peak counts bounded compressed buffers; opaque reader/writer allocations excluded.",
    ]
    outputTransferred = true
    return ProducedOutput(transaction: transaction, receipt: receipt)
  }
}
