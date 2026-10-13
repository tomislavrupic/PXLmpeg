import Darwin
import Foundation
import PXLMedia

struct SourceFingerprint: Codable, Sendable, Equatable {
  let device: Int32, inode: UInt64, size: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64
  static func read(_ url: URL) throws -> Self {
    var st = stat()
    guard url.isFileURL, fstatat(AT_FDCWD, url.path, &st, 0) == 0, (st.st_mode & S_IFMT) == S_IFREG
    else {
      throw MediaError(
        .ioFailure, stage: "source", "Source must be a readable regular file",
        underlyingCode: Int(errno))
    }
    return Self(
      device: st.st_dev, inode: st.st_ino, size: st.st_size,
      modifiedSeconds: Int64(st.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(st.st_mtimespec.tv_nsec))
  }
}
final class OutputTransaction {
  let temporaryURL: URL
  private let parentFD: Int32, temporaryFD: Int32
  private let temporaryName: String, destinationName: String, mediaName: String
  private var published = false, cleaned = false
  static func validate(destination: URL, source: URL, container: OutputContainer = .mov) throws {
    guard destination.isFileURL, destination.pathExtension.lowercased() == container.rawValue,
      destination.resolvingSymlinksInPath() != source.resolvingSymlinksInPath()
    else {
      throw MediaError(
        .invalidRequest, stage: "destination",
        "Use a new .\(container.rawValue) destination distinct from the source"
      )
    }
    var info = stat()
    if lstat(destination.path, &info) == 0 {
      throw MediaError(.destinationExists, stage: "destination", "Destination already exists")
    }
    guard errno == ENOENT else {
      throw MediaError(
        .ioFailure, stage: "destination", "Cannot inspect destination", underlyingCode: Int(errno))
    }
  }
  init(destination: URL, source: URL, jobID: UUID, container: OutputContainer = .mov) throws {
    try Self.validate(destination: destination, source: source, container: container)
    let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
    let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else {
      throw MediaError(
        .ioFailure, stage: "destination", "Cannot open destination directory",
        underlyingCode: Int(errno))
    }
    let name = ".pxlmpeg-\(jobID.uuidString)-\(UUID().uuidString)"
    guard mkdirat(fd, name, 0o700) == 0 else {
      let e = errno
      close(fd)
      throw MediaError(
        .ioFailure, stage: "destination", "Cannot reserve private output directory",
        underlyingCode: Int(e))
    }
    let tempFD = openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard tempFD >= 0 else {
      let e = errno
      unlinkat(fd, name, AT_REMOVEDIR)
      close(fd)
      throw MediaError(
        .ioFailure, stage: "destination", "Cannot open reserved directory", underlyingCode: Int(e))
    }
    parentFD = fd
    temporaryFD = tempFD
    temporaryName = name
    destinationName = destination.lastPathComponent
    mediaName = "media.\(container.rawValue)"
    temporaryURL = parent.appendingPathComponent(name, isDirectory: true).appendingPathComponent(
      mediaName)
  }
  func commit() throws {
    guard !published, !cleaned else {
      throw MediaError(.invalidRequest, stage: "commit", "Output transaction is already finished")
    }
    guard
      renameatx_np(temporaryFD, mediaName, parentFD, destinationName, UInt32(RENAME_EXCL)) == 0
    else {
      throw MediaError(
        errno == EEXIST ? .destinationExists : .ioFailure, stage: "commit",
        "Cannot publish without replacing an existing file", underlyingCode: Int(errno))
    }
    published = true
    cleanup()
  }
  func abort() { cleanup() }
  private func cleanup() {
    guard !cleaned else { return }
    if !published {
      _ = unlinkat(temporaryFD, mediaName, 0)
      removeWriterScratch()
    }
    _ = unlinkat(parentFD, temporaryName, AT_REMOVEDIR)
    cleaned = true
  }
  // AVAssetWriter's safe-save file can survive cancelWriting momentarily.
  // Confine cleanup to regular writer-owned names under the reserved descriptor;
  // leave unknown entries and symlinks alone, even if that keeps the directory.
  private func removeWriterScratch() {
    let fd = dup(temporaryFD)
    guard fd >= 0 else { return }
    guard let directory = fdopendir(fd) else {
      close(fd)
      return
    }
    defer { closedir(directory) }
    while let entry = readdir(directory) {
      let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
          String(cString: $0)
        }
      }
      guard name.hasPrefix(mediaName + ".sb-") else { continue }
      var info = stat()
      guard fstatat(temporaryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
        (info.st_mode & S_IFMT) == S_IFREG
      else { continue }
      _ = unlinkat(temporaryFD, name, 0)
    }
  }
  deinit {
    cleanup()
    close(temporaryFD)
    close(parentFD)
  }
}
