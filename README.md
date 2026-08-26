# ln-reader (iOS)

iOS client of **ln-reader**, the audiobook player half of the Lectures and
Narrations ecosystem — plays the multi-voice `.m4b` audiobooks produced by
ln-vox, with chapter-relative scrubbing, sleep timers, embedded-image viewing,
and an EPUB companion reader that highlights text in sync with the audio.

The Android client lives in [`ln-reader`](https://github.com/vibetuned/ln-reader);
this repo is the Swift/SwiftUI port. Feature reference: the Android README.
Architecture and porting decisions: [DESIGN.md](DESIGN.md).

## Layout

```
project.yml          XcodeGen spec (the .xcodeproj is generated, not committed)
LnReader/            app target — SwiftUI, iOS 17+
LnReaderCore/        Swift package — platform-neutral core (m4b parser, sync manifest)
```

## Building

Requires Xcode 26+ (iOS 17 deployment target) and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate
open LnReader.xcodeproj
```

Signing: select your team under Signing & Capabilities (automatic signing),
or set `DEVELOPMENT_TEAM` in `project.yml`.

## Core package

`LnReaderCore` builds and runs anywhere Swift does — no Xcode needed:

```sh
cd LnReaderCore
swift build
swift test                    # unit tests (parser, sync manifest, repository)
swift run M4bDump <file.m4b>  # dump parsed metadata/chapters of a real m4b
```

## Status

- [x] `M4bParser` — MP4 atom walker, Nero `chpl` chapters (both header
      variants), `ilst` metadata, embedded `covr` images
- [x] `SyncManifest` — beat/image manifest parsing + `beatAt` lookup
- [x] Data layer — GRDB schema, `BookRepository` (import/delete/observe,
      companion attach/detach), relative-path `FileStore`
- [x] Library — cover grid with progress bars, sort, `.m4b` file import with
      phase progress, detail sheet with remove
- [x] Player — AVPlayer with pitch-preserving speed (0.5–3×), background-audio
      session, lock-screen/Control-Center commands + now-playing metadata,
      chapter-relative scrubber with whole-book strip, chapter list, ±10/30 s
      and chapter skips, 5 s position auto-save, resume-on-launch (paused),
      mini-player on non-player tabs
- [x] Collections — folder tiles with cover shelves, collection view (import
      into, delete with move-back or delete-books), add/remove from the
      detail sheet
- [x] Sleep timer — time mode (counts play time, pause freezes) and chapter
      mode, volume fade-out, expiry notification with Postpone/Dismiss,
      shake-to-postpone
- [x] Image viewer — embedded-image grid, full-screen pager with pinch zoom
      (5×), double-tap zoom, swipe between images
- [x] Companions — attach/detach EPUB + sync manifest from the detail sheet
- [x] EPUB reader — custom zip extractor + OPF spine parser (LnReaderCore),
      WKWebView reader with manual paging, light/dark + text size, audio-synced
      beat highlighting with auto-follow + Resume, scrubber image markers
- [x] Playback speed persisted across launches; per-collection manual sort
      with a drag-to-reorder sheet
- [x] Sleep-timer drawer + speed control in the player top bar
- [x] PrivacyInfo.xcprivacy (no tracking, no collected data); joint privacy
      policy + iOS docs live at https://ln.vibetuned.com
- [ ] App Store Connect listing (screenshots, description, review notes)
