import CoreVideo
import Metal
import PXLAppleMedia
import PXLMedia

private struct OrientationParameters {
  var quarterTurns: UInt32, plane: UInt32, width: UInt32, height: UInt32, quantize10: UInt32
}
package final class PlaneOrienter {
  private let context: MetalContext, state: MTLComputePipelineState
  private let cache: CVMetalTextureCache
  package init(context: MetalContext) throws {
    self.context = context
    guard let function = context.library.makeFunction(name: "orient_plane") else {
      throw MediaError(.gpuFailure, stage: "orient", "Missing orientation kernel")
    }
    state = try context.device.makeComputePipelineState(function: function)
    var result: CVMetalTextureCache?
    guard CVMetalTextureCacheCreate(nil, nil, context.device, nil, &result) == kCVReturnSuccess,
      let result
    else {
      throw MediaError(.gpuFailure, stage: "orient", "Cannot create orientation texture cache")
    }
    cache = result
  }
  // Canonical left-chroma output. GPU owns the source and destination until completion.
  package func orient(_ input: MediaLease, into output: MediaLease, rotation: DisplayRotation)
    throws
  {
    let width = CVPixelBufferGetWidth(input.pixel)
    let height = CVPixelBufferGetHeight(input.pixel)
    guard input.pixel !== output.pixel,
      CVPixelBufferGetPixelFormatType(input.pixel) == CVPixelBufferGetPixelFormatType(output.pixel),
      CVPixelBufferGetWidth(output.pixel) == (rotation.swapsAxes ? height : width),
      CVPixelBufferGetHeight(output.pixel) == (rotation.swapsAxes ? width : height),
      let command = context.commandQueue.makeCommandBuffer()
    else {
      throw MediaError(.gpuFailure, stage: "orient", "Invalid orientation surfaces or command")
    }
    var mappings: [TextureLease] = []
    for plane in 0..<2 {
      let source = try TextureLease(pixel: input.pixel, plane: plane, cache: cache)
      let target = try TextureLease(pixel: output.pixel, plane: plane, cache: cache)
      mappings += [source, target]
      guard let encoder = command.makeComputeCommandEncoder() else {
        throw MediaError(.gpuFailure, stage: "orient", "Cannot create compute encoder")
      }
      encoder.setComputePipelineState(state)
      encoder.setTexture(source.texture, index: 0)
      encoder.setTexture(target.texture, index: 1)
      var p = OrientationParameters(
        quarterTurns: UInt32(rotation.rawValue / 90), plane: UInt32(plane), width: UInt32(width),
        height: UInt32(height),
        quantize10: CVPixelBufferGetPixelFormatType(output.pixel)
          == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ? 1 : 0)
      encoder.setBytes(&p, length: MemoryLayout<OrientationParameters>.stride, index: 0)
      let w = state.threadExecutionWidth
      let h = max(1, min(8, state.maxTotalThreadsPerThreadgroup / w))
      encoder.dispatchThreads(
        MTLSize(width: target.texture.width, height: target.texture.height, depth: 1),
        threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
      encoder.endEncoding()
    }
    command.commit()
    command.waitUntilCompleted()
    withExtendedLifetime((input, output, mappings)) {}
    guard command.status == .completed else {
      throw MediaError(
        .gpuFailure, stage: "orient", "GPU orientation failed: \(String(describing: command.error))"
      )
    }
    PixelContract.propagate(from: input.pixel, to: output.pixel)
  }
}
