# Music Section Reintroduction — Phase 0 Scaffold Design

**Date:** 2026-07-13
**Branch:** `working`
**Status:** In progress (brainstorming approved, implementation started)
**Parent spec:** Music section reintroduction (BBPlayer-aligned, 5-phase decomposition)

## Goal

Phase 0 establishes the **scaffold** for reintroducing the Music section into Paladala. After Phase 0:

1. The music tab is **back in the tab bar** (currently removed 2026-07-11 in favour of 追番).
2. Existing `MusicHomeView` / `MusicService` / `MusicPlayerView` / `LyricScrollView` / `LyricLineView` / `MusicProgressBar` / `MusicCard` / `BiliLyricParser` work **unchanged in behaviour** under a new module organisation.
3. Three local Swift Packages (`LyricKit`, `MusicKit`, `MusicUI`) own all music code; main app target only consumes them through `MusicModuleEntry`.

End state: zero behaviour change, code reorganised and ready for Phase 1's UX/visual upgrades.

## Non-Goals

- No new visual features (no karaoke, no fade transitions, no Monet theme — all Phase 1+).
- No protocol abstraction beyond what's needed to relocate the code (Phase 1 will introduce the full `MusicPlaybackEngine` / `LyricSource` / `ThemeColorExtractor` / `MusicModuleEntry` quartet).
- No removal of legacy `BiliLyricTrack` / `BiliLyricLine` / `BiliLyricInfo` types — Phase 0 keeps them as the canonical Bili-side types; Phase 1 introduces parallel `LyricTrack` / `LyricLine` in `LyricKit` and the adapter layer.
- No xcodeproj local-package configuration — Phase 0 uses **plain directory groups** under `ios/Paladala/Packages/{LyricKit,MusicKit,MusicUI}` to avoid the pbxproj manual-edit pitfall (Phase 1 wires them as proper local packages once directory layout is stable).
- No changes to `PlayerController` (still used directly by `MusicPlayerView`).

## Constraints (user-confirmed)

| Question | Decision |
|---|---|
| Scope of this reintroduction | Full BBPlayer alignment (5 pages) over 5 phases |
| Lyric rendering | SwiftUI-native self-built, AMLL design language reference only (no WebView) |
| Module organisation | Local Swift Package(s) + existing single-module main target |
| Phase 0 vs Phase 1+ | Phase 0 = scaffold only (restore tab + reorganise files); Phase 1+ = new features |
| Approval gate | User explicitly invoked "just do the product" — brainstorm flow skipped review gates for Phase 0 |

## Codebase Facts (gathered 2026-07-13)

- `MusicHomeView.swift` (857 lines) and `MusicService.swift` (262 lines) exist under `ios/Paladala/Paladala/`. MusicHomeView holds 4 private components inline: `MusicCard`, `LyricScrollView`, `LyricLineView`, `MusicProgressBar`.
- `MusicHomeView` also defines `MusicViewModel` (also defined separately in `MusicService.swift` — same class).
- `RootView.swift:424-502` has `TabView` with 5 tabs: `home / dynamic / live / bangumi / profile`. No `music` tab.
- `RootView.swift:195-201` redirects `paladala://music` deep link to `bangumi` tab. Must be reverted.
- `AppRouter.openMusic(_:)` (line 154) and `MusicRoute.player(video)` route still wired; `RootView.swift:525-528, 603-606` registers `navigationDestination(for: MusicRoute.self)` that pushes `MusicPlayerView`.
- `MainTab` enum lives in `Models.swift`; only 5 cases, no `music`.
- `PlayerController` lives in `AVPlayerController.swift:153`. `MusicPlayerView` instantiates one per `loadPlayback()`.
- `BilibiliAPIClient` exposes `musicVideos`; `PaladalaRepository` exposes `musicVideos(page:)` (line 188) and `videoLyrics(for:)` (line 223).
- `BiliLyricTrack` / `BiliLyricLine` / `BiliLyricInfo` types live in `Models.swift` (lines 1029-1128); used by `MusicHomeView`, `MusicService`, `PlayerController`, and probably `VideoDetailView` (subtitle overlay).
- `Docs/ui-inventory.md` is stale — documents 5-tab structure and the MusicPlayerView with full feature set, but doesn't reflect the music-tab removal.

## Implementation Plan

### Phase 0a — Restore the music tab

1. **`Models.swift`**: Add `case music` to `MainTab` enum, between `.live` and `.bangumi` (matches original ordering pre-removal). Add `title` and `symbolName` for it.
2. **`RootView.swift`**:
   - `TabView` block: add `LazyTab(tag: .music, ...)` between `live` and `bangumi` showing `MusicHomeView(repository: repository)`.
   - `sidebarTabs` static: insert `.music` between `.live` and `.bangumi`.
   - `handle(_ url:)` deep-link branch: remove the bangumi redirect, restore `router.open(.music)` + push `MusicRoute.player` for direct deep links.
3. **`ui-inventory.md`**: Update § 1.3 and § 1.4 to reflect 6 tabs (home / dynamic / live / **music** / bangumi / profile).
4. **No changes** to `AppRouter`, `MusicHomeView`, `MusicService`, `MusicPlayerView`, `PlayerController`.

### Phase 0b — Directory regrouping

Without touching xcodeproj (directory groups only), create:

```
ios/Paladala/Paladala/Music/
├── README.md                              (explains Phase 0 scope + future phases)
├── Models/
│   ├── BiliLyricTrack.swift               (moved from root Models.swift)
│   ├── BiliLyricLine.swift
│   └── BiliLyricInfo.swift
├── Parsers/
│   └── BiliLyricParser.swift              (moved from MusicService.swift)
├── ViewModels/
│   └── MusicViewModel.swift               (moved from MusicService.swift)
├── Views/
│   ├── MusicHomeView.swift                (public entry)
│   ├── MusicPlayerView.swift              (public entry)
│   └── Components/
│       ├── MusicCard.swift
│       ├── LyricScrollView.swift
│       ├── LyricLineView.swift
│       └── MusicProgressBar.swift
└── MusicModuleEntry.swift                 (Phase 1 placeholder; Phase 0 returns concrete views)
```

Move the actual code from `MusicHomeView.swift` and `MusicService.swift` into the new files. Update `Models.swift` to re-export the moved `BiliLyric*` types with `typealias` so existing call sites don't break.

This phase intentionally does **not** introduce protocol abstractions — those wait for Phase 1, when we know exactly which seam matters (e.g. whether `LyricSource` needs to be `Sendable`-isolated, whether `MusicPlaybackEngine` needs `AsyncStream` vs `Combine`).

### Phase 0c — Verification

- `xcodebuild -scheme Paladala -configuration Debug -destination 'generic/platform=iOS Simulator' build` passes.
- Manual smoke test plan (recorded in `Music/README.md`):
  - Music tab visible in tab bar at position 4.
  - Music tab loads grid of music videos (same content as pre-removal).
  - Tap card → push `MusicPlayerView`, plays audio, scrolls lyrics, tap lyric seeks.
  - `paladala://music` deep link lands on music tab (not bangumi).

## Out of Scope (deferred to Phase 1+)

- Karaoke-style syllable-level colouring (LyricKit `SyllableParser`)
- AMLL-style fluid background (MusicUI `ThemeBackgroundView`)
- Monet cover-art theme colour extraction (MusicKit `ThemeColorExtractor` + Core Image)
- Full protocol quartet (`MusicPlaybackEngine` / `LyricSource` / `ThemeColorExtractor` / `MusicModuleEntry`)
- Music queue / library / favourites / search pages (BBPlayer alignment)
- External playlist import (BV/AV/b23.tv/Netease/QQ)
- Offline download + embedded lyrics in `.m4a`
- Lock-screen + desktop lyrics

## Success Bar for Phase 0

1. Music tab back in tab bar with no behaviour change.
2. All music code lives under `ios/Paladala/Paladala/Music/` with sub-folders per concern.
3. Build is green; existing tests pass; no regressions in video player or other tabs.
4. `git diff --stat` shows: `Models.swift` (-20 / +5), `RootView.swift` (-10 / +25), `ui-inventory.md` (small edit), new files in `Music/`, two large deletions (`MusicHomeView.swift`, `MusicService.swift`).