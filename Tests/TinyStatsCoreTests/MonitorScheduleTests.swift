import Foundation
import Testing

@testable import TinyStatsCore

@Test func regroupRequestsShareDeadlineCoalesceAndDoNotCollectBeforeOneSecond() {
  var schedule = MonitorSchedule()
  let date = Date(timeIntervalSince1970: 100.25)
  #expect(schedule.next(at: 10, date: date, interval: 5, clockStep: nil).collect)
  schedule.collectionFinished(at: 10.2, interval: 5)
  // The worker supplies last completed collection + 1, even for repeated mode changes.
  for now in [10.3, 10.5, 11.199] {
    schedule.requestCollection(noEarlierThan: 11.2)
    #expect(schedule.deadline(at: now, date: date, clockStep: nil) == 11.2)
    #expect(!schedule.next(at: now, date: date, interval: 5, clockStep: nil).collect)
  }
  #expect(schedule.next(at: 11.2, date: date, interval: 5, clockStep: nil).collect)
  #expect(!schedule.next(at: 11.201, date: date, interval: 5, clockStep: nil).collect)
  schedule.collectionFinished(at: 11.3, interval: 5)
  #expect(schedule.deadline(at: 11.4, date: date, clockStep: nil) == 16.2)
  // Already-old requests collect on the next shared tick; clock ticks cannot jump the boundary.
  schedule.requestCollection(noEarlierThan: 12.3)
  #expect(!schedule.next(at: 12, date: date, interval: 5, clockStep: 1).collect)
  #expect(schedule.next(at: 13, date: date, interval: 5, clockStep: 1).collect)
  schedule.reset()
  #expect(schedule.next(at: 14, date: date, interval: 5, clockStep: nil).collect)
}

@Test func invalidRegroupDeadlinesDoNotReplaceTheSharedSchedule() {
  var schedule = MonitorSchedule()
  let date = Date(timeIntervalSince1970: 100)
  _ = schedule.next(at: 10, date: date, interval: 5, clockStep: nil)
  for invalid in [Double.nan, .infinity, -1] {
    schedule.requestCollection(noEarlierThan: invalid)
    #expect(schedule.deadline(at: 11, date: date, clockStep: nil) == 15)
  }
}
