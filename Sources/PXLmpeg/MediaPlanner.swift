import CryptoKit
import Foundation
import PXLAppleMedia
import PXLMedia

struct MediaPlanner {
  static func prepare(_ request: JobRequest, asset: AssetDescriptor, engineID: UUID) throws
    -> PreparedJob
  {
    if (asset.timedMetadataTracks ?? 0) > 0 && request.timedMetadataPolicy != .discard {
      throw MediaError(
        .unsupportedMedia, stage: "plan",
        "Timed metadata tracks require explicit timedMetadataPolicy=discard")
    }
    try OutputTransaction.validate(
      destination: request.destination, source: request.source, container: request.outputContainer)
    if asset.effectiveBitDepth == 10 && request.outputCodec != .hevc {
      throw MediaError(
        .unsupportedMedia, stage: "plan",
        "Ten-bit/HDR input requires outputCodec=hevc; no silent reduction")
    }
    let geometry = try OutputGeometry(
      sourceWidth: asset.displayWidth, sourceHeight: asset.displayHeight, width: request.resizeWidth
    )
    let sourceBytes = PixelContract.storageBytes(
      width: asset.width, height: asset.height, bitDepth: asset.effectiveBitDepth)
    let outputBytes = PixelContract.storageBytes(
      width: geometry.width, height: geometry.height, bitDepth: asset.effectiveBitDepth)
    let scratch =
      geometry.width == asset.displayWidth && geometry.height == asset.displayHeight
      ? 0 : geometry.width * asset.displayHeight * 10 + 131072
    let reorderDepth = asset.maxReorderFrames ?? 16
    guard (0...16).contains(reorderDepth) else {
      throw MediaError(.unsupportedMedia, stage: "plan", "Unsupported decoded reorder window")
    }
    let orientedBytes =
      asset.rotation == nil || asset.rotation == DisplayRotation.none
      ? 0
      : PixelContract.storageBytes(
        width: asset.displayWidth, height: asset.displayHeight, bitDepth: asset.effectiveBitDepth)
    let estimate =
      sourceBytes * (reorderDepth + 1) + orientedBytes + outputBytes + scratch + 24 * 1024 * 1024
    guard estimate <= request.memoryBudgetBytes else {
      throw MediaError(
        .resourceLimit, stage: "plan",
        "Budget cannot fit the declared decoded reorder window (estimated \(estimate) bytes)")
    }
    return PreparedJob(
      request: request, asset: asset, geometry: geometry,
      requestDigest: SHA256.hash(data: try request.normalizedData()).map {
        String(format: "%02x", $0)
      }.joined(),
      estimatedWorkingSetBytes: estimate, fingerprint: try SourceFingerprint.read(request.source),
      engineID: engineID)
  }
}
