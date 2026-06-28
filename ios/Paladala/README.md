# Paladala for iOS

Paladala is the native SwiftUI iPhone/iPad app in the
[`pure-bilibili-rethinking`](https://github.com/darrenintr/pure-bilibili-rethinking)
repository.

Implemented:

- SwiftUI app shell with iPhone `TabView` and iPad `NavigationSplitView`
- Liquid Glass navigation and controls on iOS 26, with a lightweight material fallback on earlier systems
- A content-first feed with selective tinting and no glass-on-glass stacking
- Public Bilibili API client for anonymous recommend, popular, search, video detail, play URL, and live room requests
- AVPlayer-backed video detail screen using returned public play URLs
- Public video comment loading on the video detail screen
- Dynamic, live, profile/settings, plugin-center-inspired surfaces
- App Intents for opening Paladala, searching, continuing the latest video, and adding a recent video to Watch Later
- `paladala://` deep links for home, dynamic, live, settings, and search
- Cached, downsampled cover images and lazy feed grids for smoother scrolling

Current limitations:

- Premium quality, authenticated history, and full danmaku rendering are not ported yet.
- QR login and local account persistence are implemented for the native iOS slice, but follow-feed/profile parity with the Android app is still incomplete.
- iOS builds require macOS with Xcode. This Linux container has no `xcodebuild` or Swift toolchain.
- The API client only uses public endpoints and does not attempt to bypass Bilibili access controls.

Build on macOS:

```sh
cd ios/Paladala
open Paladala.xcodeproj
```

Then select the `Paladala` scheme and an iPhone or iPad simulator.

Build unsigned IPA on GitHub Actions:

1. Open the `iOS Unsigned IPA` workflow in GitHub Actions.
2. Run it manually, or push a change under `ios/Paladala/`.
3. Download the `Paladala-unsigned-ipa` artifact.
4. Re-sign and install the Paladala IPA with your sideloading tool.

## Liquid Glass references

The visual hierarchy follows Apple’s official guidance:

- [Meet Liquid Glass (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/219/)
- [Build a SwiftUI app with the new design (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/323/)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
- [GlassEffectContainer](https://developer.apple.com/documentation/swiftui/glasseffectcontainer)
