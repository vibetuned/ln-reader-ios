import AVFoundation
import MediaPlayer
import Observation
import UIKit
import LnReaderCore

/// The playback core: owns the AVPlayer, the audio session, lock-screen /
/// control-center integration, and position auto-save. Process-scoped — the
/// iOS analog of the Android PlaybackService + PlayerHolder pair, collapsed
/// into one class because iOS needs no service boundary: the `audio`
/// background mode plus an active session keeps playback alive in background.
@MainActor
@Observable
final class PlayerEngine {
    static let speedPresets: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    /// A saved position this close to the end means "finished" — reopening restarts.
    private static let finishedMarginMs: Int64 = 5000
    private static let saveIntervalTicks = 20 // 20 × 0.25 s = 5 s

    private(set) var book: Book?
    private(set) var chapters: [Chapter] = []
    private(set) var cover: UIImage?
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var positionMs: Int64 = 0
    private(set) var rate: Double = 1.0

    var locator: ChapterLocator {
        ChapterLocator(chapters: chapters, bookDurationMs: book?.durationMs ?? 0)
    }

    private let bookRepository: BookRepository
    private let positionRepository: PositionRepository
    private let fileStore: FileStore

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var itemEndObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var detailObservationTask: Task<Void, Never>?
    private var ticksSinceSave = 0
    private var wasPlayingBeforeInterruption = false

    init(bookRepository: BookRepository, positionRepository: PositionRepository, fileStore: FileStore) {
        self.bookRepository = bookRepository
        self.positionRepository = positionRepository
        self.fileStore = fileStore
        // Speed is persisted app-wide across launches.
        let storedRate = UserDefaults.standard.double(forKey: "player.rate")
        if storedRate > 0 { rate = storedRate }
        if #available(iOS 16.0, *) { player.defaultRate = Float(rate) }
        configureAudioSession()
        configureRemoteCommands()
        installTimeObserver()
        installInterruptionObserver()
    }

    // MARK: - Loading

    /// Idempotent: opening the already-loaded book only honors `autoPlay`.
    func open(bookId: String, autoPlay: Bool) async {
        if book?.id == bookId {
            if autoPlay, !isPlaying { play() }
            return
        }
        guard let detail = try? await bookRepository.detail(bookId: bookId) else { return }

        if book != nil { await savePosition() }

        book = detail.book
        chapters = detail.chapters
        cover = detail.book.coverPath
            .flatMap { UIImage(contentsOfFile: fileStore.url(for: $0).path) }
        observeDetailChanges(bookId: bookId)

        var startMs = (try? await positionRepository.get(bookId: bookId)).flatMap { $0 } ?? 0
        // A finished book's saved position is its end; restart it instead of instantly re-ending.
        if detail.book.durationMs > 0, startMs >= detail.book.durationMs - Self.finishedMarginMs {
            startMs = 0
        }

        let item = AVPlayerItem(url: fileStore.url(for: detail.book.audioPath))
        item.audioTimePitchAlgorithm = .timeDomain // best for speech
        installItemEndObserver(for: item)
        player.replaceCurrentItem(with: item)
        await player.seek(to: time(fromMs: startMs), toleranceBefore: .zero, toleranceAfter: .zero)
        positionMs = startMs

        if autoPlay {
            play()
        } else {
            updateNowPlaying()
        }
    }

    /// Follows the loaded book's row so companion attach/detach (epubPath /
    /// syncPath) reflects live in the player UI without reopening the book.
    private func observeDetailChanges(bookId: String) {
        detailObservationTask?.cancel()
        detailObservationTask = Task { [weak self] in
            guard let repository = self?.bookRepository else { return }
            let observation = repository.observeDetail(bookId: bookId)
            do {
                for try await detail in observation {
                    guard let self, let detail, self.book?.id == bookId else { break }
                    self.book = detail.book
                    self.chapters = detail.chapters
                }
            } catch {}
        }
    }

    /// Clears the loaded book (used when it's deleted from the library).
    func unload(bookId: String) {
        guard book?.id == bookId else { return }
        detailObservationTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        book = nil
        chapters = []
        cover = nil
        isPlaying = false
        positionMs = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Transport

    func play() {
        guard book != nil else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.rate = Float(rate)
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        Task { await savePosition() }
        updateNowPlaying()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(toMs targetMs: Int64) {
        guard let book else { return }
        let clamped = min(max(0, targetMs), book.durationMs)
        positionMs = clamped
        player.seek(to: time(fromMs: clamped), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    func skip(seconds: Int) {
        seek(toMs: positionMs + Int64(seconds) * 1000)
    }

    func nextChapter() {
        guard let current = locator.window(atMs: positionMs),
              let next = locator.window(atIndex: current.index + 1) else { return }
        seek(toMs: next.startMs)
    }

    /// More than 3 s into a chapter jumps to its start; otherwise to the previous chapter.
    func previousChapter() {
        guard let current = locator.window(atMs: positionMs) else { return }
        if positionMs - current.startMs > 3000 {
            seek(toMs: current.startMs)
        } else if let previous = locator.window(atIndex: current.index - 1) {
            seek(toMs: previous.startMs)
        } else {
            seek(toMs: 0)
        }
    }

    /// 0…1, used by the sleep timer's fade-out.
    func setVolume(_ volume: Float) {
        player.volume = min(max(0, volume), 1)
    }

    func setRate(_ newRate: Double) {
        rate = newRate
        UserDefaults.standard.set(newRate, forKey: "player.rate")
        if isPlaying { player.rate = Float(newRate) }
        if #available(iOS 16.0, *) { player.defaultRate = Float(newRate) }
        updateNowPlaying()
    }

    // MARK: - Session / observers

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
    }

    private func installTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 4), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.tick(time)
            }
        }
    }

    private func tick(_ time: CMTime) {
        guard book != nil else { return }
        if time.isNumeric {
            positionMs = Int64((time.seconds * 1000).rounded())
        }
        isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        // Auto-save every 5 s while playing (mirrors Android's save loop).
        if isPlaying {
            ticksSinceSave += 1
            if ticksSinceSave >= Self.saveIntervalTicks {
                ticksSinceSave = 0
                Task { await savePosition() }
            }
        }
    }

    private func installItemEndObserver(for item: AVPlayerItem) {
        if let itemEndObserver { NotificationCenter.default.removeObserver(itemEndObserver) }
        itemEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                if let duration = self.book?.durationMs { self.positionMs = duration }
                Task { await self.savePosition() }
                self.updateNowPlaying()
            }
        }
    }

    private func installInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleInterruption(notification)
            }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying { pause() }
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if wasPlayingBeforeInterruption, options.contains(.shouldResume) { play() }
        @unknown default:
            break
        }
    }

    // MARK: - Lock screen / control center

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(seconds: -10) }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(seconds: 30) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(toMs: Int64(event.positionTime * 1000)) }
            return .success
        }
        center.changePlaybackRateCommand.supportedPlaybackRates = Self.speedPresets.map { NSNumber(value: $0) }
        center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.setRate(Double(event.playbackRate)) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let book else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: book.title,
            MPMediaItemPropertyPlaybackDuration: Double(book.durationMs) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(positionMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let author = book.author {
            info[MPMediaItemPropertyArtist] = author
        }
        if let chapter = locator.window(atMs: positionMs) {
            info[MPMediaItemPropertyAlbumTitle] = chapter.title
        }
        if let cover {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: cover.size) { _ in cover }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Persistence

    private func savePosition() async {
        guard let book else { return }
        try? await positionRepository.save(bookId: book.id, positionMs: positionMs)
    }

    private func time(fromMs ms: Int64) -> CMTime {
        CMTime(value: CMTimeValue(ms), timescale: 1000)
    }
}
