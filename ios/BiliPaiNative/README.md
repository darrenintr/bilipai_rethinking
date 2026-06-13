# BiliPai Native iOS

This is a native SwiftUI iPhone/iPadOS port slice for BiliPai.

Implemented:

- SwiftUI app shell with iPhone `TabView` and iPad `NavigationSplitView`
- BiliPai visual language: Bili pink accent, compact cards, rounded 8pt surfaces, grouped settings
- Public Bilibili API client for anonymous recommend, popular, search, video detail, play URL, and live room requests
- AVPlayer-backed video detail screen using returned public play URLs
- Public video comment loading on the video detail screen
- Dynamic, live, profile/settings, plugin-center-inspired surfaces
- App Intents for opening BiliPai, searching, continuing the latest video, and adding a recent video to Watch Later
- `bilipai://` deep links for home, dynamic, live, settings, and search

Current limitations:

- Login, cookies, WBI signing, premium quality, authenticated history, and full danmaku rendering are not ported yet.
- iOS builds require macOS with Xcode. This Linux container has no `xcodebuild` or Swift toolchain.
- The API client only uses public endpoints and does not attempt to bypass Bilibili access controls.

Build on macOS:

```sh
cd ios/BiliPaiNative
open BiliPaiNative.xcodeproj
```

Then select the `BiliPaiNative` scheme and an iPhone or iPad simulator.
