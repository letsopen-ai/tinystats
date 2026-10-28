import AppKit
import Foundation
import Testing

@testable import TinyStats
@testable import TinyStatsCore

private let cycleDomain = "TinyStats.CycleProbe.9ED9D88E-6E36-4F8D-9BD1-B56019D5F160"
private let cycleArguments = ["TinyStats", "--preview-popover", "--preview-popover-cycles", "2"]
private func probeConfiguration() -> PopoverCycleProbe.Configuration {
  .init(count: 2, baselineSeconds: 30, openSeconds: 6, closedSeconds: 10)
}

@Test func cycleProbeRequiresExplicitBoundedIsolatedLaunch() {
  let expected = probeConfiguration()
  #expect(
    PopoverCycleProbe.Configuration.parse(arguments: cycleArguments, preferencesDomain: cycleDomain)
      == expected)
  for domain in [nil, "", "com.niechen.tinystats", "TinyStats.CycleProbe.invalid"] as [String?] {
    #expect(
      PopoverCycleProbe.Configuration.parse(arguments: cycleArguments, preferencesDomain: domain)
        == nil)
  }
  for arguments in [
    ["--preview-popover-cycles", "2"],
    ["--preview-popover", "--preview-popover-cycles"],
    ["--preview-popover", "--preview-popover-cycles", "0"],
    ["--preview-popover", "--preview-popover-cycles", "51"],
    ["--preview-popover", "--preview-popover-cycles", "999999999999999999999"],
    cycleArguments + ["--preview-popover-cycles", "3"],
    cycleArguments + ["--preview-popover"],
  ] {
    #expect(
      PopoverCycleProbe.Configuration.parse(arguments: arguments, preferencesDomain: cycleDomain)
        == nil)
  }
  for flag in [
    "--preview", "--preview-history", "--preview-settings", "--preview-popover-close-after",
    "--preview-history-close-after", "--preview-quit-after",
  ] {
    #expect(
      PopoverCycleProbe.Configuration.parse(
        arguments: cycleArguments + [flag, "10"], preferencesDomain: cycleDomain) == nil)
  }
  for (flag, low, high) in [
    ("--cycle-baseline-seconds", 20.0, 120.0), ("--cycle-open-seconds", 4.0, 60.0),
    ("--cycle-closed-seconds", 4.0, 120.0),
    ("--cycle-tail-seconds", 15.0, 120.0),
  ] {
    for value in ["nan", "inf", "-inf", "", String(low - 1), String(high + 1)] {
      #expect(
        PopoverCycleProbe.Configuration.parse(
          arguments: cycleArguments + [flag, value], preferencesDomain: cycleDomain) == nil)
    }
    for value in [low, high] {
      #expect(
        PopoverCycleProbe.Configuration.parse(
          arguments: cycleArguments + [flag, String(value)], preferencesDomain: cycleDomain) != nil)
    }
    #expect(
      PopoverCycleProbe.Configuration.parse(
        arguments: cycleArguments + [flag], preferencesDomain: cycleDomain) == nil)
    #expect(
      PopoverCycleProbe.Configuration.parse(
        arguments: cycleArguments + [flag, String(low), flag, String(low)],
        preferencesDomain: cycleDomain) == nil)
  }
}

@Test func cycleProbeRejectsInternetEventsAndPersistentProfiles() {
  let configuration = probeConfiguration()
  var baseline = Settings()
  baseline.persistHistory = false
  #expect(configuration.permits(baseline))
  let changes: [(inout Settings) -> Void] = [
    { $0.weather.enabled = true }, { $0.calendarEvents = true },
    { $0.connectivityChecks = true }, { $0.publicIPChecks = true }, { $0.persistHistory = true },
  ]
  for change in changes {
    var settings = baseline
    change(&settings)
    #expect(!configuration.permits(settings))
  }
}

@Test func cycleProbeUsesActualTransitionsAndSettlesWithoutAddingTimersOrRepeatedActions() {
  var probe = PopoverCycleProbe(configuration: probeConfiguration())
  #expect(probe.tick(at: 0)?.event?.kind == .baseline)
  #expect(probe.tick(at: 29) == nil)
  #expect(probe.tick(at: 30)?.command == .show)
  #expect(probe.tick(at: 50) == nil)  // A delayed real show cannot be credited as already open.
  #expect(probe.didShow(true, at: 51)?.cycle == 1)
  #expect(probe.tick(at: 56) == nil)
  #expect(probe.tick(at: 57)?.command == .close)
  #expect(probe.tick(at: 58) == nil)
  #expect(probe.didClose(at: 59)?.kind == .closed)
  #expect(probe.tick(at: 68) == nil)
  let first = probe.tick(at: 69)
  #expect(
    first?.event?.kind == .settled && first?.event?.cycle == 1 && first?.event?.complete == false)
  #expect(first?.command == .show)
  #expect(probe.didShow(true, at: 70)?.cycle == 2)
  #expect(probe.tick(at: 76)?.command == .close)
  #expect(probe.didClose(at: 77)?.cycle == 2)
  #expect(probe.tick(at: 86) == nil)
  let final = probe.tick(at: 87)
  #expect(
    final?.event?.kind == .settled && final?.event?.cycle == 2 && final?.event?.complete == false)
  #expect(final?.command == nil)
  #expect(probe.tick(at: 146) == nil)
  let completed = probe.tick(at: 147)
  #expect(completed?.event?.kind == .complete && completed?.event?.complete == true)
  #expect(probe.tick(at: 1000) == nil)
}

@Test func cycleProbeFailedOrInterruptedPresentationNeverCountsAsACompleteCycle() {
  for failure in ["failed-show", "early-close", "duplicate-show", "duplicate-close"] {
    var probe = PopoverCycleProbe(configuration: probeConfiguration())
    _ = probe.tick(at: 0)
    _ = probe.tick(at: 30)
    if failure == "failed-show" {
      #expect(probe.didShow(false, at: 31)?.reason == .showFailed)
    } else {
      _ = probe.didShow(true, at: 31)
      if failure == "early-close" {
        #expect(probe.didClose(at: 32)?.reason == .unexpectedClose)
      } else if failure == "duplicate-show" {
        #expect(probe.didShow(true, at: 32)?.reason == .unexpectedShow)
      } else {
        _ = probe.tick(at: 37)
        _ = probe.didClose(at: 38)
        #expect(probe.didClose(at: 39)?.reason == .unexpectedClose)
      }
    }
    #expect(probe.tick(at: 100) == nil)
    #expect(probe.didShow(true, at: 101) == nil)
    #expect(probe.didClose(at: 102) == nil)
  }
}

@Test func cycleProbeRejectsClockRegressionAndEmitsFiniteBoundedJSON() throws {
  for invalid in [Double.nan, .infinity, -.infinity, -1, 29] {
    var probe = PopoverCycleProbe(configuration: probeConfiguration())
    _ = probe.tick(at: 30)
    let event = try #require(probe.tick(at: invalid)?.event)
    #expect(event.kind == .failed && event.reason == .clock && !event.complete)
    let prefix = "TinyStats:cycle="
    #expect(event.line.hasPrefix(prefix) && event.line.utf8.count < 256)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(event.line.dropFirst(prefix.count).utf8))
        as? [String: Any])
    #expect(object["event"] as? String == "failed")
    if !invalid.isFinite { #expect(object["uptime"] is NSNull) }
    #expect(probe.tick(at: 100) == nil)
  }
}

@Test func cycleProbeExternalInterruptionInvalidatesBaselineShownAndClosedPhases() {
  for stage in 0...2 {
    var probe = PopoverCycleProbe(configuration: probeConfiguration())
    _ = probe.tick(at: 0)
    if stage > 0 {
      _ = probe.tick(at: 30)
      _ = probe.didShow(true, at: 31)
    }
    if stage > 1 {
      _ = probe.tick(at: 37)
      _ = probe.didClose(at: 38)
    }
    let event = probe.interrupt(at: 40)
    #expect(event?.kind == .failed && event?.reason == .interrupted && event?.complete == false)
    #expect(probe.tick(at: 100) == nil)
    #expect(probe.interrupt(at: 101) == nil)
  }
}

@Test @MainActor func cycleProbeAllReadingsActionInvalidatesAndFinalMarkerRequiresClosedWindow()
  throws
{
  var probe = PopoverCycleProbe(configuration: probeConfiguration())
  _ = probe.tick(at: 0)
  _ = probe.tick(at: 30)
  _ = probe.didShow(true, at: 31)
  let controller = DetailController()
  controller.selected = .network
  var failure: PopoverCycleProbe.Event?
  controller.onViewModeChange = { failure = probe.interrupt(at: 32) }
  let button = try #require(
    controller.view.subviews.compactMap { $0 as? NSButton }.first { $0.title == "All readings" })
  #expect(
    NSApplication.shared.sendAction(try #require(button.action), to: button.target, from: button))
  #expect(controller.showsAllReadings && failure?.reason == .interrupted)
  #expect(probe.tick(at: 1000) == nil)
  var config = probeConfiguration()
  config.count = 1
  var tail = PopoverCycleProbe(configuration: config)
  _ = tail.tick(at: 0)
  _ = tail.tick(at: 30)
  _ = tail.didShow(true, at: 31)
  _ = tail.tick(at: 37)
  _ = tail.didClose(at: 38)
  #expect(tail.tick(at: 48)?.event?.kind == .settled)
  let invalid = tail.tick(at: 108, shown: true)
  #expect(invalid?.event?.reason == .unexpectedShow && invalid?.event?.complete == false)
}
