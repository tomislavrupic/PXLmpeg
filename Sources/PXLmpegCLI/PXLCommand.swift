import Darwin
import Foundation
import PXLMedia
import PXLmpeg

private struct PlanSummary: Encodable {
  let request: JobRequest
  let geometry: OutputGeometry
  let estimatedWorkingSetBytes: Int
  let requestDigest: String
  let operations: [String]
  init(_ plan: PreparedJob) {
    request = plan.request
    geometry = plan.geometry
    estimatedWorkingSetBytes = plan.estimatedWorkingSetBytes
    requestDigest = plan.requestDigest
    operations = [
      "read compressed samples", "hardware decode", "Metal NV12/P010 orientation and scale",
      "hardware encode", "AAC copy or explicit drop",
      "verify and publish \(plan.request.outputContainer.rawValue)",
    ]
  }
}
private struct RemuxPlanSummary: Encodable {
  let request: RemuxRequest
  let asset: AssetDescriptor
  let estimatedWorkingSetBytes: Int
  let requestDigest: String
  let operations: [String]
  init(_ plan: PreparedRemux) {
    request = plan.request
    asset = plan.asset
    estimatedWorkingSetBytes = plan.estimatedWorkingSetBytes
    requestDigest = plan.requestDigest
    operations = [
      "read compressed samples in decode order",
      "copy compressed video without decoding or encoding",
      "retain display transform and HDR signalling", "AAC copy or explicit drop",
      "verify and publish \(plan.request.outputContainer.rawValue)",
    ]
  }
}
private struct CLIError: Encodable {
  let code: ErrorCode
  let stage: String
  let message: String
}

@main struct PXLCommand {
  @MainActor static func main() async {
    let writer = JSONEventWriter()
    do {
      let command = try CLICommand.parse(Array(CommandLine.arguments.dropFirst()))
      let engine = MediaEngine(configuration: try EngineConfiguration())
      switch command {
      case .help:
        try writer.emit(
          "help",
          payload: [
            "usage":
              "pxlmpeg capabilities | inspect FILE | plan JOB.json | run JOB.json | plan-remux COPY.json | remux COPY.json [--json]",
            "version": PXLVersion.current,
          ])
      case .capabilities: try writer.emit("capabilities", payload: await engine.capabilities())
      case .inspect(let path):
        try writer.emit("asset", payload: await engine.inspect(URL(fileURLWithPath: path)))
      case .plan(let path), .run(let path):
        let data = try readRequest(path)
        let request = try JobRequest.decodeStrict(data)
        let plan = try await engine.prepare(request)
        if case .plan = command {
          try writer.emit(
            "plan", jobID: request.id,
            payload: PlanSummary(plan))
        } else {
          try await run(engine: engine, id: plan.id, writer: writer) {
            try await engine.execute(plan)
          }
        }
      case .planRemux(let path), .remux(let path):
        let request = try RemuxRequest.decodeStrict(readRequest(path))
        let plan = try await engine.prepare(request)
        if case .planRemux = command {
          try writer.emit("plan", jobID: request.id, payload: RemuxPlanSummary(plan))
        } else {
          try await run(engine: engine, id: plan.id, writer: writer) {
            try await engine.execute(plan)
          }
        }

      }
    } catch {
      let e =
        (error as? MediaError) ?? MediaError(.ioFailure, stage: "cli", String(describing: error))
      if let receipt = e.receipt {
        try? writer.emit(receipt.state, jobID: receipt.jobID, payload: receipt)
      } else {
        try? writer.emit(
          "error", payload: CLIError(code: e.code, stage: e.stage, message: e.message))
      }
      FileHandle.standardError.write(Data("\(e.errorDescription ?? e.message)\n".utf8))
      let code: Int32 =
        e.code == .cancelled
        ? 130
        : [
          .invalidRequest, .unsupportedMedia, .unsupportedHardware, .hardwareUnavailable,
          .resourceLimit,
        ].contains(e.code) ? 2 : 3
      exit(code)
    }
  }
  private static func readRequest(_ path: String) throws -> Data {
    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? file.close() }
    let data = try file.read(upToCount: 1024 * 1024 + 1) ?? Data()
    guard data.count <= 1024 * 1024 else {
      throw MediaError(.invalidRequest, stage: "cli", "Request exceeds 1 MiB")
    }
    return data
  }
  @MainActor private static func run(
    engine: MediaEngine, id: UUID, writer: JSONEventWriter,
    execute: @Sendable () async throws -> JobReceipt
  ) async throws {
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler { @Sendable in Task { await engine.cancel(id) } }
    interrupt.resume()
    defer { interrupt.cancel() }
    // One polling task, one latest-value progress slot; no accumulated event stream.
    let progress = Task { @MainActor in
      while !Task.isCancelled {
        try await Task.sleep(for: .milliseconds(250))
        if let snapshot = await engine.progress(for: id),
          !Task.isCancelled, !["completed", "cancelled", "failed"].contains(snapshot.state)
        {
          do { try writer.emit("progress", jobID: id, payload: snapshot) } catch {
            await engine.cancel(id)
            throw error
          }
        }
      }
    }
    do {
      let receipt = try await execute()
      progress.cancel()
      _ = await progress.result
      try writer.emit("completed", jobID: id, payload: receipt)
    } catch {
      progress.cancel()
      _ = await progress.result
      throw error
    }
  }
}
