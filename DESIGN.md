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
    ├── Library/  Player/  Viewer/  Timer/  Reader/  Common/
```

No Settings tab (unlike Android): its only real setting there is the download
location, which doesn't exist on iOS — imports are always copied into the app
container. Reader/player preferences live where they're used (toolbars).

```
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

## Sleep timer

`SleepTimerController` drives playback through the same `PlayerEngine` the UI
uses (like Android's controller sharing the MediaController). Time mode counts
elapsed *play* time on a 0.5 s tick — pausing freezes it. Chapter mode computes
a book-absolute target (`ChapterLocator` end of the Nth chapter from arming)
and fires when the position crosses it. Fade is a linear ramp on
`AVPlayer.volume` over the configured tail. On fire: pause, restore volume,
`UNUserNotificationCenter` notification with Postpone / Dismiss actions, and
CoreMotion shake-to-postpone (user acceleration > 1.3 g, 1.2 s cooldown),
armed only while the expired state is pending.

## Image viewer

Viewer tab shows the explicitly requested book (`AppNavigation.viewerBookId`,
set by the detail sheet / player toolbar) or falls back to the playing book;
leaving the tab clears the explicit target — mirroring Android's optional
route arg. Full-screen pager is a `TabView(.page)` of `UIScrollView`-backed
zoomable images (pinch to 5×, double-tap toggle); paging swipes win only at
1× zoom, which UIScrollView gives for free.

## Collections

Same model as Android: nullable `book.collectionId`, no nesting. The FK is
`ON DELETE SET NULL`, so dropping a collection row moves its books back to the
top level in one statement; "delete the books too" walks the members through
`BookRepository.delete` first (file cleanup lives there). Tile art is a 2×2
cover shelf (simplified from Android's overlapping 3×3). Per-collection
manual sort is not ported yet.

## EPUB reader + sync

- **Zip**: Foundation ships no unzip API on iOS, so `ZipArchive`
  (LnReaderCore) is a minimal central-directory reader — stored + deflate via
  the Compression framework (`COMPRESSION_ZLIB` = raw DEFLATE, exactly what
  zip stores), no zip64/encryption, path-traversal guarded. Same
  no-third-party ethos as the m4b parser; tested against synthetic zips and
  both real ln-vox EPUBs (`swift run EpubDump <file>`).
- **EpubReader** extracts once (idempotent marker file) into
  `epubs/<bookId>/` and parses container.xml → OPF manifest + spine into
  root-relative page paths. Manifest `xhtml` values match these paths exactly.
- **ReaderViewModel** owns a WKWebView (`loadFileURL` with read access to the
  extraction dir — no web server needed), a 400 ms follow loop that maps
  `engine.positionMs` → beat (`SyncManifest.beatAt`) → spine page, and JS
  injection: an `lnvox-active` class + `scrollIntoView` for highlighting,
  a `<style>` block for dark mode / highlight, `-webkit-text-size-adjust`
  for text zoom (80–250 %, persisted app-wide with dark mode).
- Auto-follow is on when sync exists and the reader's book is the player's;
  manual paging turns it off; **Resume** re-engages and jumps to the beat.
- The reader presents as a full-screen cover (`AppNavigation.readerBookId`),
  entered from the player top bar or the detail sheet.
- **Scrubber image markers**: manifest images with an embedded m4b image at
  the same ordinal render as tappable dots above the player scrubber at their
  chapter-local fraction, opening the full-screen image viewer — m4b-backed
  by spec, as on Android.
- The reader injects `-apple-system` (San Francisco) as the body font —
  WebKit defaults to Times when the EPUB doesn't specify one.

## Toolbar rule: never rely on UIKit's auto-overflow

UIKit's automatic toolbar overflow ("…", `OverflowBarButtonItem`) **never
opens** on iPadOS 26 in this app — verified by UI test with a hierarchy dump:
the tap lands, no menu appears (regardless of whether the collapsed items are
Buttons or Menus; the `updateVisibleMenuWithBlock` console noise is
unrelated and harmless). Rules:

- Toolbars must never collapse implicitly: the 11-inch iPad fits only ~2
  trailing items beside the tab bar, so the player keeps ZERO visible
  `topBarTrailing` items — the stateful controls (Cast / AirPlay / Read /
  sleep timer) live in a row inside the player body where nothing can fold.
- Items that may not fit go in `ToolbarItem(placement: .secondaryAction)`
  with full `Label`s — SwiftUI renders its own ellipsis menu, which opens
  reliably (player: speed / chapters / images). Caveat: even those item taps
  are dropped *intermittently* on iPadOS, so anything tapped repeatedly or
  whose silent failure confuses (the reader's A−/A+) must be a direct
  button. The reader cover owns its whole nav bar (no adjacent tab bar), so
  it shows search / dark / A− / A+ inline with room to spare.
- Directly visible `Menu`s work fine (Library sort/add) — but playback speed
  is a Button + SpeedSheet (Android parity) since it sat in a crowded bar.
- `PlayerToolbarUITests` guards this on the 11-inch iPad.

## Collection advancing

`CollectionAdvanceController` mirrors Android's: it hangs off
`PlayerEngine.onBookFinished` (fired only on a natural end — AVPlayer's
did-play-to-end never fires on a paused restore-at-end, so Android's
`playWhenReady` guard is implicit). If the finished book is in a collection it
orders the members with `LibraryPrefs.orderedBooks` — the same
sort/manual-order the library shows — and publishes a `CollectionEndPrompt`
with the previous/next books. `ContinueCollectionHost` presents the sheet
globally: attached to the tab root and to the reader's full-screen cover,
with only one active at a time (a sheet can't present from a context hidden
under a cover). Tapping a cover opens that book playing; the finished-margin
guard already restarts finished books from zero.

## Sort & speed persistence

- Playback speed persists app-wide (`player.rate` in UserDefaults), applied
  on engine init via `AVPlayer.defaultRate`.
- Per-collection **Manual** sort mirrors Android: a mode flag + arranged id
  order in UserDefaults (`library.collection.<id>.manual` / `.order`), no DB
  migration. Picking Manual seeds the order from the current on-screen order
  and opens a drag-to-reorder sheet (`List.onMove`, saves as rows move);
  books added later append at the end in import order.

## v1.5 parity notes

- **Whole-book search**: `EpubTextSearch` (LnReaderCore) is a 1:1 port of the
  Android engine — plain-text extraction that mirrors the DOM text-node walk
  (no separator for markup, entities decoded, head/script/style dropped),
  whitespace/NBSP-flexible matching, 500-result cap. The highlight/step JS is
  ported verbatim; occurrence indexes agree between the Swift and JS sides by
  construction. Search bar is a top `safeAreaInset` row (not a nav-bar
  replacement); results overlay the page. Same test suite as Android.
- **Casting — both AirPlay and Google Cast** (the Android app can only do
  Cast; Apple offers no AirPlay sender SDK on Android):
  - *AirPlay*: `AVRoutePickerView`; AVPlayer streams to the route natively.
  - *Google Cast*: official SDK via SRG SSR's SPM wrapper of the unmodified
    XCFramework (Google ships no SPM support). Same architecture as Android:
    `CastMediaServer` (LnReaderCore, NWListener, tested over real HTTP) serves
    `/t/<token>/book|cover/<id>` with Range support; the per-process token
    gates the library from the rest of the network. `CastController` owns the
    session: on start it brings the server up, loads the media on the receiver
    at the current position, and puts the engine into remote mode — transport,
    volume fade, speed (clamped 0.5–2× on the default receiver), position
    polling all route to `GCKRemoteMediaClient`, so the mini-player, sleep
    timer, reader follow, and collection advancing keep working. Disconnect
    hands playback back to the local player at the receiver's position,
    **paused**. The Cast button only appears while devices are discovered.
    Requires `NSLocalNetworkUsageDescription` + `NSBonjourServices`
    (`_googlecast._tcp`, `_CC1AD845._googlecast._tcp`).
- **Sleep-timer expiry dialog**: `SleepTimerExpiredHost` alert over any screen
  (tab root + reader cover, one active at a time); the alert, the notification
  actions, and shake-to-postpone all drive the same controller state.
- **Portrait-only** (Android) is NOT ported: iPhone was already
  portrait-only; iPad keeps all orientations per Apple's HIG/multitasking
  expectations.

## Signing / distribution

- Automatic signing; team is selected in Xcode (or `DEVELOPMENT_TEAM` in
  `project.yml`). Bundle id `com.vibetuned.lnreader` (underscores are not
  allowed in bundle ids, hence no `ln_reader`).
- Background playback requires the `audio` entry in `UIBackgroundModes`
  (declared in `project.yml` → generated Info.plist).
