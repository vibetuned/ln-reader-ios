// Dev tool: extract an EPUB and dump its spine as the reader will see it.
// Usage: swift run EpubDump <file.epub>
import Foundation
import LnReaderCore

guard CommandLine.arguments.count == 2 else {
    print("usage: EpubDump <file.epub>")
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("epubdump-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: dir) }

let started = Date()
try EpubReader.ensureExtracted(epubURL: url, to: dir)
let extractSeconds = Date().timeIntervalSince(started)
let book = try EpubReader.parse(extractedDir: dir)

let archive = try ZipArchive(url: url)
print("file:    \(url.lastPathComponent)")
print("entries: \(archive.entries.count)")
print(String(format: "extract: %.2f s", extractSeconds))
print("spine:   \(book.spine.count) pages")
for path in book.spine.prefix(5) { print("  \(path)") }
if book.spine.count > 5 { print("  … \(book.spine.count - 5) more") }
