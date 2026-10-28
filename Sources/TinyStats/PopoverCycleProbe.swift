import Foundation
import TinyStatsCore

/// Opt-in lifecycle diagnostics driven only by existing sample deliveries.
struct PopoverCycleProbe {
  struct Configuration: Equatable {
    var count: Int
    var baselineSeconds: Double
    var openSeconds: Double
    var closedSeconds: Double
    var tailSeconds: Double = 60

    func permits(_ settings: Settings) -> Bool {
      !settings.weather.enabled && !settings.calendarEvents && !settings.connectivityChecks
        && !settings.publicIPChecks && !settings.persistHistory
    }

    static func parse(arguments: [String], preferencesDomain: String?) -> Self? {
      let prefix = "TinyStats.CycleProbe."
      guard let preferencesDomain, preferencesDomain.hasPrefix(prefix),
        UUID(uuidString: String(preferencesDomain.dropFirst(prefix.count))) != nil,
        arguments.filter({ $0 == "--preview-popover" }).count == 1,
        !arguments.contains(where: {
          [
            "--preview", "--preview-history", "--preview-settings", "--preview-popover-close-after",
            "--preview-history-close-after", "--preview-quit-after",
          ].contains($0)
        })
      else { return nil }
      func value(_ flag: String, fallback: String? = nil) -> String? {
        let indices = arguments.indices.filter { arguments[$0] == flag }
        if indices.isEmpty { return fallback }
        guard indices.count == 1, let index = indices.first, index + 1 < arguments.count else {
          return nil
        }
        return arguments[index + 1]
      }
      guard let count = value("--preview-popover-cycles").flatMap(Int.init),
        (1...50).contains(count),
        let baseline = value("--cycle-baseline-seconds", fallback: "30").flatMap(Double.init),
        baseline.isFinite, (20...120).contains(baseline),
        let open = value("--cycle-open-seconds", fallback: "6").flatMap(Double.init),
        open.isFinite, (4...60).contains(open),
        let closed = value("--cycle-closed-seconds", fallback: "10").flatMap(Double.init),
        closed.isFinite, (4...120).contains(closed),
        let tail = value("--cycle-tail-seconds", fallback: "60").flatMap(Double.init),
        tail.isFinite, (15...120).contains(tail)
      else { return nil }
      return .init(
        count: count, baselineSeconds: baseline, openSeconds: open, closedSeconds: closed,
        tailSeconds: tail)
    }
  }

  enum Command: Equatable { case show, close }
  struct Event: Equatable {
    enum Kind: String { case baseline, shown, closed, settled, complete, failed }
    var kind: Kind
    var cycle: Int
    var uptime: Double?
    var complete = false
    enum Failure: String {
      case clock, interrupted
      case unexpectedShow = "unexpected-show"
      case showFailed = "show-failed"
      case unexpectedClose = "unexpected-close"
    }
    var reason: Failure? = nil

    var line: String {
      // All text values originate from this state machine, never collected user data.
      let time = uptime.map(String.init(describing:)) ?? "null"
      let failure = reason.map { ",\"reason\":\"\($0.rawValue)\"" } ?? ""
      return
        "TinyStats:cycle={\"event\":\"\(kind.rawValue)\",\"cycle\":\(cycle),\"uptime\":\(time),\"complete\":\(complete)\(failure)}\n"
    }
  }
  struct Step: Equatable {
    var command: Command? = nil
    var event: Event? = nil
  }
  private enum Phase {
    case initial
    case baseline(Double)
    case awaitingShow(Int)
    case shown(Int, Double)
    case awaitingClose(Int)
    case closed(Int, Double)
    case tail(Double)
    case finished, failed
  }
  let configuration: Configuration
  private var phase: Phase = .initial
  private var lastUptime: Double?
  private var cycle = 0

  mutating func tick(at uptime: Double, shown: Bool = false) -> Step? {
    switch phase {
    case .failed, .finished: return nil
    default: break
    }
    guard validTime(uptime) else { return .init(event: fail(.clock, at: uptime)) }
    switch phase {
    case .initial:
      phase = .baseline(uptime + configuration.baselineSeconds)
      return .init(event: .init(kind: .baseline, cycle: 0, uptime: uptime))
    case .baseline(let deadline) where uptime >= deadline:
      cycle = 1
      phase = .awaitingShow(cycle)
      return .init(command: .show)
    case .shown(let cycle, let deadline) where uptime >= deadline:
      phase = .awaitingClose(cycle)
      return .init(command: .close)
    case .closed(let cycle, let deadline) where uptime >= deadline:
      let finished = cycle == configuration.count
      phase = finished ? .tail(uptime + configuration.tailSeconds) : .awaitingShow(cycle + 1)
      self.cycle = finished ? cycle : cycle + 1
      return .init(
        command: finished ? nil : .show,
        event: .init(kind: .settled, cycle: cycle, uptime: uptime))
    case .tail(let deadline) where uptime >= deadline:
      guard !shown else { return .init(event: fail(.unexpectedShow, at: uptime)) }
      phase = .finished
      return .init(event: .init(kind: .complete, cycle: cycle, uptime: uptime, complete: true))
    default: return nil
    }
  }

  mutating func didShow(_ shown: Bool, at uptime: Double) -> Event? {
    guard validTime(uptime) else { return fail(.clock, at: uptime) }
    guard case .awaitingShow(let cycle) = phase else { return fail(.unexpectedShow, at: uptime) }
    guard shown else { return fail(.showFailed, at: uptime) }
    phase = .shown(cycle, uptime + configuration.openSeconds)
    return .init(kind: .shown, cycle: cycle, uptime: uptime)
  }
  mutating func didClose(at uptime: Double) -> Event? {
    guard validTime(uptime) else { return fail(.clock, at: uptime) }
    guard case .awaitingClose(let cycle) = phase else {
      return fail(.unexpectedClose, at: uptime)
    }
    phase = .closed(cycle, uptime + configuration.closedSeconds)
    return .init(kind: .closed, cycle: cycle, uptime: uptime)
  }
  mutating func interrupt(at uptime: Double) -> Event? {
    guard validTime(uptime) else { return fail(.clock, at: uptime) }
    return fail(.interrupted, at: uptime)
  }
  private mutating func validTime(_ uptime: Double) -> Bool {
    guard uptime.isFinite, uptime >= 0, lastUptime.map({ uptime >= $0 }) ?? true else {
      return false
    }
    lastUptime = uptime
    return true
  }
  private mutating func fail(_ reason: Event.Failure, at uptime: Double) -> Event? {
    if case .failed = phase { return nil }
    phase = .failed
    return .init(
      kind: .failed, cycle: cycle, uptime: uptime.isFinite ? uptime : nil, reason: reason)
  }
}
