import Foundation
import GoogleCast
import Observation
import LnReaderCore

/// Google Cast integration — the iOS port of Android's cast half of
/// PlaybackService. When a cast session starts, the media server is brought up
/// (the receiver fetches the m4b from it over the LAN) and the engine enters
/// remote mode; when it ends, playback moves back to the local player —
/// paused, so the device doesn't suddenly start talking — and the server
/// shuts down.
@MainActor
@Observable
final class CastController: NSObject {
    /// Drives the Cast button's visibility, like Android's disappearing button.
    private(set) var devicesAvailable = false

    private let engine: PlayerEngine
    private let server: CastMediaServer
    private let fileStore: FileStore
    private var remoteClient: GCKRemoteMediaClient?
    private var lastKnownPositionMs: Int64?

    init(engine: PlayerEngine, bookRepository: BookRepository, fileStore: FileStore) {
        self.engine = engine
        self.fileStore = fileStore
        let store = fileStore
        server = CastMediaServer { kind, id in
            // Synchronous provider: resolve paths from the store layout directly.
            switch kind {
            case "book":
                let dir = store.bookDir(bookId: id)
                guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
                      let audio = files.first(where: { $0.hasSuffix(".m4b") || $0.hasSuffix(".m4a") })
                        ?? files.first(where: { !$0.hasPrefix(".") && $0 != "images" })
                else { return nil }
                return CastMediaServer.Resource(
                    fileURL: dir.appendingPathComponent(audio), mimeType: "audio/mp4")
            case "cover":
                let cover = store.imagesDir(bookId: id).appendingPathComponent("0.jpg")
                let coverPng = store.imagesDir(bookId: id).appendingPathComponent("0.png")
                if FileManager.default.fileExists(atPath: cover.path) {
                    return CastMediaServer.Resource(fileURL: cover, mimeType: "image/jpeg")
                }
                if FileManager.default.fileExists(atPath: coverPng.path) {
                    return CastMediaServer.Resource(fileURL: coverPng, mimeType: "image/png")
                }
                return nil
            default:
                return nil
            }
        }
        super.init()

        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        options.suspendSessionsWhenBackgrounded = false
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().sessionManager.add(self)
        GCKCastContext.sharedInstance().discoveryManager.add(self)
        devicesAvailable = GCKCastContext.sharedInstance().discoveryManager.deviceCount > 0

        engine.onBookOpened = { [weak self] book, startMs, autoPlay in
            self?.loadRemoteMedia(book: book, startMs: startMs, autoPlay: autoPlay)
        }
    }

    // MARK: - Session lifecycle

    private func sessionStarted(_ session: GCKCastSession) {
        try? server.start()
        remoteClient = session.remoteMediaClient
        session.remoteMediaClient?.add(self)
        let wasPlaying = engine.isPlaying
        let position = engine.positionMs
        engine.enterRemote(self)
        if let book = engine.book {
            loadRemoteMedia(book: book, startMs: position, autoPlay: wasPlaying)
        }
    }

    private func sessionEnded() {
        remoteClient?.remove(self)
        remoteClient = nil
        engine.exitRemote(atMs: lastKnownPositionMs)
        server.stop()
    }

    private func loadRemoteMedia(book: Book, startMs: Int64, autoPlay: Bool) {
        guard let client = remoteClient,
              let contentURL = server.url(kind: "book", id: book.id) else { return }
        let metadata = GCKMediaMetadata(metadataType: .musicTrack)
        metadata.setString(book.title, forKey: kGCKMetadataKeyTitle)
        if let author = book.author {
            metadata.setString(author, forKey: kGCKMetadataKeyArtist)
        }
        if let coverURL = server.url(kind: "cover", id: book.id) {
            metadata.addImage(GCKImage(url: coverURL, width: 600, height: 900))
        }

        let builder = GCKMediaInformationBuilder(contentURL: contentURL)
        builder.streamType = .buffered
        builder.contentType = "audio/mp4"
        builder.streamDuration = TimeInterval(book.durationMs) / 1000
        builder.metadata = metadata

        let options = GCKMediaLoadOptions()
        options.playPosition = TimeInterval(startMs) / 1000
        options.autoplay = autoPlay
        options.playbackRate = Float(min(max(engine.rate, 0.5), 2.0))
        lastKnownPositionMs = startMs
        client.loadMedia(builder.build(), with: options)
    }
}

// MARK: - RemotePlayback (what the engine drives)

extension CastController: RemotePlayback {
    var positionMs: Int64? {
        guard let client = remoteClient, client.mediaStatus?.mediaInformation != nil else {
            return lastKnownPositionMs
        }
        let seconds = client.approximateStreamPosition()
        guard seconds.isFinite, seconds >= 0 else { return lastKnownPositionMs }
        let ms = Int64(seconds * 1000)
        if ms > 0 { lastKnownPositionMs = ms }
        return ms > 0 ? ms : lastKnownPositionMs
    }

    var isPlaying: Bool {
        remoteClient?.mediaStatus?.playerState == .playing
    }

    var isBuffering: Bool {
        let state = remoteClient?.mediaStatus?.playerState
        return state == .buffering || state == .loading
    }

    func play() {
        remoteClient?.play()
    }

    func pause() {
        remoteClient?.pause()
    }

    func seek(toMs targetMs: Int64) {
        lastKnownPositionMs = targetMs
        let options = GCKMediaSeekOptions()
        options.interval = TimeInterval(targetMs) / 1000
        remoteClient?.seek(with: options)
    }

    func setRate(_ rate: Double) {
        // The default receiver supports 0.5–2.0×.
        remoteClient?.setPlaybackRate(Float(min(max(rate, 0.5), 2.0)))
    }

    func setVolume(_ volume: Float) {
        remoteClient?.setStreamVolume(volume)
    }
}

// MARK: - GCK listeners

extension CastController: GCKSessionManagerListener {
    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        MainActor.assumeIsolated { sessionStarted(session) }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didResumeCastSession session: GCKCastSession) {
        MainActor.assumeIsolated { sessionStarted(session) }
    }

    nonisolated func sessionManager(
        _ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?
    ) {
        MainActor.assumeIsolated { sessionEnded() }
    }

    nonisolated func sessionManager(
        _ sessionManager: GCKSessionManager, didFailToStart session: GCKCastSession, withError error: Error
    ) {
        MainActor.assumeIsolated { sessionEnded() }
    }
}

extension CastController: GCKRemoteMediaClientListener {
    nonisolated func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        MainActor.assumeIsolated {
            guard let mediaStatus else { return }
            if mediaStatus.playerState == .idle, mediaStatus.idleReason == .finished {
                engine.remoteFinished()
            }
        }
    }
}

extension CastController: GCKDiscoveryManagerListener {
    nonisolated func didUpdateDeviceList() {
        MainActor.assumeIsolated {
            devicesAvailable = GCKCastContext.sharedInstance().discoveryManager.deviceCount > 0
        }
    }
}
