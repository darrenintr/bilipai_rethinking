# Flutter Migration Map (Incremental)

Last updated: 2026-05-19

## Scope

This plan starts a Flutter multiplatform app (`flutter_app/`) while keeping the existing Android app stable.

## Current implementation status

✅ Implemented in this repo slice:
- Flutter app shell (`BiliPaiApp`) with Material 3 theme.
- Home feature slice with local feed repository contract + stub implementation.
- Settings feature slice with a migrated playback speed policy equivalent.
- Shared formatting utilities and baseline widget test.

## Milestones

1. Bootstrap + first runnable vertical slice (done)
   - Home list, navigation, settings shell.
2. Domain extraction
   - Rebuild settings/network/feed policies as pure Dart modules.
3. Data integration
   - Replace local feed repository with remote API and auth/session handling.
4. Platform services
   - Playback, background audio, notifications, deep links.
5. Hard features
   - Danmaku, casting, plugin compatibility.

## Mapping from current Kotlin modules

- `settings-core/` -> `flutter_app/lib/domain/settings/*`
- `network-core/` -> `flutter_app/lib/domain/network/*`
- `app/core/store`, `app/domain/*` -> `flutter_app/lib/domain/*`
- `app/feature/*` -> `flutter_app/lib/features/*`

## Non-goals for current slice

- No replacement of existing Android production app.
- No player, cast, or plugin runtime migration yet.
