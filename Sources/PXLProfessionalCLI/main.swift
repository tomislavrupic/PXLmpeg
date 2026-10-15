import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import PXLMedia
import PXLProfessionalMedia

struct SeekEvidence: Encodable {
  let target: MediaTime
  let videoPTS: MediaTime?
  let audioPTS: MediaTime?
  let elapsedMilliseconds: Double
}
struct ProbeEvidence: Encodable {
  var schemaVersion = 1
  let operation = "professional-ingest-probe"
  let asset: ProfessionalAssetDescriptor
  let sourceSHA256: String
  let originalUnchanged: Bool
  let hardwarePolicy: ProfessionalHardwarePolicy
  let openMilliseconds: Double
  let firstFrameMilliseconds: Double
  let videoReadMilliseconds: Double
  let videoFrames: Int
  let videoEOF: Bool
  let firstVideoPTS: MediaTime?
  let lastVideoEnd: MediaTime?
  let audioFrames: Int
  let audioEOF: Bool
  let firstAudioPTS: MediaTime?
  let lastAudioEnd: MediaTime?
  let pixelFormat: String
  let seeks: [SeekEvidence]
  let metrics: ProfessionalMediaMetrics
  let sampledProcessFootprintPeakBytes: UInt64
}

@main enum ProfessionalCLI {
  static func main() async {
    do { try await run() } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      exit(2)
    }
  }
  static func run() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.count == 2, args[0] == "metadata", !args[1].hasPrefix("--") {
      let metadata = try CameraMetadataInspector.inspect(URL(fileURLWithPath: args[1]))
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      FileHandle.standardOutput.write(try encoder.encode(metadata))
      FileHandle.standardOutput.write(Data("\n".utf8))
      return
    }
    guard args.count >= 2, args[0] == "probe", !args[1].hasPrefix("--") else {
      throw MediaError(
        .invalidRequest, stage: "usage",
        "pxl-prores metadata /path/source.mxf OR probe /path/source.mov [--max-frames 120] [--allow-software]")
    }
    var maximum = 120
    var policy: ProfessionalHardwarePolicy = .requireHardware
    var i = 2
    while i < args.count {
      switch args[i] {
      case "--allow-software": policy = .allowSoftware
      case "--max-frames":
        i += 1
        guard i < args.count, let n = Int(args[i]), (1...10000).contains(n) else {
          throw MediaError(.invalidRequest, stage: "usage", "max-frames must be 1–10000")
        }
        maximum = n
      default: throw MediaError(.invalidRequest, stage: "usage", "Unknown option")
      }
      i += 1
    }
    let url = URL(fileURLWithPath: args[1])
    let original = try hash(url)
    let start = clock()
    let session = try await ProfessionalMediaSession.open(
      url, options: ProfessionalMediaOptions(hardwarePolicy: policy))
    do {
      let open = (clock() - start) * 1000
      var footprint = processFootprint()
      var videoFrames = 0
      var audioFrames = 0
      var firstVideo: MediaTime?
      var lastVideoEnd: MediaTime?
      var firstAudio: MediaTime?
      var lastAudioEnd: MediaTime?
      var videoEOF = false
      var audioEOF = false
      var firstLatency = 0.0
      var pixelFormat = ""
      let videoStart = clock()
      while videoFrames < maximum {
        guard let frame = try await session.nextVideoFrame() else {
          videoEOF = true
          break
        }
        if videoFrames == 0 {
          firstLatency = (clock() - videoStart) * 1000
          firstVideo = frame.presentationTime
          let format = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
          pixelFormat =
            String(
              bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: format >> $0) },
              encoding: .ascii) ?? "unknown"
        }
        videoFrames += 1
        lastVideoEnd = try add(frame.presentationTime, frame.duration)
        footprint = max(footprint, processFootprint())
      }
      let videoMilliseconds = (clock() - videoStart) * 1000
      // Safety cap for independent audio validation: at most 30 seconds per invocation.
      while audioFrames < 48000 * 30 {
        guard
          let audio = try await session.nextAudioChunk(
            maximumFrames: min(8192, 48000 * 30 - audioFrames))
        else {
          audioEOF = true
          break
        }
        if firstAudio == nil { firstAudio = audio.presentationTime }
        audioFrames += audio.frameCount
        lastAudioEnd = try add(audio.presentationTime, audio.duration)
        footprint = max(footprint, processFootprint())
      }
      var seeks: [SeekEvidence] = []
      for fraction in [0.25, 0.5, 0.75] {
        let seconds =
          session.descriptor.videoStart.seconds + session.descriptor.videoDuration.seconds
          * fraction
        let cm = CMTime(seconds: seconds, preferredTimescale: 48000)
        let target = try MediaTime(value: cm.value, timescale: cm.timescale)
        let seekStart = clock()
        let generation = try await session.seek(to: target)
        let frame = try await session.nextVideoFrame()
        let audio = try await session.nextAudioChunk(maximumFrames: 1024)
        guard frame.map({ $0.generation == generation && $0.presentationTime >= target }) ?? true,
          audio.map({ $0.generation == generation && $0.presentationTime >= target }) ?? true
        else {
          throw MediaError(
            .timingViolation, stage: "professional-probe", "Stale or pre-target seek result")
        }
        seeks.append(
          SeekEvidence(
            target: target, videoPTS: frame?.presentationTime,
            audioPTS: audio?.presentationTime, elapsedMilliseconds: (clock() - seekStart) * 1000))
        footprint = max(footprint, processFootprint())
      }
      let metrics = await session.metrics()
      await session.close()
      guard try hash(url) == original else {
        throw MediaError(
          .sourceChanged, stage: "professional-probe", "Original content hash changed")
      }
      let evidence = ProbeEvidence(
        asset: session.descriptor, sourceSHA256: original, originalUnchanged: true,
        hardwarePolicy: policy, openMilliseconds: open, firstFrameMilliseconds: firstLatency,
        videoReadMilliseconds: videoMilliseconds, videoFrames: videoFrames, videoEOF: videoEOF,
        firstVideoPTS: firstVideo, lastVideoEnd: lastVideoEnd, audioFrames: audioFrames,
        audioEOF: audioEOF,
        firstAudioPTS: firstAudio, lastAudioEnd: lastAudioEnd, pixelFormat: pixelFormat,
        seeks: seeks,
        metrics: metrics, sampledProcessFootprintPeakBytes: footprint)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      FileHandle.standardOutput.write(try encoder.encode(evidence))
      print("")
    } catch {
      await session.close()
      throw error
    }
  }
  static func clock() -> Double { ProcessInfo.processInfo.systemUptime }
  static func add(_ a: MediaTime, _ b: MediaTime) throws -> MediaTime {
    let c = CMTimeAdd(
      CMTime(value: a.value, timescale: a.timescale), CMTime(value: b.value, timescale: b.timescale)
    )
    return try MediaTime(value: c.value, timescale: c.timescale)
  }
  static func hash(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var digest = SHA256()
    while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
      digest.update(data: bytes)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
  static func processFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : 0
  }
}
