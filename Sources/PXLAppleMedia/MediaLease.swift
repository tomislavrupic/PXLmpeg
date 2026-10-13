import CoreMedia
import CoreVideo

// Confined to the worker. Native operations retain this lease through completion.
package final class MediaLease {
  package let pixel: CVPixelBuffer
  package let pts: CMTime
  package let duration: CMTime
  private let reservation: Reservation
  package init(pixel: CVPixelBuffer, pts: CMTime, duration: CMTime, reservation: Reservation) {
    self.pixel = pixel
    self.pts = pts
    self.duration = duration
    self.reservation = reservation
  }
  package static func byteCount(_ pixel: CVPixelBuffer) -> Int {
    max(
      CVPixelBufferGetDataSize(pixel),
      (0..<CVPixelBufferGetPlaneCount(pixel)).reduce(0) {
        $0 + CVPixelBufferGetBytesPerRowOfPlane(pixel, $1)
          * CVPixelBufferGetHeightOfPlane(pixel, $1)
      })
  }
}
