import Foundation
import PXLMedia

// Narrow supported 1.0 record: single-layer profile 8 with an HLG/PQ base layer.
// RPU-present is configuration signalling, not a per-frame RPU integrity check.
package enum DolbyVisionConfiguration {
  package static func validate(_ data: Data, colourSpace: VideoColourSpace) throws -> Bool {
    let bytes = [UInt8](data)
    guard bytes.count == 24, bytes[0] == 1, bytes[1] == 0, bytes[2] >> 1 == 8,
      bytes[3] & 2 == 0, bytes[3] & 1 == 1,
      (bytes[4] >> 4 == 4 && colourSpace == .hlg2020)
        || (bytes[4] >> 4 == 1 && colourSpace == .pq2020)
    else {
      throw MediaError(
        .unsupportedMedia, stage: "inspect",
        "Only HLG/PQ-compatible single-layer Dolby Vision profile 8 configuration v1.0 is supported"
      )
    }
    return bytes[3] & 4 != 0
  }
}
