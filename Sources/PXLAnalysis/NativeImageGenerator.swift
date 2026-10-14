import AVFoundation
import CoreGraphics
import PXLMedia

package struct NativeGeneratedImage: Sendable {
  package let image: CGImage
  package let actualTime: MediaTime
}

/// Immutable handle for one native request, with explicit asynchronous cancellation.
/// Never reuse a cancelled generator: its delayed cancel could otherwise cancel a newer request.
package final class NativeImageGenerator: @unchecked Sendable {
  private let generator: AVAssetImageGenerator
  package init(asset: AVAsset, maximumSize: CGSize) {
    generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.dynamicRangePolicy = .forceSDR
    generator.maximumSize = maximumSize
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
  }
  package func image(at time: CMTime) async throws -> NativeGeneratedImage {
    try await NativeImageRequest.run(
      timeout: .seconds(8),
      start: { [self] completion in
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
          _, image, actual, status, error in
          do {
            guard status == .succeeded, let image, actual.isNumeric else {
              throw error
                ?? MediaError(
                  .codecFailure, stage: "native-image", "Native image extraction failed")
            }
            completion(
              .success(
                NativeGeneratedImage(
                  image: image,
                  actualTime: try MediaTime(value: actual.value, timescale: actual.timescale))))
          } catch { completion(.failure(error)) }
        }
      }, cancel: { [self] in generator.cancelAllCGImageGeneration() })
  }
}
