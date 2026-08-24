import Foundation

/// Parsed `sync_manifest.json` that ties audio timestamps to EPUB beats and images.
///
/// - `beats` drive in-reader highlighting: each carries the `data-beat-id` to mark and the audio
///   window it covers.
/// - `images` drive scrubber markers: each carries a `trigger_seconds` position and the ordinal
///   used to match it to an embedded m4b image.
public struct SyncManifest: Equatable {
    public let spanClass: String
    public let dataAttr: String
    public let beats: [SyncBeat]
    public let images: [SyncImage]

    /// Active beat for a playback position: the last beat whose window has started.
    public func beat(atMs positionMs: Int64) -> SyncBeat? {
        guard !beats.isEmpty else { return nil }
        let seconds = Double(positionMs) / 1000.0
        // beats are sorted by startSeconds at parse time; binary search the last start <= seconds.
        var lo = 0
        var hi = beats.count - 1
        var found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if beats[mid].startSeconds <= seconds {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return found >= 0 ? beats[found] : nil
    }
}

public struct SyncBeat: Equatable {
    public let dataBeatId: String
    public let chapterId: String?
    /// EPUB-relative path of the XHTML this beat lives in, e.g. "OEBPS/Text/prologue.xhtml".
    public let xhtml: String
    public let startSeconds: Double
    public let endSeconds: Double
}

public struct SyncImage: Equatable {
    /// EPUB-relative src as written in the manifest, e.g. "../Images/Cover.jpg".
    public let src: String
    public let xhtml: String?
    public let triggerSeconds: Double
    /// Position of this entry within the manifest's images array (used to index m4b images).
    public let ordinal: Int
}

public enum SyncManifestParser {

    public static func parse(fileURL: URL) -> SyncManifest? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? parse(data: data)
    }

    public static func parse(json: String) throws -> SyncManifest {
        try parse(data: Data(json.utf8))
    }

    public static func parse(data: Data) throws -> SyncManifest {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let spanClass = root["span_class"] as? String ?? "lnvox-beat"
        let dataAttr = root["data_attr"] as? String ?? "data-beat-id"

        var beats: [SyncBeat] = []
        if let beatsArr = root["beats"] as? [Any] {
            beats.reserveCapacity(beatsArr.count)
            for element in beatsArr {
                guard let o = element as? [String: Any] else { continue }
                let id = (o["data_beat_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (o["beat_id"] as? String) ?? ""
                guard !id.isEmpty else { continue }
                beats.append(SyncBeat(
                    dataBeatId: id,
                    chapterId: (o["chapter_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    xhtml: o["xhtml"] as? String ?? "",
                    startSeconds: doubleValue(o["start_seconds"]) ?? 0,
                    endSeconds: doubleValue(o["end_seconds"]) ?? 0
                ))
            }
        }
        beats.sort { $0.startSeconds < $1.startSeconds }

        var images: [SyncImage] = []
        if let imagesArr = root["images"] as? [Any] {
            images.reserveCapacity(imagesArr.count)
            for (i, element) in imagesArr.enumerated() {
                guard let o = element as? [String: Any],
                      let src = o["src"] as? String, !src.isEmpty else { continue }
                images.append(SyncImage(
                    src: src,
                    xhtml: (o["xhtml"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    triggerSeconds: doubleValue(o["trigger_seconds"]) ?? 0,
                    ordinal: i
                ))
            }
        }

        return SyncManifest(spanClass: spanClass, dataAttr: dataAttr, beats: beats, images: images)
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        (any as? NSNumber)?.doubleValue ?? (any as? String).flatMap(Double.init)
    }
}
