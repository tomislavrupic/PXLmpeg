import CoreVideo
import Metal
import PXLMedia

package final class TextureLease {
  package let texture: MTLTexture
  private let wrapper: CVMetalTexture
  private let pixel: CVPixelBuffer
  package init(pixel: CVPixelBuffer, plane: Int, cache: CVMetalTextureCache) throws {
    guard
      [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
      ].contains(CVPixelBufferGetPixelFormatType(pixel)), (0..<2).contains(plane)
    else {
      throw MediaError(.gpuFailure, stage: "texture", "Expected NV12/P010 plane")
    }
    var mapped: CVMetalTexture?
    let ten =
      CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    let format: MTLPixelFormat =
      ten ? (plane == 0 ? .r16Unorm : .rg16Unorm) : (plane == 0 ? .r8Unorm : .rg8Unorm)
    let status = CVMetalTextureCacheCreateTextureFromImage(
      nil, cache, pixel, nil, format,
      CVPixelBufferGetWidthOfPlane(pixel, plane), CVPixelBufferGetHeightOfPlane(pixel, plane),
      plane, &mapped)
    guard status == kCVReturnSuccess, let mapped, let texture = CVMetalTextureGetTexture(mapped)
    else {
      throw MediaError(
        .gpuFailure, stage: "texture", "Cannot map NV12 plane", underlyingCode: Int(status))
    }
    self.pixel = pixel
    wrapper = mapped
    self.texture = texture
  }
}
