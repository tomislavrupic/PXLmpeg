import CryptoKit
import Darwin
import Foundation

func regularFile(_ url: URL) throws -> FileHandle {
  guard url.isFileURL else { throw analysisError("Expected a local regular file") }
  let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
  guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  var info = stat()
  guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
    close(fd)
    throw analysisError("Input must be a regular file")
  }
  return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
}
func boundedData(at url: URL, maximum: Int) throws -> Data {
  guard url.isFileURL else { throw analysisError("Expected a local file") }
  let file = try regularFile(url)
  defer { try? file.close() }
  let data = try file.read(upToCount: maximum + 1) ?? Data()
  guard data.count <= maximum else { throw analysisError("File exceeds supported size") }
  return data
}
func contentDigest(_ url: URL) throws -> String {
  guard url.isFileURL else { throw analysisError("Expected a local file") }
  let file = try regularFile(url)
  defer { try? file.close() }
  var digest = SHA256()
  while true {
    try Task.checkCancellation()
    let data = try file.read(upToCount: 1_048_576) ?? Data()
    if data.isEmpty { break }
    digest.update(data: data)
  }
  return digest.finalize().map { String(format: "%02x", $0) }.joined()
}
func milliseconds(since start: ContinuousClock.Instant) -> Double {
  let c = start.duration(to: ContinuousClock.now).components
  return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
}

// Keep the parent directory open, write a unique 0600 temporary and atomically
// publish with RENAME_EXCL. Foundation disallows atomic + withoutOverwriting.
func publishNew(_ data: Data, to destination: URL) throws {
  let parent = destination.deletingLastPathComponent()
  let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  defer { close(directory) }
  let temporary = ".pxl-semantic-\(UUID().uuidString).tmp"
  let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
  guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  defer { unlinkat(directory, temporary, 0) }
  let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  try file.write(contentsOf: data)
  try file.synchronize()
  try file.close()
  try Task.checkCancellation()
  guard
    renameatx_np(
      directory, temporary, directory, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0
  else {
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
