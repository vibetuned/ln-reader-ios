import SwiftUI
import Charts
import LnReaderCore

/// Shades a stacked bar gets, in the order books are stacked (biggest share first).
///
/// Steps through the palette from the deep binding green out to parchment, with the amber accent
/// last — adjacent books stay distinguishable without leaving the book's own colour world. A
/// library with more books than shades wraps, which is why the legend names them. Matches the
/// Android chart's `BOOK_SHADES`.
enum BookShade {
    static let all: [Color] = [
        Color(red: 0.290, green: 0.420, blue: 0.325),  // #4A6B53 forest
        Color(red: 0.424, green: 0.541, blue: 0.455),  // #6C8A74 sage subtle
        Color(red: 0.671, green: 0.812, blue: 0.698),  // #ABCFB2 forest light
        Color(red: 0.698, green: 0.804, blue: 0.725),  // #B2CDB9 sage light
        Color(red: 0.776, green: 0.573, blue: 0.204),  // #C69234 amber
        Color(red: 0.773, green: 0.918, blue: 0.800),  // #C5EACC forest pale
    ]
    static func at(_ index: Int) -> Color { all[index % all.count] }
}

/// Time spent per book over a chosen window — the Settings screen's usage chart.
///
/// Uses Swift Charts, where Android draws the bars from layout. The shapes agree because both
/// read the same `ReadingStats` buckets; only the rendering is platform-native.
struct StatsSection: View {
    let stats: ReadingStats?
    @Binding var granularity: StatsGranularity
    let onOpenSessions: () -> Void

    var body: some View {
        Section {
            Picker("Range", selection: $granularity) {
                ForEach(StatsGranularity.allCases, id: \.self) { value in
                    Text(label(value)).tag(value)
                }
            }
            .pickerStyle(.segmented)

            if let stats {
                if stats.isEmpty {
                    Text("Nothing here yet — time spent listening and reading will appear once you play a book.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    total(stats)
                    chart(stats)
                    ForEach(Array(stats.books.enumerated()), id: \.element.id) { index, book in
                        legendRow(book: book, shade: BookShade.at(index))
                    }
                    Button(action: onOpenSessions) {
                        Label("Details", systemImage: "list.bullet")
                    }
                }
            } else {
                ProgressView()
            }
        } header: {
            Text("Time spent")
        } footer: {
            Text("How long each book has been open, listening and reading together.")
        }
    }

    private func total(_ stats: ReadingStats) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(formatTotal(stats.totalMs))
                .font(.title2.weight(.semibold))
            Text("across \(stats.books.count) \(stats.books.count == 1 ? "book" : "books")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chart(_ stats: ReadingStats) -> some View {
        // Flattened to one mark per (bucket, book); Charts stacks same-x marks automatically.
        let marks: [(bucket: StatsBucket, bookId: String, ms: Int64, shade: Color)] =
            stats.buckets.flatMap { bucket in
                stats.books.enumerated().compactMap { index, book in
                    guard let ms = bucket.byBook[book.id], ms > 0 else { return nil }
                    return (bucket, book.id, ms, BookShade.at(index))
                }
            }
        return Chart {
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                BarMark(
                    x: .value("When", mark.bucket.label),
                    y: .value("Minutes", Double(mark.ms) / 60_000)
                )
                .foregroundStyle(mark.shade)
            }
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let minutes = value.as(Double.self) {
                        Text(axisLabel(minutes: minutes))
                    }
                }
            }
        }
        .chartXAxis {
            // 14 day labels would collide; name every other one.
            AxisMarks(values: .automatic(desiredCount: stats.buckets.count > 8 ? 7 : 6))
        }
        .frame(height: 170)
        .padding(.vertical, 4)
    }

    private func legendRow(book: StatsBook, shade: Color) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(shade).frame(width: 10, height: 10)
            Text(book.title.isEmpty ? "Untitled" : book.title)
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            Text(formatTotal(book.totalMs))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func label(_ granularity: StatsGranularity) -> String {
        switch granularity {
        case .day: "Days"
        case .week: "Weeks"
        case .month: "Months"
        case .year: "Years"
        }
    }

    private func axisLabel(minutes: Double) -> String {
        minutes >= 120 ? "\(Int(minutes / 60))h" : "\(Int(minutes))m"
    }
}

/// "4h 12m" / "12m" / "—". Shared by the total line, the legend and the session rows.
func formatTotal(_ ms: Int64) -> String {
    guard ms > 0 else { return "—" }
    let minutes = ms / 60_000
    let hours = minutes / 60
    if hours > 0 { return "\(hours)h \(minutes % 60)m" }
    return minutes > 0 ? "\(minutes)m" : "<1m"
}
