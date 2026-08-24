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

## Signing / distribution

- Automatic signing; team is selected in Xcode (or `DEVELOPMENT_TEAM` in
  `project.yml`). Bundle id `com.vibetuned.lnreader` (underscores are not
  allowed in bundle ids, hence no `ln_reader`).
- Background playback requires the `audio` entry in `UIBackgroundModes`
  (declared in `project.yml` → generated Info.plist).
