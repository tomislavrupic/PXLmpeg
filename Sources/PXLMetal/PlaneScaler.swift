import CoreVideo
import Metal
import PXLAppleMedia
import PXLMedia

private struct ScaleAxis {
  var axis: UInt32
  var offset: Float
  var quantize10: UInt32
  var padding: UInt32 = 0
}
package final class PlaneScaler {
  private let context: MetalContext
  private let state: MTLComputePipelineState
  private let cache: CVMetalTextureCache
  package init(context: MetalContext) throws {
    self.context = context
    guard let function = context.library.makeFunction(name: "scale_plane") else {
      throw MediaError(.gpuFailure, stage: "scale", "Missing scale kernel")
    }
    state = try context.device.makeComputePipelineState(function: function)
    var c: CVMetalTextureCache?
    let status = CVMetalTextureCacheCreate(nil, nil, context.device, nil, &c)
    guard status == kCVReturnSuccess, let c else {
      throw MediaError(.gpuFailure, stage: "scale", "Cannot create texture cache")
    }
    cache = c
  }
  // Dedicated worker only. Local strong leases keep buffers/wrappers alive until
  // waitUntilCompleted returns. No CPU mapping/readback on the processing path.
  package func scale(_ input: MediaLease, into output: MediaLease, budget: MediaBudget) throws {
    guard
      CVPixelBufferGetPixelFormatType(input.pixel) == CVPixelBufferGetPixelFormatType(output.pixel)
    else {
      throw failure("Scale requires matching bit depths")
    }
    guard let command = context.commandQueue.makeCommandBuffer() else {
      throw failure("Cannot create command buffer")
    }
    var mappings: [TextureLease] = []
    var scratch: [MTLTexture] = []
    var reservations: [Reservation] = []
    for plane in 0..<2 {
      let src = try TextureLease(pixel: input.pixel, plane: plane, cache: cache)
      let dst = try TextureLease(pixel: output.pixel, plane: plane, cache: cache)
      mappings += [src, dst]
      if src.texture.width == dst.texture.width && src.texture.height == dst.texture.height {
        guard let blit = command.makeBlitCommandEncoder() else {
          throw failure("Cannot create blit encoder")
        }
        blit.copy(from: src.texture, to: dst.texture)
        blit.endEncoding()
        continue
      }
      let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rg32Float, width: dst.texture.width, height: src.texture.height,
        mipmapped: false)
      desc.storageMode = .private
      desc.usage = [.shaderRead, .shaderWrite]
      // Metal's device-reported size includes alignment; reserve before allocation.
      let bytes = context.device.heapTextureSizeAndAlign(descriptor: desc).size
      let reservation = try budget.reserve(bytes: bytes, kind: .bytes)
      guard let middle = context.device.makeTexture(descriptor: desc) else {
        throw failure("Cannot allocate intermediate texture")
      }
      scratch.append(middle)
      reservations.append(reservation)
      try dispatch(command, src.texture, middle, axis: 0, offset: plane == 0 ? 0.5 : 0.25)
      try dispatch(
        command, middle, dst.texture, axis: 1, offset: 0.5,
        quantize10: CVPixelBufferGetPixelFormatType(output.pixel)
          == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
    }
    command.commit()
    command.waitUntilCompleted()
    withExtendedLifetime((input, output, mappings, scratch, reservations)) {}
    guard command.status == .completed else {
      throw failure("GPU command failed: \(String(describing: command.error))")
    }
    PixelContract.propagate(from: input.pixel, to: output.pixel)
  }
  private func dispatch(
    _ command: MTLCommandBuffer, _ source: MTLTexture, _ destination: MTLTexture, axis: UInt32,
    offset: Float, quantize10: Bool = false
  ) throws {
    guard let encoder = command.makeComputeCommandEncoder() else {
      throw failure("Cannot create compute encoder")
    }
    encoder.setComputePipelineState(state)
    encoder.setTexture(source, index: 0)
    encoder.setTexture(destination, index: 1)
    var params = ScaleAxis(axis: axis, offset: offset, quantize10: quantize10 ? 1 : 0)
    encoder.setBytes(&params, length: MemoryLayout<ScaleAxis>.stride, index: 0)
    let w = state.threadExecutionWidth
    let h = max(1, min(8, state.maxTotalThreadsPerThreadgroup / w))
    encoder.dispatchThreads(
      MTLSize(width: destination.width, height: destination.height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    encoder.endEncoding()
  }
  private func failure(_ text: String) -> MediaError {
    MediaError(.gpuFailure, stage: "scale", text)
  }
}
