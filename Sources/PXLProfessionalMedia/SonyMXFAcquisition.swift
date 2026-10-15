import Foundation
import Darwin
import PXLMedia

/// A sampled acquisition record, separate from generic codec/container color tags.
public struct SonyCameraColour: Sendable, Equatable {
  public let sourceFingerprint: String
  public let monitoringLookName: String?
  public let exposureIndex: Int?
  public let isoSensitivity: Int?
  public let luminanceCodeRange: Int?
  public let gamma: String
  public let gamut: String
  public let gammaLabel: String
  public let gamutLabel: String?
  public let gamutFromGammaLabel: Bool
  public let packetOffset: UInt64
  public let bytesRead: Int
}

/// Read-only first-camera-record probe. Does not admit MXF for native decoding.
/// SMPTE RDD18 camera sets in ST436 ANC, 8-bit sample coding only.
public enum SonyMXFAcquisition {
  public static func inspect(_ url: URL) throws -> SonyCameraColour? {
    guard url.isFileURL, url.pathExtension.lowercased() == "mxf" else { return nil }
    let identity = try ProfessionalSourceIdentity.read(url)
    // Nonblocking/no-follow open closes the check/open race with FIFOs and symlinks.
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
    guard descriptor >= 0 else { throw MediaError(.ioFailure, stage: "camera-metadata", "Cannot open source") }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
          UInt64(opened.st_ino) == identity.inode, UInt64(opened.st_dev) == identity.device,
          UInt64(opened.st_size) == identity.size else {
      Darwin.close(descriptor)
      throw MediaError(.sourceChanged, stage: "camera-metadata", "Source changed before metadata open")
    }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    let end = try file.seekToEnd()
    try file.seek(toOffset: 0)
    var bytesRead = 0
    func read(_ count: Int) throws -> [UInt8]? {
      guard count >= 0, bytesRead + count <= 1024 * 1024 else { return nil }
      let data = try file.read(upToCount: count) ?? Data()
      bytesRead += data.count
      return data.count == count ? Array(data) : nil
    }
    for _ in 0..<4096 {
      let offset = try file.offset()
      guard offset < min(end, 64 * 1024 * 1024),
            let key = try read(16), let first = try read(1)?.first,
            Array(key.prefix(4)) == [0x06,0x0e,0x2b,0x34] else { return nil }
      var length = UInt64(first)
      if first & 0x80 != 0 {
        let count = Int(first & 0x7f)
        guard (1...8).contains(count), let raw = try read(count) else { return nil }
        length = raw.reduce(0) { ($0 << 8) | UInt64($1) }
      }
      let valueOffset = try file.offset()
      guard valueOffset <= end, length <= end - valueOffset else { return nil }
      if key == ancKey, length <= 65536, let value = try read(Int(length)),
         let colour = parseANC(value) {
        guard try ProfessionalSourceIdentity.read(url) == identity else {
          throw MediaError(.sourceChanged, stage: "camera-metadata", "Source changed during metadata read")
        }
        return SonyCameraColour(sourceFingerprint: identity.cameraFingerprint,
          monitoringLookName: colour.monitoringLookName, exposureIndex: colour.exposureIndex,
          isoSensitivity: colour.isoSensitivity, luminanceCodeRange: colour.luminanceCodeRange, gamma: colour.gamma, gamut: colour.gamut,
          gammaLabel: colour.label.map { String(format: "%02x", $0) }.joined(),
          gamutLabel: colour.gamutLabel?.map { String(format: "%02x", $0) }.joined(),
          gamutFromGammaLabel: colour.derived, packetOffset: offset, bytesRead: bytesRead)
      }
      try file.seek(toOffset: valueOffset + length)
    }
    return nil
  }

  private static let ancKey: [UInt8] = [0x06,0x0e,0x2b,0x34,0x01,0x02,0x01,0x01,0x0d,0x01,0x03,0x01,0x17,0x01,0x02,0x01]
  private static let cameraKey: [UInt8] = [0x06,0x0e,0x2b,0x34,0x02,0x53,0x01,0x01,0x0c,0x02,0x01,0x01,0x02,0x01,0,0]
  private static let sonyPrefix: [UInt8] = [0x06,0x0e,0x2b,0x34,0x04,0x01,0x01,0x06,0x0e,0x06,0x04,0x01]
  private struct Colour {
    let gamma: String, gamut: String
    let label: [UInt8]
    let gamutLabel: [UInt8]?
    let derived: Bool
    var monitoringLookName: String? = nil
    var exposureIndex: Int? = nil
    var isoSensitivity: Int? = nil
    var luminanceCodeRange: Int? = nil
  }
  private static func parseANC(_ bytes: [UInt8]) -> Colour? {
    var c = Cursor(bytes: bytes)
    guard let count = c.integer(2), (1...21).contains(count) else { return nil }
    var assembled = [UInt8](), sequence = 1
    for _ in 0..<count {
      guard c.take(2) != nil, c.take(1) != nil, c.integer(1) == 4,
            let samples = c.integer(2), let arrayCount = c.integer(4),
            c.integer(4) == 1, samples >= 4, samples <= arrayCount,
            let storage = c.take(arrayCount) else { return nil }
      let payload = Array(storage.prefix(samples))
      guard payload[0] == 0x43, payload[1] == 5 else { continue }
      guard Int(payload[2]) == samples - 3, Int(payload[3]) == sequence else { return nil }
      sequence += 1
      assembled.append(contentsOf: payload.dropFirst(4))
    }
    var sets = Cursor(bytes: assembled)
    var found: Colour?
    var capturedLook: String?
    while sets.remaining > 0 {
      guard let key = sets.take(16), let size = sets.ber(), let body = sets.take(size) else { return nil }
      var privateKey = cameraKey; privateKey[12] = 0x7f
      if key == privateKey {
        guard capturedLook == nil else { return nil }
        capturedLook = parseSonyLook(body); continue
      }
      guard key == cameraKey else { continue }
      guard found == nil, let colour = parseCamera(body) else { return nil }
      found = colour
    }
    found?.monitoringLookName = capturedLook
    return found
  }
  private static func parseSonyLook(_ bytes: [UInt8]) -> String? {
    let sonyOwner: [UInt8] = [0x96,0x69,0x08,0,0x46,0x78,3,0x1c,0x20,0x50,0,3,0xf0,0xc0,0x11,0x81]
    var fields = Cursor(bytes: bytes), owner: [UInt8]?, look: String?
    while fields.remaining > 0 {
      guard let tag = fields.integer(2), let count = fields.integer(2), let value = fields.take(count) else { return nil }
      if tag == 0xe000 { guard owner == nil else { return nil }; owner = value }
      if tag == 0xe109 {
        guard look == nil, (1...128).contains(count), !value.contains(0) else { return nil }
        look = String(bytes: value, encoding: .utf8)
      }
    }
    return owner == sonyOwner && look?.hasPrefix("SonyProf2:") == true ? look : nil
  }
  private static func parseCamera(_ bytes: [UInt8]) -> Colour? {
    var fields = Cursor(bytes: bytes), gamma: [UInt8]?, gamut: [UInt8]?
    var exposureIndex: Int?, isoSensitivity: Int?, luminanceCodeRange: Int?
    var seenExposureTags = Set<Int>()
    while fields.remaining > 0 {
      guard let tag = fields.integer(2), let count = fields.integer(2),
            let value = fields.take(count) else { return nil }
      if tag == 0x8115 || tag == 0x810b {
        guard count == 2, seenExposureTags.insert(tag).inserted else { return nil }
        let number = (Int(value[0]) << 8) | Int(value[1])
        if (1...32000).contains(number) {
          if tag == 0x8115 { exposureIndex = number } else { isoSensitivity = number }
        }
      }
      if tag == 0x8120 {
        guard luminanceCodeRange == nil, count == 1 else { return nil }
        luminanceCodeRange = Int(value[0])
      }
      if tag == 0x3210 { guard gamma == nil, count == 16 else { return nil }; gamma = value }
      if tag == 0x3219 { guard gamut == nil, count == 16 else { return nil }; gamut = value }
    }
    guard let gamma, Array(gamma.prefix(12)) == sonyPrefix else { return nil }
    let cine = Array(gamma.suffix(4)) == [1,1,6,5]
    guard cine || Array(gamma.suffix(4)) == [1,1,6,4] else { return nil }
    let expectedGamut = sonyPrefix + [1,3,1, cine ? 5 : 4]
    // RDD18 section5.4.25 explicitly defines S-Log3.Cine as paired with S-Gamut3.Cine.
    // Generic S-Log3 alone does not establish primaries.
    guard gamut == expectedGamut || (cine && gamut == nil) else { return nil }
    var colour = Colour(gamma: cine ? "s-log3-cine" : "s-log3",
                  gamut: cine ? "s-gamut3-cine" : "s-gamut3", label: gamma, gamutLabel: gamut, derived: gamut == nil)
    colour.exposureIndex = exposureIndex; colour.isoSensitivity = isoSensitivity
    colour.luminanceCodeRange = luminanceCodeRange
    return colour
  }
  private struct Cursor {
    let bytes: [UInt8]
    var position = 0
    var remaining: Int { bytes.count - position }
    mutating func take(_ count: Int) -> [UInt8]? {
      guard count >= 0, count <= remaining else { return nil }
      defer { position += count }
      return Array(bytes[position..<position + count])
    }
    mutating func integer(_ count: Int) -> Int? {
      guard (1...4).contains(count), let value = take(count) else { return nil }
      return value.reduce(0) { ($0 << 8) | Int($1) }
    }
    mutating func ber() -> Int? {
      guard let first = integer(1) else { return nil }
      if first & 0x80 == 0 { return first }
      return integer(first & 0x7f)
    }
  }
}
