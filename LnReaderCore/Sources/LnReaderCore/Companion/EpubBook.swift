import Foundation

/// Parsed EPUB: the ordered reading spine as extraction-root-relative paths
/// (e.g. "OEBPS/Text/prologue.xhtml").
public struct EpubBook: Equatable, Sendable {
    public let spine: [String]
}

public enum EpubError: Error {
    case missingContainer
    case missingOpf(String)
    case emptySpine
}

public enum EpubReader {
    private static let markerName = ".lnreader-extracted"

    /// Unzips the EPUB into `directory` once (idempotent via a marker file,
    /// zip path-traversal guarded by ZipArchive).
    public static func ensureExtracted(epubURL: URL, to directory: URL) throws {
        let marker = directory.appendingPathComponent(markerName)
        if FileManager.default.fileExists(atPath: marker.path) { return }
        // A partial previous extraction (no marker) is retried from scratch.
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ZipArchive(url: epubURL).extractAll(to: directory)
        try Data().write(to: marker)
    }

    /// Reads META-INF/container.xml → OPF → ordered spine from an extracted dir.
    public static func parse(extractedDir: URL) throws -> EpubBook {
        let containerURL = extractedDir.appendingPathComponent("META-INF/container.xml")
        guard let containerData = try? Data(contentsOf: containerURL),
              let opfPath = ContainerParser.rootfilePath(containerData) else {
            throw EpubError.missingContainer
        }

        let opfURL = extractedDir.appendingPathComponent(opfPath)
        guard let opfData = try? Data(contentsOf: opfURL) else {
            throw EpubError.missingOpf(opfPath)
        }
        let opfDir = (opfPath as NSString).deletingLastPathComponent

        let opf = OpfParser.parse(opfData)
        let spine = opf.spineIdrefs.compactMap { idref -> String? in
            guard let href = opf.manifest[idref],
                  let decoded = href.removingPercentEncoding else { return nil }
            return opfDir.isEmpty
                ? decoded
                : (opfDir as NSString).appendingPathComponent(decoded)
        }
        guard !spine.isEmpty else { throw EpubError.emptySpine }
        return EpubBook(spine: spine)
    }
}

// MARK: - container.xml

private final class ContainerParser: NSObject, XMLParserDelegate {
    private var path: String?

    static func rootfilePath(_ data: Data) -> String? {
        let delegate = ContainerParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.path
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName: String?, attributes: [String: String]
    ) {
        if elementName == "rootfile", path == nil,
           let fullPath = attributes["full-path"] {
            path = fullPath
            parser.abortParsing()
        }
    }
}

// MARK: - OPF (manifest + spine)

private final class OpfParser: NSObject, XMLParserDelegate {
    private(set) var manifest: [String: String] = [:] // id → href
    private(set) var spineIdrefs: [String] = []

    static func parse(_ data: Data) -> OpfParser {
        let delegate = OpfParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName: String?, attributes: [String: String]
    ) {
        switch elementName {
        case "item":
            if let id = attributes["id"], let href = attributes["href"] {
                manifest[id] = href
            }
        case "itemref":
            if let idref = attributes["idref"] {
                spineIdrefs.append(idref)
            }
        default:
            break
        }
    }
}
