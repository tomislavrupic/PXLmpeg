import Darwin
import Foundation

/// Only compiler-returned temporary bundles enter this owner. No host cache is read.
final class CompiledModelArtifacts: @unchecked Sendable {
  let imageURL: URL
  let textURL: URL
  init(imageSource: URL, textSource: URL, compiler: (URL) throws -> URL) throws {
    var owned: [URL] = []
    do {
      for source in [imageSource, textSource] {
        try Task.checkCancellation()
        let output = try compiler(source)
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        guard output.isFileURL, output.pathExtension == "mlmodelc",
          output.resolvingSymlinksInPath().path.hasPrefix(temporary), !owned.contains(output)
        else { throw analysisError("Compiler output must be a distinct temporary model bundle") }
        owned.append(output)
      }
      try Task.checkCancellation()
    } catch {
      for url in owned { try? FileManager.default.removeItem(at: url) }
      throw error
    }
    imageURL = owned[0]
    textURL = owned[1]
  }
  deinit { cleanupOwnedFiles() }
  fileprivate func cleanupOwnedFiles() {
    try? FileManager.default.removeItem(at: imageURL)
    try? FileManager.default.removeItem(at: textURL)
  }
}

/// Serializes compilation and reuses at most two identities in one process.
/// Active ModelPairs retain leases after eviction. Normal exit cleans pool-owned files.
final class CompiledModelPool: @unchecked Sendable {
  static let shared: CompiledModelPool = {
    let pool = CompiledModelPool(capacity: 2)
    atexit { CompiledModelPool.shared.shutdown() }
    return pool
  }()
  private let lock = NSLock()
  private let capacity: Int
  private var entries: [String: CompiledModelArtifacts] = [:]
  private var order: [String] = []
  init(capacity: Int) { self.capacity = max(1, capacity) }
  func lease(
    identity: String, build: () throws -> CompiledModelArtifacts,
    validate: (CompiledModelArtifacts) throws -> Void = { _ in }
  ) throws -> CompiledModelArtifacts {
    try Task.checkCancellation()
    lock.lock()
    defer { lock.unlock() }
    try Task.checkCancellation()
    if let entry = entries[identity],
      FileManager.default.fileExists(atPath: entry.imageURL.path),
      FileManager.default.fileExists(atPath: entry.textURL.path)
    {
      do { try validate(entry) } catch {
        entries.removeValue(forKey: identity)
        order.removeAll { $0 == identity }
        throw error
      }
      order.removeAll { $0 == identity }
      order.append(identity)
      return entry
    }
    entries.removeValue(forKey: identity)
    order.removeAll { $0 == identity }
    let entry = try build()
    try validate(entry)
    try Task.checkCancellation()
    while order.count >= capacity { entries.removeValue(forKey: order.removeFirst()) }
    entries[identity] = entry
    order.append(identity)
    return entry
  }
  /// Only for process exit: never wait for a compiler that may be stalled.
  func shutdown() {
    guard lock.try() else { return }
    let owned = Array(entries.values)
    entries.removeAll()
    order.removeAll()
    lock.unlock()
    for artifact in owned { artifact.cleanupOwnedFiles() }
  }
  func removeAll() {
    lock.lock()
    defer { lock.unlock() }
    entries.removeAll()
    order.removeAll()
  }
}
