import CoreMedia
import CoreVideo
import Foundation
import PXLMedia

package struct PixelContract {
  package let bitDepth: Int
  package let colourSpace: VideoColourSpace
  package let staticMetadata: [String: Data]
  package init(
    bitDepth: Int = 8, colourSpace: VideoColourSpace = .bt709, staticMetadata: [String: Data] = [:]
  ) {
    self.bitDepth = bitDepth
    self.colourSpace = colourSpace
    self.staticMetadata = staticMetadata
  }
  package var pixelFormat: OSType {
    bitDepth == 10
      ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
      : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
  }
  package var primaries: CFString {
    colourSpace == .bt709
      ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_ITU_R_2020
  }
  package var transfer: CFString {
    switch colourSpace {
    case .bt709: kCVImageBufferTransferFunction_ITU_R_709_2
    case .hlg2020: kCVImageBufferTransferFunction_ITU_R_2100_HLG
    case .pq2020: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
    }
  }
  package var matrix: CFString {
    colourSpace == .bt709
      ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_2020
  }
  package static func storageBytes(width: Int, height: Int, bitDepth: Int) -> Int {
    ((width + 255) / 256 * 256) * height * (bitDepth == 10 ? 4 : 2) + 16384
  }
  package static var metadataKeys: [(CFString, Int)] {
    [
      (kCVImageBufferMasteringDisplayColorVolumeKey, 24),
      (kCVImageBufferContentLightLevelInfoKey, 4),
      (kCVImageBufferAmbientViewingEnvironmentKey, 8),
    ]
  }
  package func retainsMetadata(from input: PixelContract) -> Bool {
    input.staticMetadata.allSatisfy { staticMetadata[$0.key] == $0.value }
  }
  package func apply(to pixel: CVPixelBuffer) {
    for (key, value) in [
      (kCVImageBufferColorPrimariesKey, primaries), (kCVImageBufferTransferFunctionKey, transfer),
      (kCVImageBufferYCbCrMatrixKey, matrix),
      (kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left),
      (kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Left),
    ] {
      CVBufferSetAttachment(pixel, key, value, .shouldPropagate)
    }
    for (key, _) in Self.metadataKeys {
      if let value = staticMetadata[key as String] {
        CVBufferSetAttachment(pixel, key, value as CFData, .shouldPropagate)
      } else {
        CVBufferRemoveAttachment(pixel, key)
      }
    }
  }
  // Geometry/dynamic metadata is not copied onto changed pixels. Static HDR and
  // ambient metadata is retained, clearing missing keys on the reused surface.
  package static func propagate(from input: CVPixelBuffer, to output: CVPixelBuffer) {
    let colourKeys = [
      kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
      kCVImageBufferYCbCrMatrixKey,
      kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocationBottomFieldKey,
    ]
    for key in colourKeys + metadataKeys.map(\.0) {
      if let value = CVBufferCopyAttachment(input, key, nil) {
        CVBufferSetAttachment(output, key, value, .shouldPropagate)
      } else {
        CVBufferRemoveAttachment(output, key)
      }
    }
  }
}
