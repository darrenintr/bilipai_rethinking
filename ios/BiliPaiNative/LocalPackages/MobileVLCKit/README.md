# Local SPM wrapper for MobileVLCKit

This local Swift Package exposes the prebuilt `MobileVLCKit` binary
framework to the BiliPaiNative iOS app via an `XCLocalSwiftPackageReference`
in `BiliPaiNative.xcodeproj/project.pbxproj`.

## Layout

```
LocalPackages/MobileVLCKit/
├── Package.swift                                  # the SPM manifest
├── README.md                                      # this file
└── Sources/MobileVLCKit/
    ├── .gitignore                                 # ignores the .xcframework
    └── MobileVLCKit.xcframework/                  # NOT committed; fetched
```

The `.xcframework` itself is **not** committed to the repo (it is
several hundred MB). It is downloaded by [`scripts/fetch_mobilelockit.sh`](../../../scripts/fetch_mobilelockit.sh)
into `Sources/MobileVLCKit/` before the iOS target can build.

## Local dev

Run the fetch script once after cloning (or any time you change
versions):

```bash
bash scripts/fetch_mobilelockit.sh
```

Then open the Xcode project. The local package resolves automatically
and `import MobileVLCKit` compiles in `VLCPlayerView.swift`.

## CI

The `ios-unsigned-ipa.yml` workflow runs the same fetch script in a
"Fetch MobileVLCKit xcframework" step before
`xcodebuild -resolvePackageDependencies` and the build.

## Why not remote SPM?

`videolan/vlc-ios` does not publish `MobileVLCKit` as a Swift Package
product (the project is CocoaPods-only). The previous attempt
(commit `1a95b9f6`) used an `XCRemoteSwiftPackageReference` to that
repo and was reverted in `ec978c8c` with the SPM product error
"Missing package product MobileVLCKit". This local-binary-target
arrangement is the only zero-CocoaPods path that produces a
`canImport(MobileVLCKit)`-true compile.
