import AppKit
import Testing

@testable import TinyStats

@MainActor private final class HistoryModalTestState {
  var replies = 0
  var delivered = false
}

@MainActor func runHistoryTerminationMode(until done: () -> Bool) {
  var timedOut = false
  let fallback = Timer(timeInterval: 3, repeats: false) { _ in
    MainActor.assumeIsolated {
      timedOut = true
    }
  }
  RunLoop.main.add(fallback, forMode: .modalPanel)
  defer { fallback.invalidate() }
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
  }
  quit.begin { _ in }
  runHistoryTerminationMode { quit.replied }
  #expect(quit.replied && state.replies == 1)
}

@Test @MainActor func historyQuitWorkerCompletionWorksInsideAppKitTerminationMode() {
  _ = NSApplication.shared
  let state = HistoryModalTestState()
  let worker = MonitorWorker(receive: { _, _, _ in })
  worker.finishHistory {
    state.delivered = true
  }
  runHistoryTerminationMode { state.delivered }
  #expect(state.delivered)
}
