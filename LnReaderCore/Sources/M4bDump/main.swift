// Dev tool: dump what M4bParser sees in an m4b (like `mp4chaps -l`, plus metadata
// and embedded images). Usage: swift run m4bdump <file.m4b>
import Foundation
import LnReaderCore

guard CommandLine.arguments.count == 2 else {
    print("usage: m4bdump <file.m4b>")
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])

func hms(_ ms: Int64) -> String {
    let s = ms / 1000
    return String(format: "%d:%02d:%02d.%03d", s / 3600, s / 60 % 60, s % 60, ms % 1000)
}

let source = try FileM4bSource(url: url)
defer { source.close() }
let started = Date()
let parsed = try M4bParser().parse(source: source)
let elapsed = Date().timeIntervalSince(started)

print("file:     \(url.lastPathComponent)")
print("size:     \(source.size) bytes")
print("title:    \(parsed.title ?? "—")")
print("author:   \(parsed.author ?? "—")")
print("album:    \(parsed.album ?? "—")")
print("duration: \(hms(parsed.durationMs))")
print("images:   \(parsed.images.count)")
for (i, image) in parsed.images.enumerated() {
    print("  [\(i)] \(image.mimeType)  \(image.bytes.count) bytes")
}
print("chapters: \(parsed.chapters.count)")
for chapter in parsed.chapters {
    print("  \(hms(chapter.startMs))  \(chapter.title)")
}
print(String(format: "parsed in %.0f ms", elapsed * 1000))
