# Design (iOS)

House rule: this port mirrors the Android app's architecture wherever the
platforms allow it, so the two clients stay easy to maintain together. When in
doubt, open the equivalent file in `../ln-reader` and mirror it. This document
records the iOS-specific mappings and deviations.

## Stack

| Concern | Android | iOS |
| --- | --- | --- |
| UI | Jetpack Compose + Material 3 | SwiftUI, `TabView` root |
| Playback | Media3/ExoPlayer + `MediaSessionService` | `AVPlayer` + background-audio mode + `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` |
| Persistence | Room | GRDB (planned; decide before Library port) |
| Settings | DataStore Preferences | `UserDefaults` via `@AppStorage`-style wrappers |
| File access | SAF picker + persistable URI permissions | `fileImporter` + security-scoped bookmarks |
| EPUB reader | WebView + `WebViewAssetLoader` | `WKWebView` + `loadFileURL(allowingReadAccessTo:)` |
| M4B parsing | custom parser in `m4b/` | same parser, ported 1:1 to `LnReaderCore` |
| DI | manual `AppContainer` | manual `AppContainer` via SwiftUI Environment |
| Build | Gradle | XcodeGen (`project.yml`) — the `.xcodeproj` is generated and git-ignored |

## Module layout

```
LnReader/                      app target (UI + platform integrations)
├── LnReaderApp.swift          @main, owns the AppContainer
├── AppContainer.swift         lazy process-scoped singletons (mirrors Android)
└── UI/                        package-by-feature, mirrors Android ui/
    ├── Library/  Player/  Viewer/  Timer/  Settings/  Common/
LnReaderCore/                  Swift package — pure logic, no UIKit/SwiftUI
├── M4b/                       M4bSource, AtomReader, M4bParser
└── Companion/                 SyncManifest (EpubBook to follow)
```

Rule: anything that can live in `LnReaderCore` does — it builds on macOS with
bare Command Line Tools, so parser/model logic is testable without a simulator.

## Porting notes

- **M4bParser** is a line-for-line port of the Kotlin original (same chpl
  9-byte/5-byte header fallback, same image type-indicator + magic-byte sniff,
  same mvhd v0/v1 handling). `M4bSource` became a protocol
  (`FileM4bSource` for real files, `DataM4bSource` for tests) instead of a
  class over a `ParcelFileDescriptor`.
- **Why not AVFoundation for chapters:** `AVAsset` reads QuickTime text-track
  chapters but not Nero `chpl`, which is what ln-vox / mp4chaps write. We keep
  the custom parser for metadata and hand `AVPlayer` only the audio.
- **SyncManifest** uses `JSONSerialization` rather than `Codable` to keep
  the Android parser's lenient semantics (optional fields, `beat_id` fallback,
  skip-invalid-entries, ordinals that preserve manifest array positions).
- **Tests**: XCTest suites in `LnReaderCore/Tests` (run via `swift test` once
  Xcode is installed). `Sources/SelfTest` is a temporary framework-free runner
  for CLT-only environments; delete it when Xcode is the norm.

## Data layer

- **GRDB** (`AppDatabase` in LnReaderCore) with an incremental, non-destructive
  migrator — same policy as Android. Schema v1 mirrors Room v5 minus the
  Android-only columns: no `uri`/`isDownloaded` (iOS has no SAF; every import
  copies the picked file into the app container, so the app owns all audio
  files), no vestigial `syncKey`.
- **Paths are stored relative** to `FileStore.baseURL` (Application Support/
  LnReader) because the iOS container path changes across app updates/restores.
- Repositories live in LnReaderCore and are tested with `swift test` on macOS
  (in-memory GRDB + temp-dir FileStore).

## Import flow (iOS)

```
fileImporter → security-scoped URL
  → chunked copy (8 MB, progress) into books/<id>/<name>.m4b
  → M4bParser.parse on the local copy
  → extract embedded images to books/<id>/images/
  → one GRDB transaction: book + chapters + images
  failure at any step deletes books/<id>/
```

Deviation from Android: there is no local-vs-remote distinction — iOS always
copies (Android only copied cloud SAF sources). Same duplicate-on-reimport
limitation as Android (UUID-keyed, no content hashing).

Dev hook (DEBUG builds): `xcrun simctl launch booted com.vibetuned.lnreader
-autoImport <host path>` imports a book without driving the file picker — the
simulator can read host paths. Handy for smoke tests with real books.

## Player

`PlayerEngine` (app target) is the iOS analog of Android's PlaybackService +
PlayerHolder pair, collapsed into one `@MainActor @Observable` class — iOS
needs no service boundary: the `audio` background mode plus an active
`AVAudioSession` (`.playback` / `.spokenAudio`) keeps playback alive.

- `AVPlayer` with `audioTimePitchAlgorithm = .timeDomain` (speech-optimized
  pitch preservation for the 0.5–3× presets).
- Chapter math (`ChapterLocator`, in LnReaderCore, tested) is shared by the
  scrubber, chapter list, chapter skips, and now-playing info. The scrubber is
  chapter-relative; the whole-book strip + time-left sit between its labels.
- Lock screen / Control Center: `MPRemoteCommandCenter` (play/pause, ±10/30 s
  skips, scrub, rate) + `MPNowPlayingInfoCenter` (cover artwork, current
  chapter as album title).
- Position saves every 5 s while playing, on pause, and on book switch;
  resume-on-launch reopens the last-played book paused (restarts from 0 when
  the saved position is within 5 s of the end — the finished-book guard).
- Interruption handling (calls, other audio) pauses and auto-resumes when the
  system says `.shouldResume`.
- The mini-player reads the same engine directly (no separate state holder,
  like Android's controller-reading MiniPlayer).

## Signing / distribution

- Automatic signing; team is selected in Xcode (or `DEVELOPMENT_TEAM` in
  `project.yml`). Bundle id `com.vibetuned.lnreader` (underscores are not
  allowed in bundle ids, hence no `ln_reader`).
- Background playback requires the `audio` entry in `UIBackgroundModes`
  (declared in `project.yml` → generated Info.plist).
