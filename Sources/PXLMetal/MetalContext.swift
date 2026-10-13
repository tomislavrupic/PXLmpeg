import Foundation
import Metal
import PXLMedia

// Confined to the job worker; Metal objects do not cross the public API.
package final class MetalContext {
  package let device: MTLDevice
  package let commandQueue: MTLCommandQueue
  package let library: MTLLibrary
  package init() throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory,
      let queue = device.makeCommandQueue()
    else {
      throw MediaError(
        .unsupportedHardware, stage: "metal", "An Apple Silicon Metal device is required")
    }
    let url = try Self.libraryURL()
    self.device = device
    self.commandQueue = queue
    self.library = try Self.loadLibrary(device: device, url: url)
  }
  // Do not invoke SwiftPM's fatal Bundle.module getter: packaging failures are errors.
  package static func libraryURL(candidates: [URL]? = nil) throws -> URL {
    var roots = [
      Bundle.main.bundleURL, Bundle.main.resourceURL,
      Bundle.main.executableURL?.deletingLastPathComponent(),
    ].compactMap { $0 }
    #if DEBUG
      // XCTest's executable lives in its .xctest bundle; the resources are alongside it.
      roots.append(
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
          .deletingLastPathComponent().deletingLastPathComponent()
          .appendingPathComponent(".build/debug"))
    #endif
    let urls =
      candidates
      ?? roots.map {
        $0.appendingPathComponent("PXLmpeg_PXLMetal.bundle/Resources/PXLKernels.metallib")
      }
    guard let url = urls.first(where: { FileManager.default.isReadableFile(atPath: $0.path) })
    else {
      throw MediaError(
        .gpuFailure, stage: "metal",
        "Bundled PXLKernels.metallib is missing; use Scripts/build.sh and ship PXLmpeg_PXLMetal.bundle beside the executable"
      )
    }
    return url
  }
  package static func loadLibrary(device: MTLDevice, url: URL) throws -> MTLLibrary {
    do { return try device.makeLibrary(URL: url) } catch {
      throw MediaError(.gpuFailure, stage: "metal", "Cannot load shader library: \(error)")
    }
  }
}
