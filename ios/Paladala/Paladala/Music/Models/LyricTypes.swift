import Foundation

// MARK: - Lyric types
//
// Moved from Models.swift as part of the music section
// reintroduction (Phase 0b — directory regrouping). Kept under the
// original names `BiliLyricTrack` / `BiliLyricLine` so the call
// sites in MusicHomeView, MusicService, and PlayerController stay
// unchanged.  `BiliLyricInfo` stays in Models.swift because the
// BilibiliAPIClient subtitle-listing DTOs are not music-specific
// (they are also surfaced on the VideoDetailView danmaku/subtitle
// path).
//
// Bilibili exposes per-video lyric tracks through `/x/player/v2`'s
// `subtitle.subtitles[]` array. The tracks arrive as either
// protocol-relative JSON (the AI-generated / "AI 字幕" case) or LRC
// plain text (the human-uploaded case). The Music view unifies both
// into a `BiliLyricTrack` so the playback view never has to think
// about the underlying encoding.

/// The fully-parsed lyric track the Music view scrolls. Stores
/// the per-line timings as an array of `BiliLyricLine` so the
/// player can binary-search for the active line in O(log n).
struct BiliLyricTrack: Hashable, Codable, Sendable {
    let lines: [BiliLyricLine]
    let language: String

    /// `true` if the track has at least one parseable line.
    var isEmpty: Bool { lines.isEmpty }

    /// The index of the line active at `time` (in seconds). Lines
    /// whose `startTime` is in the future are skipped; if no line
    /// is active yet, returns `0` so the UI can show the first
    /// line as "pending". Returns `lines.count - 1` for time
    /// past the last line so we don't crash the scroll view.
    func index(at time: Double) -> Int {
        guard !lines.isEmpty else { return 0 }
        // NaN comparisons always return false, so a non-finite
        // `time` would fall through to "line 0" but with the
        // active-line highlight sitting on the wrong row.
        // Treat any non-finite value as "not yet started".
        guard time.isFinite else { return 0 }
        // Upper-bound binary search: find the first line that starts
        // after `time`, then step back to the last active line. This
        // runs on every playback tick, so O(log n) avoids repeatedly
        // scanning long subtitle and lyric tracks.
        var lowerBound = 0
        var upperBound = lines.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if lines[midpoint].startTime <= time {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return max(0, lowerBound - 1)
    }
}

/// One line of timed lyrics.
struct BiliLyricLine: Hashable, Codable, Identifiable, Sendable {
    /// Position in the parent `BiliLyricTrack.lines` array. The
    /// line is `Identifiable` so a `ForEach` over the track can
    /// drive `ScrollViewReader` lookups.
    let startTime: Double
    let text: String
    /// Bilibili occasionally ships "metadata" lines (artist, album,
    /// composer) inside the same JSON / LRC document. They are not
    /// singable content, so the Music view downplays them — we
    /// surface a separate `isMetadata` flag.
    let isMetadata: Bool
    /// Stable parse-order identity for `ForEach`. Two lines can
    /// share the same `startTime` (chorus refrains with the same
    /// timestamp, dual-language lines that fire together, etc.) —
    /// using `startTime * 1000` as `id` made `ForEach` collide on
    /// duplicates, which broke `ScrollViewReader.scrollTo` and
    /// caused random "active line" mis-hits on iOS 18. The
    /// parser assigns a monotonically increasing `ordinal` so
    /// each line has a unique id that survives the post-sort.
    let ordinal: Int

    var id: Int { ordinal }
}