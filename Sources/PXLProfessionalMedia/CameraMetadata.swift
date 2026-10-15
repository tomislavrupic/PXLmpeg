import Foundation
import PXLMedia

public struct CameraMetadataEvidence: Codable, Sendable, Equatable {
  public let field: String
  public let rawValue: String
  public let source: URL
  public let location: String
  public let derivation: String?
}

/// Capture facts only. Semantic/model annotations belong in a separate index or sidecar.
public struct CameraMetadata: Codable, Sendable, Equatable {
  public let sourceFingerprint: String
  public func matchesSource(_ url: URL) throws -> Bool {
    try ProfessionalSourceIdentity.read(url).cameraFingerprint == sourceFingerprint
  }
  public let labelNamespace: String
  public let cameraManufacturer: String? = nil
  public let monitoringLookName: String?
  public let exposureIndex: Int?
  public let isoSensitivity: Int?
  /// Raw RDD18 code, including unknown/reserved values. Nil means absent.
  public let luminanceCodeRange: Int?
  public let captureGamma: String
  public let captureGamut: String
  public let evidence: [CameraMetadataEvidence]
  public let samplingScope: String
  public let bytesRead: Int
}

/// Vendor-independent entry point. Only proven readers are enabled; unknown is not guessed.
public enum CameraMetadataInspector {
  public static func inspect(_ url: URL) throws -> CameraMetadata? {
    guard let sony = try SonyMXFAcquisition.inspect(url) else { return nil }
    let location = "MXF/ST436/RDD18/camera/0x3210@\(sony.packetOffset)"
    return CameraMetadata(sourceFingerprint: sony.sourceFingerprint, labelNamespace: "Sony",
      monitoringLookName: sony.monitoringLookName, exposureIndex: sony.exposureIndex,
      isoSensitivity: sony.isoSensitivity, luminanceCodeRange: sony.luminanceCodeRange, captureGamma: sony.gamma,
      captureGamut: sony.gamut, evidence: [
        CameraMetadataEvidence(field: "CaptureGammaEquation", rawValue: sony.gammaLabel,
          source: url, location: location, derivation: nil),
        CameraMetadataEvidence(field: "CaptureColorPrimaries", rawValue: sony.gamutLabel ?? sony.gammaLabel,
          source: url, location: sony.gamutFromGammaLabel ? location : "MXF/ST436/RDD18/camera/0x3219@\(sony.packetOffset)",
          derivation: sony.gamutFromGammaLabel ? "S-Log3.Cine label pairing defined by RDD18 section5.4.25" : nil)
      ] + [
        sony.exposureIndex.map { CameraMetadataEvidence(field: "ExposureIndexOfPhotoMeter", rawValue: String($0), source: url,
          location: "MXF/ST436/RDD18/camera/0x8115@\(sony.packetOffset)", derivation: nil) },
        sony.isoSensitivity.map { CameraMetadataEvidence(field: "ISOSensitivity", rawValue: String($0), source: url,
          location: "MXF/ST436/RDD18/camera/0x810b@\(sony.packetOffset)", derivation: nil) },
        sony.monitoringLookName.map { CameraMetadataEvidence(field: "CapturedMonitoringLook", rawValue: $0, source: url,
          location: "MXF/ST436/RDD18/SonyUDAM/0xe109@\(sony.packetOffset)", derivation: nil) },
        sony.luminanceCodeRange.map { CameraMetadataEvidence(field: "LuminanceCodeRange", rawValue: String($0), source: url,
          location: "MXF/ST436/RDD18/camera/0x8120@\(sony.packetOffset)", derivation: nil) }
      ].compactMap { $0 }, samplingScope: "first supported camera acquisition record; not whole-clip verification",
      bytesRead: sony.bytesRead)
  }
}

extension ProfessionalSourceIdentity {
  // A comparison token, not a cryptographic content checksum.
  var cameraFingerprint: String {
    "\(device):\(inode):\(size):\(modified.timeIntervalSince1970.bitPattern)"
  }
}
