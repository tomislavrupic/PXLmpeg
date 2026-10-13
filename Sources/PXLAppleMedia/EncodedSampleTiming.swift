import CoreMedia
import PXLMedia

extension EncodedSample {
  // AVAssetReader may carry a container edit through an output PTS override.
  // Materialize both mapped PTS and DTS before remux: AVAssetWriter must not see
  // a media-time DTS together with a movie-time PTS. Payload/attachments are shared.
  package func mappingOutputVideoTiming() throws -> EncodedSample {
    let mappedDTS = CMSampleBufferGetOutputDecodeTimeStamp(buffer)
    guard
      CMSampleBufferGetPresentationTimeStamp(buffer) != pts
        || CMSampleBufferGetDecodeTimeStamp(buffer) != mappedDTS
        || CMSampleBufferGetDuration(buffer) != duration
    else { return self }
    var timing = CMSampleTimingInfo(
      duration: duration, presentationTimeStamp: pts, decodeTimeStamp: mappedDTS)
    var copy: CMSampleBuffer?
    try checkVT(
      CMSampleBufferCreateCopyWithNewTiming(
        allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleBufferOut: &copy), stage: "remux-timing")
    guard let copy else {
      throw MediaError(.ioFailure, stage: "remux-timing", "Missing timed sample")
    }
    return EncodedSample(buffer: copy, sequence: sequence)
  }
}
