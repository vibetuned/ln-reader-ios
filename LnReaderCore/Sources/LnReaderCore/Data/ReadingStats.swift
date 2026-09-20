import Foundation

/// Bar width for the usage chart: what one bar covers.
public enum StatsGranularity: String, CaseIterable, Sendable {
    case day, week, month, year
}

/// One book's share of the charted window, used to order the stack and pick its shade.
public struct StatsBook: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let totalMs: Int64
}

/// One bar: a time bucket and how long each book was open inside it.
public struct StatsBucket: Equatable, Identifiable, Sendable {
    public let start: Date
    public let label: String
    /// bookId -> ms inside this bucket. Books with no time here are absent, not zero.
    public let byBook: [String: Int64]
    public var id: Date { start }
    public var totalMs: Int64 { byBook.values.reduce(0, +) }
}

/// The charted window: consecutive buckets ending with the one containing "now", plus the books
/// that appear in it ordered by how much of it they account for.
public struct ReadingStats: Equatable, Sendable {
    public let granularity: StatsGranularity
    public let buckets: [StatsBucket]
    public let books: [StatsBook]

    public var totalMs: Int64 { books.reduce(0) { $0 + $1.totalMs } }
    public var isEmpty: Bool { totalMs == 0 }
    /// Longest single bar — the chart's vertical scale.
    public var peakBucketMs: Int64 { buckets.map(\.totalMs).max() ?? 0 }

    /// Shade slot for a book, by its rank in `books`. The UI maps this onto its palette.
    public func shadeIndex(of bookId: String) -> Int {
        books.firstIndex { $0.id == bookId } ?? 0
    }
}

/// Turns raw `readLog` sessions into chart buckets — the Swift twin of Android's
/// `ReadingStatsBuilder`, with the same rules so the two charts agree.
///
/// Calendar-aware: bucket edges are real local day/week/month/year boundaries, not fixed-width
/// slices back from now, so "this week" means the week you'd name. A session is **clipped** to
/// each bucket it overlaps rather than counted wholly in the one it started in — an hour that
/// runs through midnight is half an hour on each day, which is what a time-spent chart has to say
/// in order to add up.
public enum ReadingStatsBuilder {

    public static func bucketCount(_ granularity: StatsGranularity) -> Int {
        switch granularity {
        case .day: 14
        case .week: 12
        case .month: 12
        case .year: 5
        }
    }

    /// Start of the window `build` charts — the oldest instant a session can contribute from.
    public static func windowStart(
        _ granularity: StatsGranularity, now: Date, calendar: Calendar = .current
    ) -> Date {
        bucketStarts(granularity, now: now, calendar: calendar).first ?? now
    }

    public static func build(
        entries: [ReadLogEntry],
        granularity: StatsGranularity,
        now: Date,
        calendar: Calendar = .current
    ) -> ReadingStats {
        let starts = bucketStarts(granularity, now: now, calendar: calendar)
        // One extra edge on the end so every bucket has an exclusive upper bound.
        let edges = starts + [nextStart(granularity, after: starts[starts.count - 1], calendar: calendar)]
        var totals = Array(repeating: [String: Int64](), count: starts.count)

        for entry in entries where entry.endedAt > entry.startedAt {
            for i in starts.indices {
                let from = max(entry.startedAt, edges[i])
                let to = min(entry.endedAt, edges[i + 1])
                let overlap = to.timeIntervalSince(from)
                if overlap > 0 {
                    let ms = Int64((overlap * 1000).rounded())
                    totals[i][entry.bookId, default: 0] += ms
                }
            }
        }

        var titles: [String: String] = [:]
        for entry in entries { titles[entry.bookId] = entry.bookTitle }
        var perBook: [String: Int64] = [:]
        for bucket in totals {
            for (id, ms) in bucket { perBook[id, default: 0] += ms }
        }

        return ReadingStats(
            granularity: granularity,
            buckets: starts.enumerated().map { index, start in
                StatsBucket(start: start,
                            label: label(granularity, start: start, calendar: calendar),
                            byBook: totals[index])
            },
            // Biggest first: the stack reads largest-at-the-bottom and shades follow the same order.
            books: perBook
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .map { StatsBook(id: $0.key, title: titles[$0.key] ?? "", totalMs: $0.value) }
        )
    }

    private static func bucketStarts(
        _ granularity: StatsGranularity, now: Date, calendar: Calendar
    ) -> [Date] {
        let count = bucketCount(granularity)
        let component: Calendar.Component = switch granularity {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
        // `dateInterval(of:)` gives the calendar's own idea of where a week or month begins,
        // including the locale's first weekday — the same intent as Android's Monday alignment.
        let currentStart = calendar.dateInterval(of: component, for: now)?.start ?? now
        return (0..<count).reversed().compactMap {
            calendar.date(byAdding: component, value: -$0, to: currentStart)
        }
    }

    private static func nextStart(
        _ granularity: StatsGranularity, after start: Date, calendar: Calendar
    ) -> Date {
        let component: Calendar.Component = switch granularity {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
        return calendar.date(byAdding: component, value: 1, to: start) ?? start
    }

    private static func label(
        _ granularity: StatsGranularity, start: Date, calendar: Calendar
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.timeZone = calendar.timeZone
        switch granularity {
        case .day: formatter.setLocalizedDateFormatFromTemplate("d")
        case .week: formatter.setLocalizedDateFormatFromTemplate("dMMM")
        case .month: formatter.setLocalizedDateFormatFromTemplate("MMM")
        case .year: formatter.setLocalizedDateFormatFromTemplate("yyyy")
        }
        return formatter.string(from: start)
    }
}
