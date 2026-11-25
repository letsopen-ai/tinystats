import AppKit
import CoreFoundation
import HostedTestEvidence
import Testing

@testable import TinyStats

@MainActor private final class HistoryModalTestState {
  var inside = true
  var replies = 0
  var delivered = false
}

@MainActor func runHistoryTerminationMode(until done: () -> Bool) {
  TinyStatsHostedTestEvidenceAppKit()
  var timedOut = false
  let fallback = Timer(timeInterval: 3, repeats: false) { _ in
    MainActor.assumeIsolated {
      FileHandle.standardError.write(
        Data("Test host evidence: history fallback stopping main run loop\n".utf8))
      timedOut = true
      CFRunLoopStop(CFRunLoopGetMain())
    }
  }
  RunLoop.main.add(fallback, forMode: .modalPanel)
  defer {
    fallback.invalidate()
    FileHandle.standardError.write(
      Data(
        "Test host evidence: history loop returned; fallback fired=\(timedOut), done=\(done())\n"
          .utf8))
  }
  // NSApplication.terminate enters this kind of nested event loop after terminateLater.
  let limit = Date().addingTimeInterval(3.5)
  while !done(), !timedOut, Date() < limit {
    _ = RunLoop.main.run(mode: .modalPanel, before: limit)
  }
}

@Test @MainActor func historyQuitDeadlineWorksInsideAppKitTerminationMode() {
  _ = NSApplication.shared
  let state = HistoryModalTestState()
  let quit = HistoryQuitCoordinator {
    state.replies += 1
    if state.inside { CFRunLoopStop(CFRunLoopGetMain()) }
  }
  quit.begin { _ in }
  runHistoryTerminationMode { quit.replied }
  state.inside = false
  #expect(quit.replied && state.replies == 1)
}

@Test @MainActor func historyQuitWorkerCompletionWorksInsideAppKitTerminationMode() {
  _ = NSApplication.shared
  let state = HistoryModalTestState()
  let worker = MonitorWorker(receive: { _, _, _ in })
  worker.finishHistory {
    state.delivered = true
    if state.inside { CFRunLoopStop(CFRunLoopGetMain()) }
  }
  runHistoryTerminationMode { state.delivered }
  state.inside = false
  #expect(state.delivered)
}
