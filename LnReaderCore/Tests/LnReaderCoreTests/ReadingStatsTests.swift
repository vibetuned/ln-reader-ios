import XCTest
@testable import LnReaderCore

/// Bucketing for the usage chart: calendar edges, clipping, ordering. Mirrors the Android
/// ReadingStatsTest so the two charts can't quietly drift apart.
final class ReadingStatsTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        c.firstWeekday = 2 // Monday, matching Android's week alignment
        return c
    }()

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func session(
        _ bookId: String, _ from: Date, _ to: Date,
        title: String? = nil, kind: ReadLogKind = .listen
    ) -> ReadLogEntry {
        ReadLogEntry(id: "s-\(bookId)-\(from.timeIntervalSince1970)", bookId: bookId,
                     bookTitle: title ?? bookId, kind: kind,
                     startedAt: from, endedAt: to, startPosition: 0, endPosition: 0)
    }

    func testDayBucketsCoverTheLastFourteenLocalDays() {
        let stats = ReadingStatsBuilder.build(
            entries: [], granularity: .day, now: at(2026, 3, 20, 15), calendar: calendar)
        XCTAssertEqual(stats.buckets.count, 14)
        XCTAssertEqual(stats.buckets.last?.start, at(2026, 3, 20))
        XCTAssertEqual(stats.buckets.first?.start, at(2026, 3, 7))
        XCTAssertTrue(stats.isEmpty)
    }

    func testASessionLandsInTheDayItHappened() {
        let stats = ReadingStatsBuilder.build(
            entries: [session("alice", at(2026, 3, 18, 21, 0), at(2026, 3, 18, 21, 30))],
            granularity: .day, now: at(2026, 3, 20, 23), calendar: calendar)
        let day18 = stats.buckets.first { $0.start == at(2026, 3, 18) }
        XCTAssertEqual(day18?.byBook["alice"], 30 * 60_000)
        XCTAssertEqual(stats.totalMs, 30 * 60_000)
        // Every other bucket stays empty rather than picking up a zero entry.
        XCTAssertTrue(stats.buckets.filter { $0.start != at(2026, 3, 18) }.allSatisfy { $0.byBook.isEmpty })
    }

    func testASessionAcrossMidnightIsSplitBetweenBothDays() {
        // 23:40 -> 00:20 is twenty minutes on each side, not forty on the day it started.
        let stats = ReadingStatsBuilder.build(
            entries: [session("oz", at(2026, 3, 18, 23, 40), at(2026, 3, 19, 0, 20))],
            granularity: .day, now: at(2026, 3, 20, 12), calendar: calendar)
        XCTAssertEqual(stats.buckets.first { $0.start == at(2026, 3, 18) }?.byBook["oz"], 20 * 60_000)
        XCTAssertEqual(stats.buckets.first { $0.start == at(2026, 3, 19) }?.byBook["oz"], 20 * 60_000)
        XCTAssertEqual(stats.totalMs, 40 * 60_000)
    }

    func testTimeOutsideTheWindowIsDropped() {
        // Starts before the 14-day window opens and runs an hour into it; only the inside counts.
        let stats = ReadingStatsBuilder.build(
            entries: [session("old", at(2026, 3, 6, 23, 0), at(2026, 3, 7, 1, 0))],
            granularity: .day, now: at(2026, 3, 20, 12), calendar: calendar)
        XCTAssertEqual(stats.totalMs, 60 * 60_000)
        XCTAssertEqual(stats.buckets.first?.byBook["old"], 60 * 60_000)
    }

    func testWeeksStartOnMondayAndMonthsOnTheFirst() {
        let now = at(2026, 3, 20, 12) // a Friday
        let weeks = ReadingStatsBuilder.build(entries: [], granularity: .week, now: now, calendar: calendar)
        XCTAssertEqual(weeks.buckets.count, 12)
        XCTAssertEqual(weeks.buckets.last?.start, at(2026, 3, 16)) // Monday of that week
        let months = ReadingStatsBuilder.build(entries: [], granularity: .month, now: now, calendar: calendar)
        XCTAssertEqual(months.buckets.count, 12)
        XCTAssertEqual(months.buckets.last?.start, at(2026, 3, 1))
        let years = ReadingStatsBuilder.build(entries: [], granularity: .year, now: now, calendar: calendar)
        XCTAssertEqual(years.buckets.count, 5)
        XCTAssertEqual(years.buckets.last?.start, at(2026, 1, 1))
    }

    func testBooksAreOrderedByTheirShareOfTheWindow() {
        let stats = ReadingStatsBuilder.build(
            entries: [
                session("alice", at(2026, 3, 19, 10), at(2026, 3, 19, 10, 30), title: "Alice"),
                session("oz", at(2026, 3, 19, 12), at(2026, 3, 19, 14), title: "Oz"),
                session("alice", at(2026, 3, 20, 9), at(2026, 3, 20, 9, 15), title: "Alice"),
            ],
            granularity: .day, now: at(2026, 3, 20, 12), calendar: calendar)
        XCTAssertEqual(stats.books.map(\.id), ["oz", "alice"])
        XCTAssertEqual(stats.books.map(\.title), ["Oz", "Alice"])
        XCTAssertEqual(stats.books[0].totalMs, 120 * 60_000)
        XCTAssertEqual(stats.books[1].totalMs, 45 * 60_000)
        // The tallest bar is the 19th: Oz's two hours plus Alice's half hour stacked on it.
        XCTAssertEqual(stats.peakBucketMs, 150 * 60_000)
        XCTAssertEqual(stats.shadeIndex(of: "oz"), 0)
        XCTAssertEqual(stats.shadeIndex(of: "alice"), 1)
    }

    func testReadingAndListeningBothCount() {
        let stats = ReadingStatsBuilder.build(
            entries: [
                session("b", at(2026, 3, 20, 8), at(2026, 3, 20, 8, 20), kind: .listen),
                session("b", at(2026, 3, 20, 9), at(2026, 3, 20, 9, 10), kind: .read),
            ],
            granularity: .day, now: at(2026, 3, 20, 12), calendar: calendar)
        XCTAssertEqual(stats.totalMs, 30 * 60_000)
    }

    func testZeroLengthSessionsAreIgnored() {
        let open = session("b", at(2026, 3, 20, 8), at(2026, 3, 20, 8))
        let stats = ReadingStatsBuilder.build(
            entries: [open], granularity: .day, now: at(2026, 3, 20, 12), calendar: calendar)
        XCTAssertTrue(stats.isEmpty)
    }

    func testWindowStartMatchesTheFirstBucket() {
        let now = at(2026, 3, 20, 12)
        for granularity in StatsGranularity.allCases {
            let stats = ReadingStatsBuilder.build(
                entries: [], granularity: granularity, now: now, calendar: calendar)
            XCTAssertEqual(stats.buckets.first?.start,
                           ReadingStatsBuilder.windowStart(granularity, now: now, calendar: calendar))
        }
    }
}
