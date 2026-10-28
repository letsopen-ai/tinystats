import AppKit
import CoreFoundation

/// Normal Quit waits briefly for a checkpoint, then replies once even if filesystem I/O stalls.
@MainActor final class HistoryQuitCoordinator {
  private let reply: @MainActor @Sendable () -> Void
  private var deadline: Timer?
  private(set) var waiting = false
  private(set) var replied = false
  init(reply: @escaping @MainActor @Sendable () -> Void) { self.reply = reply }
  func begin(flush: (@escaping @MainActor @Sendable () -> Void) -> Void) {
    guard !waiting, !replied else { return }
    waiting = true
    // terminateLater pumps a nested AppKit loop; the main dispatch queue can be suspended.
    // This is one shutdown deadline, never a recurring sampler or view timer.
    let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.finish() }
    }
    deadline = timer
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.add(timer, forMode: .modalPanel)
    flush { [weak self] in self?.finish() }
  }
  nonisolated static func deliver(_ action: @escaping @MainActor @Sendable () -> Void) {
    RunLoop.main.perform(inModes: [.common, .modalPanel]) {
      // This block belongs to the documented main run loop, including its nested modal mode.
      MainActor.assumeIsolated { action() }
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
  }
  private func finish() {
    guard waiting else { return }
    waiting = false
    replied = true
    deadline?.invalidate()
    deadline = nil
    reply()
  }
}
