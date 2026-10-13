import AVFoundation
import CryptoKit
import Foundation
import PXLAppleMedia
import PXLMedia
import PXLTestSupport
import PXLmpeg

private struct RemuxCase: Codable {
  let source: String
  var status = "failed", error: String?
  var videoMatches = false, audioMatches = false, picturesMatch = false, metadataMatches = false,
    sourceUnchanged = false
  var sourceSHA256: String?
  var receipts: [JobReceipt] = []
}
enum RemuxValidation {
  static func run(_ arguments: [String]) async throws {
    guard let path = arguments.first else {
      throw NSError(domain: "Usage: pxl-validation remux OUTPUT_DIRECTORY [SOURCE ...]", code: 2)
    }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var sources: [URL] = []
    for kind in 0..<5 {
      for rotation in [0, 90] {
        let url = directory.appendingPathComponent("native-\(kind)-\(rotation).mov")
        try FixtureFactory.make(
          at: url, width: 160, height: 96, frames: 48, audio: true,
          audioFrames: rotation == 0 ? 72 : 24, reorder: true, startFrame: 3,
          frameDurations: [1, 2, 1], codec: kind == 0 ? .h264 : .hevc, rotationDegrees: rotation,
          bitDepth: kind >= 2 ? 10 : 8,
          colourSpace: kind == 3 ? .hlg2020 : (kind == 4 ? .pq2020 : .bt709))
        sources.append(url)
      }
    }
    sources += arguments.dropFirst().map { URL(fileURLWithPath: $0) }
    var reports: [RemuxCase] = []
    for (index, source) in sources.enumerated() {
      var report = RemuxCase(source: source.path)
      do {
        let before = try hash(source)
        report.sourceSHA256 = before
        let input = try await AssetInput.open(source)
        let video = try await NativePacketReference.read(source, audio: false)
        let audio = try await NativePacketReference.read(source, audio: true)
        let pictures = try await NativeReference.frames(
          at: source, bitDepth: input.descriptor.effectiveBitDepth)
        var current = source
        for container in [OutputContainer.mp4, .mov] {
          let output = directory.appendingPathComponent("case-\(index).\(container.rawValue)")
          let request = try RemuxRequest(
            source: current, destination: output, outputContainer: container,
            timedMetadataPolicy: .discard)
          let engine = MediaEngine(configuration: try EngineConfiguration())
          let receipt = try await engine.execute(engine.prepare(request))
          report.receipts.append(receipt)
          let copiedVideo = try await NativePacketReference.read(output, audio: false)
          let copiedAudio = try await NativePacketReference.read(output, audio: true)
          if let difference = copiedVideo.difference(from: video, allowConstantDTSOffset: true) {
            throw NSError(domain: "Video: \(difference)", code: 3)
          }
          if let difference = copiedAudio.difference(from: audio) {
            throw NSError(domain: "AAC: \(difference)", code: 3)
          }
          let outputInput = try await AssetInput.open(output)
          let decoded = try await NativeReference.frames(
            at: output, bitDepth: input.descriptor.effectiveBitDepth)
          guard decoded == pictures else {
            throw NSError(domain: "Decoded pictures differ", code: 3)
          }
          guard outputInput.displayTransform == input.displayTransform,
            outputInput.descriptor.rotation == input.descriptor.rotation,
            outputInput.descriptor.width == input.descriptor.width,
            outputInput.descriptor.height == input.descriptor.height,
            outputInput.descriptor.bitDepth == input.descriptor.bitDepth,
            outputInput.descriptor.colourSpace == input.descriptor.colourSpace,
            outputInput.descriptor.hasDynamicHDR == input.descriptor.hasDynamicHDR,
            outputInput.contract.staticMetadata == input.contract.staticMetadata,
            CMFormatDescriptionEqualIgnoringExtensionKeys(
              outputInput.videoFormat, otherFormatDescription: input.videoFormat,
              extensionKeysToIgnore: [
                kCMFormatDescriptionExtension_FormatName,
                kCMFormatDescriptionExtension_SpatialQuality,
                kCMFormatDescriptionExtension_TemporalQuality,
              ] as CFArray, sampleDescriptionExtensionAtomKeysToIgnore: nil),
            (input.audioFormat == nil && outputInput.audioFormat == nil)
              || (input.audioFormat != nil && outputInput.audioFormat != nil
                && CMFormatDescriptionEqualIgnoringExtensionKeys(
                  input.audioFormat!, otherFormatDescription: outputInput.audioFormat!,
                  extensionKeysToIgnore: kCMFormatDescriptionExtension_FormatName,
                  sampleDescriptionExtensionAtomKeysToIgnore: nil)),
            receipt.operation == .remux, !receipt.decoderHardware, !receipt.encoderHardware,
            receipt.metalDevice.isEmpty, receipt.acceptedBitrate == nil,
            receipt.ownedMemoryPeak <= 16 * 1024 * 1024, receipt.frames == video.packets.count
          else { throw NSError(domain: "Remux metadata/format/receipt mismatch", code: 3) }
          current = output
        }
        report.videoMatches = true
        report.audioMatches = true
        report.picturesMatch = true
        report.metadataMatches = true
        report.sourceUnchanged = try hash(source) == before
        guard report.sourceUnchanged else { throw NSError(domain: "Source changed", code: 3) }
        report.status = "completed"
      } catch { report.error = String(describing: error) }
      reports.append(report)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(reports).write(to: directory.appendingPathComponent("remux.json"))
      print(
        "Remux \(index): \(report.status), \(report.error ?? "packets/audio/pictures/metadata matched")"
      )
    }
    let cli = try RemuxRequest(
      source: sources.last!, destination: directory.appendingPathComponent("cli-output.mp4"),
      outputContainer: .mp4, timedMetadataPolicy: .discard)
    try cli.normalizedData().write(to: directory.appendingPathComponent("cli-remux.json"))
    guard reports.allSatisfy({ $0.status == "completed" }) else {
      throw NSError(domain: "Remux acceptance failed; inspect remux.json", code: 3)
    }
  }
  private static func hash(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
      hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
