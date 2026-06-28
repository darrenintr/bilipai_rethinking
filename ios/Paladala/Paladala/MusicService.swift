import Foundation

// MARK: - LRC / JSON lyric parser
//
// Bilibili serves two lyric encodings on the same `/x/player/v2`
// endpoint:
//   * JSON  — `{"body":[{"from":0.0,"to":2.5,"content":"…"}, …]}`
//   * LRC   — `[mm:ss.xx]lyric text` lines
//
// The Music view must accept either; we sniff the first
// non-whitespace byte to pick a parser. The output is a
// `BiliLyricTrack` whose `lines` are sorted by `startTime`
// ascending so `index(at:)` can short-circuit on a linear
// from-the-end walk.
enum BiliLyricParser {

    /// Parse the lyric body. The caller passes the raw text the
    /// API returned (JSON or LRC) and a `language` label for
    /// display. We return an empty track when neither parser
    /// yields anything — that lets the UI render a clean
    /// "这首歌暂无歌词" placeholder rather than crashing the
    /// scroll view.
    static func parse(text raw: String, language: String) -> BiliLyricTrack? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("{") {
            return parseJSON(trimmed, language: language)
                ?? parseLRC(trimmed, language: language) // tolerate
                                                          // JSON-ish LRC
        }
        if trimmed.hasPrefix("[") {
            return parseLRC(trimmed, language: language)
        }
        // Default to LRC — most B站 lyric tracks are LRC.
        return parseLRC(trimmed, language: language)
    }

    // MARK: JSON

    /// Parse a Bilibili-style JSON lyric document.
    ///
    /// Example payload:
    ///   {
    ///     "body": [
    ///       { "from": 0.0,  "to": 2.5,  "content": "歌词" },
    ///       { "from": 2.5,  "to": 5.0,  "content": "下一句" }
    ///     ]
    ///   }
    private static func parseJSON(_ text: String, language: String) -> BiliLyricTrack? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let envelope = try? JSONDecoder().decode(LyricJSONEnvelope.self, from: data) else {
            return nil
        }
        // `ordinal` must be unique across the track. Assign it at
        // parse time so subsequent `.sorted { ... }` cannot shuffle
        // identities.
        var ordinalCounter = 0
        let lines = envelope.body
            .compactMap { entry -> BiliLyricLine? in
                let cleaned = entry.content
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { return nil }
                let line = BiliLyricLine(
                    startTime: entry.from,
                    text: cleaned,
                    isMetadata: false,
                    ordinal: ordinalCounter
                )
                ordinalCounter += 1
                return line
            }
            .sorted { $0.startTime < $1.startTime }
        return BiliLyricTrack(lines: lines, language: language)
    }

    // MARK: LRC
    //
    // LRC grammar we accept:
    //   * `[mm:ss.xx]text`           single timestamp
    //   * `[mm:ss.xxx]text`          millisecond precision
    //   * `[mm:ss.xx][mm:ss.xx]text` repeated lines (one entry per
    //                                  timestamp, same text) — used
    //                                  for chorus refrains
    //   * `[ar:…]`, `[ti:…]`, `[al:…]` metadata tags — surfaced
    //     as `isMetadata: true` lines so the player can render
    //     them in a muted style and the auto-scroll never
    //     accidentally lands on them as the "active" line.
    //
    // We deliberately do NOT implement the full LRC spec
    // (attribute quoting, ID tags, etc.) — Bilibili's
    // human-uploaded lyrics stick to the subset above.

    private static let lrcLineRegex: NSRegularExpression = {
        // Match `[mm:ss.xx]` (1- or 2-digit minutes, 2-digit seconds,
        // 1-3 fractional digits). Capture each timestamp.
        let pattern = #"\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#
        // The pattern is a compile-time constant that has compiled
        // successfully on every iOS version we ship, but `try!`
        // traps the *entire process* on a future regex-grammar
        // tightening.  Fall back to a never-matching regex so a
        // compile failure surfaces as "no lyric" instead of a crash.
        do {
            return try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            assertionFailure("BiliLyricParser.lrcLineRegex failed to compile: \(error)")
            // `.{99999}` requires 99 999+ chars to match — effectively
            // a no-op for any real lyric line.
            return try! NSRegularExpression(pattern: ".{99999}", options: [])
        }
    }()

    private static let metadataRegex: NSRegularExpression = {
        let pattern = #"\[(ar|ti|al|by|offset|length):[^\]]*\]"#
        do {
            return try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        } catch {
            assertionFailure("BiliLyricParser.metadataRegex failed to compile: \(error)")
            return try! NSRegularExpression(pattern: ".{99999}", options: [])
        }
    }()

    private static func parseLRC(_ text: String, language: String) -> BiliLyricTrack? {
        var lines: [BiliLyricLine] = []
        // `ordinal` is the parse-order identity. Two LRC lines can
        // share a timestamp (a chorus refrain `[00:30.00][00:30.00]x`
        // or two singers starting in unison) — without a per-line
        // counter those would collide in `BiliLyricLine.id` and
        // break `ForEach` / `ScrollViewReader.scrollTo`.
        var ordinalCounter = 0
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            // Find all timestamp matches on the line.
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            let matches = lrcLineRegex.matches(in: line, options: [], range: range)
            guard !matches.isEmpty else { continue }
            // The lyric text is whatever follows the last timestamp.
            let lastMatch = matches.last!
            let textStart = lastMatch.range.location + lastMatch.range.length
            let lyricText: String
            if textStart < nsLine.length {
                lyricText = nsLine.substring(from: textStart)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                lyricText = ""
            }
            let isMetadata = metadataRegex.firstMatch(
                in: line, options: [], range: range
            ) != nil
            for match in matches {
                let minutesStr = nsLine.substring(with: match.range(at: 1))
                let secondsStr = nsLine.substring(with: match.range(at: 2))
                let fracStr: String = {
                    let r = match.range(at: 3)
                    if r.location == NSNotFound { return "0" }
                    return nsLine.substring(with: r)
                }()
                guard
                    let minutes = Int(minutesStr),
                    let seconds = Int(secondsStr)
                else { continue }
                // Normalise the fraction to milliseconds regardless
                // of digit count (".5" → 500, ".50" → 500, ".505" → 505).
                let fracValue: Int = {
                    if fracStr.isEmpty { return 0 }
                    let padded: String
                    if fracStr.count == 1 { padded = fracStr + "00" }
                    else if fracStr.count == 2 { padded = fracStr + "0" }
                    else { padded = String(fracStr.prefix(3)) }
                    return Int(padded) ?? 0
                }()
                let startTime = Double(minutes * 60 + seconds) + Double(fracValue) / 1000.0
                lines.append(BiliLyricLine(
                    startTime: startTime,
                    text: lyricText.isEmpty ? "♪" : lyricText,
                    isMetadata: isMetadata,
                    ordinal: ordinalCounter
                ))
                ordinalCounter += 1
            }
        }
        let sorted = lines.sorted { $0.startTime < $1.startTime }
        if sorted.isEmpty { return nil }
        return BiliLyricTrack(lines: sorted, language: language)
    }
}

// MARK: - JSON envelope
//
// Private to this file. The shape is the exact one Bilibili ships
// in its `subtitle_url` JSON files; the rest of the app does not
// need to see it.

private struct LyricJSONEnvelope: Decodable {
    let body: [LyricJSONEntry]
}

private struct LyricJSONEntry: Decodable {
    let from: Double
    let to: Double
    let content: String
}

// MARK: - Music view model
//
// Loads the music region feed and (lazily) the lyric track for
// the currently-playing video. The lyric is fetched on demand by
// `MusicPlayerView` so the list view never has to pay the cost of
// a second round-trip per row.
@MainActor
final class MusicViewModel: ObservableObject {
    @Published private(set) var videos: [BiliVideo] = []
    @Published private(set) var isLoading: Bool = false
    @Published var errorMessage: String?

    func load(repository: PaladalaRepository) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let next = try await repository.musicVideos(page: 1)
            videos = next
        } catch {
            errorMessage = "\(L10n.music.networkError)：\(error.localizedDescription)"
            videos = []
        }
    }

    func refresh(repository: PaladalaRepository) async {
        await load(repository: repository)
    }
}
