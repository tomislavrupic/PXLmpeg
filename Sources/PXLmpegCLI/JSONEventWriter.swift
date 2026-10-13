import Darwin
import Foundation
import PXLMedia

struct JSONEvent<Payload: Encodable>: Encodable {
  let schemaVersion = 1
  let jobID: UUID?
  let type: String
  let payload: Payload
}
// Main-actor confined. Nonblocking stdout bounds slow-consumer waits and prevents
// SIGPIPE from killing the process before the media job can clean up.
@MainActor final class JSONEventWriter {
  private let previousFlags: Int32
  init() {
    signal(SIGPIPE, SIG_IGN)
    previousFlags = fcntl(STDOUT_FILENO, F_GETFL)
    if previousFlags >= 0 { _ = fcntl(STDOUT_FILENO, F_SETFL, previousFlags | O_NONBLOCK) }
  }
  func emit<T: Encodable>(_ type: String, jobID: UUID? = nil, payload: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(JSONEvent(jobID: jobID, type: type, payload: payload))
    data.append(10)
    guard data.count <= 1024 * 1024 else {
      throw MediaError(.resourceLimit, stage: "stdout", "Event exceeds 1 MiB")
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    try data.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let n = Darwin.write(
          STDOUT_FILENO, raw.baseAddress!.advanced(by: offset), raw.count - offset)
        if n > 0 {
          offset += n
          continue
        }
        if n < 0, errno == EINTR { continue }
        if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
          guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw MediaError(.cancelled, stage: "stdout", "Output consumer stalled")
          }
          var fd = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
          _ = poll(&fd, 1, 50)
          continue
        }
        throw MediaError(
          .cancelled, stage: "stdout", "Output consumer closed", underlyingCode: Int(errno))
      }
    }
  }
}
