import Darwin
import Foundation
import OSLog
import TinyStatsCore

struct NativeUpdateHelperSpawner: UpdateHelperSpawning {
  static let readyDescriptor: Int32 = 3

  func spawn(executable: URL, arguments: [String]) throws -> any UpdateHelperChild {
    var descriptors: [Int32] = [-1, -1]
    guard pipe(&descriptors) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    let reader = descriptors[0]
    // Keep the source distinct from the fixed child descriptor, even if stdin
    // was closed. All unrelated descriptors are close-on-exec by default.
    let writer = fcntl(descriptors[1], F_DUPFD_CLOEXEC, 4)
    close(descriptors[1])
    guard writer >= 0 else {
      close(reader)
      throw POSIXError(.EIO)
    }
    defer { close(writer) }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else {
      close(reader)
      throw POSIXError(.EIO)
    }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawnattr_init(&attributes) == 0 else {
      close(reader)
      throw POSIXError(.EIO)
    }
    defer { posix_spawnattr_destroy(&attributes) }
    let errors = [
      posix_spawn_file_actions_addclose(&actions, reader),
      posix_spawn_file_actions_adddup2(&actions, writer, Self.readyDescriptor),
      posix_spawn_file_actions_addclose(&actions, writer),
      posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
      posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0),
      posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0),
      posix_spawnattr_setflags(
        &attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)),
    ]
    guard errors.allSatisfy({ $0 == 0 }) else {
      close(reader)
      throw POSIXError(.EIO)
    }
    let strings = ([executable.path] + arguments).map { strdup($0) }
    defer { for string in strings { free(string) } }
    var argv = strings + [nil]
    var pid: pid_t = 0
    let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
    defer { for value in environment { free(value) } }
    var envp = environment + [nil]
    let result = posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &envp)
    guard result == 0 else {
      close(reader)
      throw POSIXError(.init(rawValue: result) ?? .EIO)
    }
    return NativeUpdateHelperChild(pid: pid, reader: reader)
  }

  static func signalReady() throws {
    let descriptor = readyDescriptor
    defer { close(descriptor) }
    // A timed-out parent may already have closed its end. Avoid SIGPIPE.
    guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else { throw POSIXError(.EIO) }
    var ready: UInt8 = 1
    guard Darwin.write(descriptor, &ready, 1) == 1 else { throw POSIXError(.EPIPE) }
  }
}

private final class NativeUpdateHelperChild: UpdateHelperChild, @unchecked Sendable {
  let pid: pid_t
  let reader: Int32
  init(pid: pid_t, reader: Int32) {
    self.pid = pid
    self.reader = reader
  }
  func waitUntilReady(timeout: TimeInterval) throws -> Bool {
    defer { close(reader) }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while true {
      let remaining = deadline - ProcessInfo.processInfo.systemUptime
      guard remaining > 0 else { return false }
      var descriptor = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
      let result = poll(&descriptor, 1, Int32(min(remaining * 1000, 10_000)))
      if result < 0 && errno == EINTR { continue }
      guard result > 0 else { return false }
      var ready: UInt8 = 0
      guard Darwin.read(reader, &ready, 1) == 1, ready == 1 else { return false }
      // Reap eventually, without tying helper lifetime to the parent's session.
      let childPID = pid
      DispatchQueue.global(qos: .utility).async {
        while waitpid(childPID, nil, 0) < 0 && errno == EINTR {}
      }
      return true
    }
  }
  func stop() {
    // No installer may outlive a failed handshake and later replace the app.
    _ = kill(pid, SIGKILL)
    while waitpid(pid, nil, 0) < 0 && errno == EINTR {}
  }
}

extension Logger {
  func updateFailure(_ context: String, error: any Error) {
    let value = error as NSError
    self.error(
      "\(context, privacy: .public): domain=\(value.domain, privacy: .public) code=\(value.code, privacy: .public) description=\(value.localizedDescription, privacy: .private)"
    )
  }
}
