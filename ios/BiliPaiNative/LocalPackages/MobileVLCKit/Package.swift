// swift-tools-version:5.7
import PackageDescription

// Local Swift Package wrapper around the prebuilt MobileVLCKit
// `.xcframework`. Used by `ios/BiliPaiNative/BiliPaiNative.xcodeproj`
// via an `XCLocalSwiftPackageReference` so the iOS app can `import
// MobileVLCKit` without going through CocoaPods (the upstream
// `videolan/vlc-ios` repo does not publish MobileVLCKit as a Swift
// Package product, which is why the previous SPM attempt in commit
// 1a95b9f6 had to be reverted in ec978c8c).
//
// The `.xcframework` itself is NOT committed — it is downloaded by
// `scripts/fetch_mobilelockit.sh` into `Sources/MobileVLCKit/`. The
// `Sources/MobileVLCKit/.gitignore` keeps the artifact out of the
// repo; the Package.swift here stays tiny so a future version bump
// is a one-line change.
let package = Package(
    name: "MobileVLCKit",
    platforms: [
        // The host app's `IPHONEOS_DEPLOYMENT_TARGET` is 18.0; we
        // declare 15.0 here to match the minimum iOS version VLC
        // ships xcframework slices for. A future bump should match
        // the host target.
        .iOS(.v15)
    ],
    products: [
        .library(name: "MobileVLCKit", targets: ["MobileVLCKit"])
    ],
    targets: [
        .binaryTarget(
            name: "MobileVLCKit",
            path: "Sources/MobileVLCKit/MobileVLCKit.xcframework"
        )
    ]
)
