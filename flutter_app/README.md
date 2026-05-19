# BiliPai Flutter Port

This folder contains a first Flutter implementation slice for a multiplatform BiliPai client, using the existing Kotlin/Jetpack Compose app as the reference.

Implemented in this slice:

- Adaptive mobile/tablet shell with bottom navigation and navigation rail
- Home feed with category tabs, Today Watch-style recommendation queue, and video cards
- Video detail/player shell with playback actions, comments, danmaku/settings controls, and resume/progress presentation
- Dynamic, Live, Profile, Settings, and Plugin Center surfaces
- Repository boundary (`BiliPaiRepository`) with mock data so the UI can run before the production Bilibili API/client layer is ported
- Pure Flutter SDK dependencies only, to keep Android/iOS runner generation straightforward

## Generate platform runners

This repository environment did not have Flutter installed when this slice was added, so `android/` and `ios/` runner projects could not be generated here.

On a machine with Flutter installed:

```sh
cd flutter_app
flutter create --platforms=android,ios .
flutter pub get
```

## Build

Android:

```sh
flutter build apk
```

iOS, from macOS with Xcode installed:

```sh
flutter build ios
```

## Next porting steps

1. Replace `MockBiliPaiRepository` with a real API implementation ported from the Kotlin repository layer.
2. Add persisted settings using `shared_preferences` or a platform channel backed by the existing settings-core concepts.
3. Port video playback with `video_player` or a native player bridge, then add danmaku rendering above the player surface.
4. Move plugin parsing/evaluation into a shared Dart service and add import/update flows.
