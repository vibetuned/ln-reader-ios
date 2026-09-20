# Changelog

## v1.1.0 — 2026-09-20

Books that are only an EPUB, a usage chart showing where your time goes, a
Settings tab in place of the Timer tab, a sleep timer you can change while it
runs, and the new shared look.

### App Store release notes (≤ 4000 chars)

```
• Books without audio: import a plain EPUB — no narration required. A page mark keeps your place, and the library shows the page you're on instead of a running time.
• Time spent: a chart of how long each book has been open, by day, week, month or year. One shade per book, stacked, with the individual sessions behind Details.
• The Timer tab is now Settings, holding both the chart and the sleep timer.
• Change a running sleep timer instead of cancelling it — pick new values and tap Update.
• A new icon and colours, shared with the Android app.
• iPad: the library now shows four large covers per row instead of six thin ones.

Everything stays on your device: no accounts, no tracking, no servers.
```

### Books without audio
- **EPUB-only imports** — a book no longer needs an `.m4b`. Import a plain
  `.epub` and it lands in the library like any other book, opening straight
  into the reader.
- A **page mark** records the page and scroll position, so the book reopens
  exactly where you left it. These books have no listening position to fall
  back on, so this is what carries your place.
- The library tile shows **`page / total`** rather than a duration.
- The **mini-player stays hidden** while you read one of these, and returns
  only when audio is actually playing.

### Time spent
- A **Time spent** section charts how long each book has been open — listening
  and reading together — across the last **days, weeks, months or years**.
- Bars are **stacked, one shade per book**, with a legend totalling each book
  for the range.
- **Details** opens the individual sessions, newest first, loading a page at a
  time as you scroll rather than reading the whole history up front.
- Sessions are recorded on device in a new usage log. Nothing leaves it.

### Settings
- **The Timer tab is now a Settings tab**, carrying the usage chart and the
  sleep timer. Android made the same move, so the two apps have the same four
  tabs again.

### Sleep timer
- **A running timer can be changed, not just cancelled.** The setup controls
  stay on screen while it runs and start from what is actually armed; pick new
  values and tap **Update timer** to replace it. The countdown and the expiry
  prompt sit above them as their own sections instead of replacing them, which
  is how the Android chips have always behaved.
- The floating mini-player **no longer covers the Update button** — every
  screen that shows it now reserves the space underneath.

### Player
- The chapter selector gained the **▼** affordance the Android player has, so
  it reads as something you can tap rather than a label.

### iPad
- The library shows **four large covers per row** instead of six thin ones. An
  adaptive grid fits as many columns as its minimum allows, and the minimum
  that suits a phone left an iPad using about a third of its width.

### Polish
- The palette is the **Athenaeum** scheme from `visual-design.md` — the same
  greens the Android app and the website use — with a new app icon to match.

## v1.0.0 — 2026-08-31

Initial App Store release — the full ln-reader experience, ported natively to
iPhone and iPad in Swift/SwiftUI: the library with collections, the
chapter-aware player, sleep timers, the embedded-image viewer, and the EPUB
companion reader with audio-synced highlighting. Plus things Android can't
do: AirPlay next to Google Cast, and books that import themselves straight
from AirDrop.

### App Store release notes (≤ 4000 chars)

```
ln-reader arrives on iPhone and iPad — a player for enhanced, multi-voice .m4b audiobooks with an EPUB reader that follows the narration.

• Library: import .m4b audiobooks, covers with progress bars, folder-style collections you can arrange by hand.
• Player: chapter-relative scrubbing with a whole-book strip, ±10/30 s skips, 0.5–3× speed, lock-screen and Control Center controls, background playback.
• Cast anywhere: AirPlay AND Google Cast — stream to the TV while the sleep timer, reader sync, and progress keep working.
• Reader: attach the matching EPUB and the text highlights itself in sync with the audio, turning pages as you listen. Light/dark mode, adjustable text size, whole-book search.
• Images: every illustration embedded in the audiobook, in a gallery and as tappable markers on the scrubber.
• Sleep timer: by time or by chapters, with volume fade-out and shake-to-postpone.
• Finish a book in a collection and the next one is a tap away.
• AirDrop a book to your device and it imports itself.

Everything stays on your device: no accounts, no tracking, no servers.
```

### Library
- Import **.m4b** audiobooks from the Files app (any provider — iCloud
  Drive, Drive, Dropbox…) or receive them via **AirDrop / "Open in…"** — an
  AirDropped book imports straight into the library.
- Grid of covers with per-book **playback progress bars**; sort by name or
  date added (remembered).
- **Collections** (folders) with cover-shelf tiles; add/remove from a book's
  detail sheet; per-collection **manual ordering** by drag; delete a
  collection with or without its books.
- Detail sheet per book: Open, Read, View images, collection membership,
  EPUB / sync-manifest companions, Remove.

### Player
- Background playback with full **lock screen / Control Center** integration
  (cover art, current chapter, ±10/30 s skips, scrubbing, speed).
- **Chapter-relative scrubber** — drag previews the numbers only and seeks
  once on release — with a whole-book progress strip and time-left between
  the chapter labels, and a live `-remaining` countdown on the right.
- Tappable chapter selector + chapter list; prev/next chapter; pitch-preserving
  **0.5–3× speed** (persisted).
- **Mini-player** on every other screen — skips, play/pause, a Read shortcut,
  stacked chapter + book progress bars.
- Auto-saves position every 5 s and resumes on launch, paused.

### Casting — AirPlay and Google Cast
- **AirPlay**: native route picker in the player.
- **Google Cast**: stream the current book to any Cast device; the device
  serves the audio to the receiver over your Wi-Fi. Sleep timer (chapter mode
  included), reader auto-follow, and position saving keep working while
  casting. Disconnecting hands playback back **paused** at the same spot.
  The Cast button appears only while Cast devices are on the network.

### EPUB reader + sync
- Attach the matching EPUB and a **sync manifest** from the book's detail
  sheet (or AirDrop them — a sheet asks which book to attach to).
- **Auto-follow**: highlights the narrated sentence, scrolls to it, and turns
  pages as playback advances; manual paging pauses following and **Resume**
  jumps back to the live beat.
- **Whole-book text search** — case-insensitive, matches across inline
  formatting; results by page with the match bolded; in-place highlighting
  with next/previous stepping.
- Light/dark mode and **A−/A+ text size** (80–250 %), both remembered.
- **Scrubber image markers**: manifest illustrations appear as dots on the
  player scrubber within their chapter — tap to open the image.

### Image viewer
- Grid of every image embedded in the m4b; full-screen pager with pinch zoom
  (to 5×), double-tap zoom, swipe between images.

### Sleep timer
- **Time** mode (5–90 min, counts listening time — pausing freezes it) and
  **Chapters** mode (end of current, +2/+3/+5).
- Volume **fade-out** (off / 10 s / 30 s / 1 min / 5 min).
- On expiry: in-app Postpone/Dismiss dialog when the app is open, a
  notification otherwise, and **shake-to-postpone** — all driving the same
  state. The timer button tints while armed.

### Collections advancing
- Finishing a book that belongs to a collection offers the **next / previous
  book by cover**, over any screen; reopening a finished book restarts it.

### Privacy
- No accounts, no analytics, no tracking, no servers; everything stays on
  device. Policy: https://ln.vibetuned.com/privacy.html

### Under the hood
- Native Swift/SwiftUI, iOS/iPadOS 17+; GRDB persistence; custom Nero-`chpl`
  m4b chapter parser and dependency-free zip/EPUB extraction in a
  platform-neutral core package with its own test suite; Google Cast SDK
  4.8.4; XcodeGen project.

### Known limitations (parity with Android)
- Chapter parsing is Nero `chpl` only; QuickTime text-track chapters load
  with an empty chapter list.
- Scrubber markers match manifest images to embedded m4b images by ordinal.
- Re-importing the same file creates a duplicate (UUID-keyed library).
- Single-device: no sync; deleting the app deletes the library.
- Reader dark mode is injected CSS — EPUBs with hard-coded colors may not
  fully darken.
