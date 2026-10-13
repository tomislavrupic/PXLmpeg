import CoreMedia
import CryptoKit
import Foundation
import PXLAppleMedia
import PXLMedia
import PXLMetal

public actor MediaEngine {
  private let configuration: EngineConfiguration
  private let identity = UUID()
  private var active: JobControl?
  private var previous: JobControl?
  public private(set) var lastReceipt: JobReceipt?
  public init(configuration: EngineConfiguration) { self.configuration = configuration }
  public func capabilities() async throws -> CapabilityReport {
    CapabilityReport(metalDevice: try MetalContext().device.name)
  }
  public func inspect(_ source: URL) async throws -> AssetDescriptor {
    try await AssetInput.open(source).descriptor
  }
  public func prepare(_ request: JobRequest) async throws -> PreparedJob {
    let fingerprint = try SourceFingerprint.read(request.source)
    let input = try await AssetInput.open(request.source, colourPolicy: request.inputColourPolicy)
    _ = try MetalContext()
    let plan = try MediaPlanner.prepare(request, asset: input.descriptor, engineID: identity)
    guard plan.fingerprint == fingerprint else {
      throw MediaError(.sourceChanged, stage: "prepare", "Source changed during preparation")
    }
    return plan
  }
  public func prepare(_ request: RemuxRequest) async throws -> PreparedRemux {
    let fingerprint = try SourceFingerprint.read(request.source)
    let input = try await AssetInput.open(request.source)
    try OutputTransaction.validate(
      destination: request.destination, source: request.source, container: request.outputContainer)
    guard
      (input.descriptor.timedMetadataTracks ?? 0) == 0 || request.timedMetadataPolicy == .discard
    else {
      throw MediaError(
        .unsupportedMedia, stage: "plan",
        "Timed metadata tracks require explicit timedMetadataPolicy=discard")
    }
    guard try SourceFingerprint.read(request.source) == fingerprint else {
      throw MediaError(.sourceChanged, stage: "prepare", "Source changed during remux preparation")
    }
    return PreparedRemux(
      request: request, asset: input.descriptor,
      requestDigest: SHA256.hash(data: try request.normalizedData()).map {
        String(format: "%02x", $0)
      }.joined(), estimatedWorkingSetBytes: 16 * 1024 * 1024, fingerprint: fingerprint,
      engineID: identity)
  }
  public func progress(for jobID: UUID) -> JobProgress? {
    if let active, active.id == jobID { return active.snapshot }
    if let previous, previous.id == jobID { return previous.snapshot }
    return nil
  }
  public func cancel(_ jobID: UUID) { if active?.id == jobID { active?.cancel() } }
  public func execute(_ job: PreparedJob) async throws -> JobReceipt {
    try await execute(ExecutionJob(job))
  }
  public func execute(_ job: PreparedRemux) async throws -> JobReceipt {
    try await execute(ExecutionJob(job))
  }
  private func execute(_ job: ExecutionJob) async throws -> JobReceipt {
    guard active == nil else {
      throw MediaError(.engineBusy, stage: "execute", "This engine already has a running job")
    }
    guard job.engineID == identity else {
      throw MediaError(.invalidRequest, stage: "execute", "Prepared job belongs to another engine")
    }
    let control = JobControl(id: job.id, timeout: configuration.noProgressTimeout)
    active = control
    lastReceipt = nil
    defer {
      control.stopWatchdog()
      previous = control
      active = nil
    }
    let started = ProcessInfo.processInfo.systemUptime
    do {
      return try await withTaskCancellationHandler {
        if Task.isCancelled { control.cancel() }
        try control.check()
        guard try SourceFingerprint.read(job.source) == job.fingerprint else {
          throw MediaError(.sourceChanged, stage: "execute", "Source changed after preparation")
        }
        let handle = try FileHandle(forReadingFrom: job.source)
        defer { try? handle.close() }
        let input = try await AssetInput.open(
          job.source, colourPolicy: job.colourPolicy)
        try control.check()
        let produced: ProducedOutput
        switch job.work {
        case .transcode(let plan):
          produced = try await JobRunner.run(plan, input: input, control: control)
        case .remux(let plan):
          produced = try await RemuxRunner.run(plan, input: input, control: control)
        }
        control.setState("verifying")
        try control.check()
        let output = try await AssetInput.open(produced.transaction.temporaryURL)
        guard output.descriptor.codec == job.codec,
          output.descriptor.rotation == job.rotation,
          output.descriptor.bitDepth == input.descriptor.bitDepth,
          output.descriptor.colourSpace == input.descriptor.colourSpace,
          output.contract.retainsMetadata(from: input.contract),
          output.descriptor.width == job.width,
          output.descriptor.height == job.height,
          output.descriptor.hasAudio == (job.audioPolicy == .copy && input.descriptor.hasAudio),
          abs(
            output.descriptor.duration.seconds
              - (job.audioPolicy == .drop
                ? input.videoEnd.seconds : input.descriptor.duration.seconds)) <= 0.002
        else {
          throw MediaError(
            .timingViolation, stage: "verify",
            "Output geometry, tracks, or duration differs from the plan")
        }
        if job.operation == .remux
          && (output.descriptor.hasDynamicHDR != input.descriptor.hasDynamicHDR
            || output.displayTransform != input.displayTransform)
        {
          throw MediaError(.unsupportedMedia, stage: "verify", "Remux HDR signalling or display transform changed")
        }
        guard try SourceFingerprint.read(job.source) == job.fingerprint else {
          throw MediaError(.sourceChanged, stage: "verify", "Source changed during execution")
        }
        var receipt = produced.receipt
        if job.operation == .remux {
          let sourceReader = try SampleReader(input: input, audioPolicy: .drop)
          let outputReader = try SampleReader(input: output, audioPolicy: .drop)
          defer {
            sourceReader.cancel()
            outputReader.cancel()
          }
          guard let original = try sourceReader.nextVideo(),
            let copied = try outputReader.nextVideo(), original.pts == copied.pts
          else {
            throw MediaError(
              .timingViolation, stage: "verify", "Remux first presentation time changed")
          }
          let before = CMSampleBufferGetOutputDecodeTimeStamp(original.buffer)
          let after = CMSampleBufferGetOutputDecodeTimeStamp(copied.buffer)
          if before.isNumeric && after.isNumeric {
            let delta = CMTimeSubtract(after, before)
            receipt.firstVideoDecodeTimeOffset = try MediaTime(
              value: delta.value, timescale: delta.timescale)
            receipt.notes.append(
              "First video DTS offset introduced by container mux: \(delta.value)/\(delta.timescale). Presentation timing is retained; corpus validation checks constant decode-clock rebasing."
            )
          }
        }
        try control.check()
        try control.commit { try produced.transaction.commit() }
        receipt.operation = job.operation
        receipt.outputContainer = job.container
        receipt.state = "completed"
        receipt.output = output.descriptor
        receipt.elapsedSeconds = ProcessInfo.processInfo.systemUptime - started
        lastReceipt = receipt
        return receipt
      } onCancel: {
        control.cancel()
      }
    } catch {
      var e =
        (error as? MediaError)
        ?? MediaError(.ioFailure, stage: "execute", String(describing: error))
      let state = e.code == .cancelled ? "cancelled" : "failed"
      control.setState(state)
      var receipt = JobReceipt(jobID: job.id, requestDigest: job.requestDigest, state: state)
      receipt.operation = job.operation
      receipt.outputContainer = job.container
      receipt.frames = control.snapshot.frames
      receipt.ownedMemoryPeak = control.peakBytes
      receipt.elapsedSeconds = ProcessInfo.processInfo.systemUptime - started
      receipt.errorCode = e.code
      receipt.errorMessage = e.errorDescription
      lastReceipt = receipt
      e.receipt = receipt
      throw e
    }
  }
}
