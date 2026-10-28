import CTinyStats

/// Temporary storage only. A changing inventory must not turn a size hint into a
/// smaller collection limit or combine readings from separate attempts.
enum ProcessSampleBuffer {
  static let maximumCapacity = 8192
  private static let headroom = 128

  static func read(
    estimatedCount: Int, collect: (inout [ts_process]) -> Int
  ) -> [ts_process] {
    let estimate = min(maximumCapacity, max(0, estimatedCount))
    var capacity = min(maximumCapacity, estimate + headroom)
    while true {
      var rows = [ts_process](repeating: ts_process(), count: capacity)
      let count = collect(&rows)
      guard count >= 0, count <= capacity else { return [] }
      if count < capacity || capacity == maximumCapacity {
        rows.removeLast(capacity - count)
        return rows
      }
      // A full buffer may be truncated, even when the original hint was accurate.
      // Drop that attempt before recollecting, up to the pre-existing hard limit.
      capacity = min(maximumCapacity, capacity * 2)
    }
  }
}
