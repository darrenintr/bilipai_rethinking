//
//  PluginModels.swift
//  Paladala
//
//  JSON-rule models for the plugin system. Mirrors the
//  Codable style of `SponsorBlockModels.swift` and relies on
//  `decodeIfPresent` everywhere so older / partial JSONs are
//  forward-compatible. All rule sub-blocks are optional so the
//  minimum viable plugin is just `id / name / scope / enabled`.
//

import Foundation

enum PluginScope: String, Codable, Sendable {
    case sponsorblock
    case cdn
    case danmaku
    case brightness
}

struct PluginSponsorRule: Codable, Equatable, Sendable {
    /// Local SponsorBlock-style skip segments added on top of
    /// the server-fetched set in `SponsorBlockManager`. Each
    /// is matched by `videoID`.
    struct ExtraSegment: Codable, Equatable, Sendable {
        let videoID: String
        let category: String
        let startTime: Double
        let endTime: Double
    }
    var extraSegments: [ExtraSegment]?
}

struct PluginCDNRule: Codable, Equatable, Sendable {
    /// If set, all media URLs for the active video are
    /// rewritten to this host regardless of the user's
    /// manual CDN selection. Empty string clears the pin.
    var pinHost: String?
}

struct PluginDanmakuRule: Codable, Equatable, Sendable {
    /// Cap on visible danmaku rows per frame (truncates by
    /// `time`).  `nil` = no cap.
    var maxDensity: Int?
    /// Any matching text is dropped at load time. Pre-compiled
    /// once by `PluginManager`.
    var filterRegex: String?
}

struct PluginBrightnessRule: Codable, Equatable, Sendable {
    /// 0.0 = fully transparent overlay (no dim), 1.0 = pitch
    /// black over the player. Applied as `Color.black.opacity(1 - level)`.
    var level: Double?
    /// 0.0 = no warm cast, 1.0 = strongly orange. Applied as
    /// `Color.orange.opacity(warmth * 0.25)` with `.softLight`.
    var warmth: Double?
}

struct PluginRules: Codable, Equatable, Sendable {
    var sponsorblock: PluginSponsorRule?
    var cdn: PluginCDNRule?
    var danmaku: PluginDanmakuRule?
    var brightness: PluginBrightnessRule?
}

struct Plugin: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var version: Int?
    var enabled: Bool
    var scope: [PluginScope]
    var rules: PluginRules?

    /// Disk-side origin used by `PluginsSettingsView` to
    /// distinguish user-pasted entries from bundled ones.
    /// `Codable` so `Plugin`'s auto-synthesised
    /// `init(from:) / encode(to:)` can encode the optional
    /// `origin` field (which is stripped at persist time
    /// anyway — see `PluginManager.persist(_:to:)`).
    enum Origin: Codable, Equatable, Sendable {
        case bundled
        case disk(filename: String)
    }
    var origin: Origin?
}
