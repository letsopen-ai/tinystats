import Foundation

/// Queue-confined kernel TCP/UDP session. The supplied serial queue owns all calls/callbacks.
/// A nil queue is reserved for explicitly pumped diagnostics; no hidden queue/timer is made.
public final class KernelTrafficSession {
  private let reader: NetworkTrafficReader
  public init(queue: DispatchQueue? = nil) { reader = NetworkTrafficReader(queue: queue) }
  private var groupedAt: Double?
  private var bundles: [TrafficBundleReading] = []
  public func read(at time: Double, grouping: TrafficGrouping = .processes)
    -> ProcessTrafficSnapshot
  {
    reader.setExpandedOutput(grouping == .bundles)
    var result = reader.read(at: time)
    result.grouping = grouping
    if grouping == .bundles, result.availability == .ready {
      if result.sampledAt != groupedAt {
        guard let rows = TrafficBundleGrouping.rows(result.processes) else {
          stop()
          result.processes = []
          result.availability = .incomplete
          result.message = "App bundle rates could not be verified. Rebuilding accounting."
          return result
        }
        bundles = rows
        groupedAt = result.sampledAt
      }
      result.bundles = bundles
      // Keep all public/default/helper process projections at their original bound.
      result.processes = Array(result.processes.prefix(8))
    } else {
      groupedAt = nil
      bundles = []
    }
    return result
  }
  public func stop() {
    reader.stop()
    groupedAt = nil
    bundles = []
  }
}
