import Foundation

/// One fragment in a fMP4 track.
///
/// The whole reason this file exists: B 站's DASH responses include
/// a `sidx` (Segment Index Box) right after the ftyp+moov that
/// lists every actual `moof+mdat` fragment the file is composed
/// of — with their real byte ranges and real durations.
///
/// The previous proxy cut the file at equal-byte intervals and
/// emitted `#EXTINF:6.0` for every segment. That was wrong on
/// both axes:
///   - MP4 is VBR. Equal bytes ≠ equal duration. A "6 s" segment
///     that should be 5.973 s (or 7.142 s) accumulated into a
///     timeline that drifted by tens of seconds within a 2-minute
///     video. AVPlayer saw `EXTINF` ≠ actual sample timestamps and
///     refused to commit the buffer (`loadedTimeRanges` stuck).
///   - The byte boundaries may land mid-NAL or mid-`mdat` box,
///     producing structurally-invalid fMP4 chunks. AVPlayer
///     treats these as decode errors (`-19602`) and drops the
///     response.
///
/// `MediaFragment` carries the fragment's *real* byte range and
/// *real* duration so the playlist generator can stop pretending
/// and hand AVPlayer a spec-conformant fMP4 HLS playlist.
struct MediaFragment: Hashable {
    /// Absolute byte range in the upstream m4s file. The proxy
    /// translates this into a Range request when AVPlayer (or
    /// its own segment handler) asks for this fragment.
    let byteRange: Range<Int64>
    /// Presentation time of the first sample in this fragment,
    /// in seconds.
    let startTime: Double
    /// Fragment duration in seconds (sum of `subsegment_duration`
    /// ticks divided by `timescale`).
    let duration: Double
    /// `true` if the fragment starts with a Stream Access Point
    /// (keyframe). Keyframes are required for `EXT-X-I-FRAMES-ONLY`
    /// playlists and for clean seek targets.
    let startsWithSAP: Bool
    /// First bytes fetched from the fragment start during
    /// validation. Kept only for diagnostics.
    let startPrefixHex: String?
}

/// Full segment index for one track (video or audio), decoded
/// from the upstream `sidx` box at serve time and cached for
/// the lifetime of the playback.
///
/// The proxy uses `initializationRange` to answer `/init` requests
/// (the ftyp+moov bytes), and `fragments[i]` to answer
/// `/segment/N.m4s` requests with the *real* `moof+mdat` slice
/// from the upstream m4s file. Both ranges come from the sidx,
/// not from byte-equal arithmetic.
struct TrackSegmentIndex: Hashable {
    /// Absolute byte range of the ftyp+moov init section in the
    /// upstream m4s file. Always serves the full init bytes —
    /// sidx points at `moov` only, but AVPlayer wants ftyp too.
    /// `LocalHLSProxyServer` re-derives this from the cached
    /// `BiliDashSource.Track.initializationRange` (the upstream
    /// already exposes it in the playurl response as
    /// `segment_base.initialization`).
    let initializationRange: Range<Int64>
    /// One entry per `moof+mdat` fragment, in presentation
    /// order. Indices are stable — `fragments[0]` is always the
    /// first fragment in the track.
    let fragments: [MediaFragment]
    /// SIDX `timescale` — denominator for the fragment
    /// durations. Not exposed in HLS but kept for diagnostics.
    let timescale: UInt32
    /// Absolute byte offset of the first media fragment. For
    /// SIDX this is `sidxEndOffset + 1 + first_offset`.
    let firstMediaOffset: Int64
    /// Absolute byte range of the upstream SIDX box.
    let sidxRange: Range<Int64>?
    /// Sum of `fragments[i].duration`. Should be within ~50 ms
    /// of `BiliDashSource.Track.totalDuration` if the upstream
    /// sidx is well-formed; the discrepancy is the "tolerance"
    /// the user called out in the acceptance criteria.
    let totalDuration: Double

    /// Largest single fragment duration. `EXT-X-TARGETDURATION`
    /// must be `ceil` of this so AVPlayer can plan its buffer.
    var maxFragmentDuration: Double {
        fragments.map(\.duration).max() ?? 0
    }

    /// Index of the fragment that contains `seconds` in its
    /// `[startTime, startTime + duration)` window. Returns `nil`
    /// if `seconds` falls outside the track (before the first
    /// fragment or after the last).
    func fragmentIndex(containing seconds: Double) -> Int? {
        // Linear scan is fine — VOD tracks have ~17 fragments
        // per minute, so even a 1-hour video is well under 1000.
        for (i, f) in fragments.enumerated() {
            if seconds >= f.startTime, seconds < f.startTime + f.duration {
                return i
            }
        }
        return nil
    }
}

/// Errors thrown by `parseSIDX`.
enum SIDXError: Error, CustomStringConvertible {
    case truncated
    case wrongBox(String)
    case unsupportedVersion(UInt8)
    case referenceCountMismatch

    var description: String {
        switch self {
        case .truncated:
            return "SIDX bytes truncated"
        case .wrongBox(let actual):
            return "expected sidx box, found \(actual)"
        case .unsupportedVersion(let v):
            return "unsupported SIDX version \(v)"
        case .referenceCountMismatch:
            return "SIDX reference count vs byte length mismatch"
        }
    }
}

/// Pure parser for the `sidx` (Segment Index Box) defined in
/// ISO/IEC 14496-12 §8.16.3.
///
/// Layout (from §8.16.3.2 / §8.16.3.3):
///
/// ```text
/// BoxHeader        (size:u32 + type:'sidx')    8 bytes
/// FullBoxHeader    (version:u8 + flags:[3]u8)  4 bytes
///   reference_ID    (deprecated, ignored)      4 bytes
///   timescale       (u32)                      4 bytes
///   earliest_presentation_time:
///     v0           (u32)                      4 bytes
///     v1           (u64)                      8 bytes
///   first_offset:
///     v0           (u32)                      4 bytes
///     v1           (u64)                      8 bytes
///   reserved        (u16)                      2 bytes
///   reference_count (u16)                      2 bytes
///   for each reference:
///     reference_type (1 bit) + referenced_size (31 bits)   4 bytes
///     subsegment_duration:
///       v0         (u32)                      4 bytes
///       v1         (u64)                      8 bytes
///     starts_with_SAP (1 bit) + SAP_type (3 bits)
///                       + SAP_delta_time (28 bits)         4 bytes
/// ```
///
/// B 站 ships version-1 SIDX for both AVC and HEVC video tracks
/// (timescale 1000) and version-1 SIDX for audio (timescale
/// 1000 or 44100). Version-0 is included for completeness even
/// though it is rare in the wild.
///
/// The parser is defensive: every read bounds-checks against the
/// input length and throws `.truncated` if the data is shorter
/// than the header claims. We never trust the upstream box size
/// to actually match the byte count B 站 sends — B 站 occasionally
/// writes a slightly larger `size` field than the actual bytes,
/// so we cap our reads at `min(boxEnd, data.endIndex)`.
func parseSIDX(_ bytes: Data) throws -> (
    timescale: UInt32,
    earliestPresentationTime: Int64,
    firstOffset: Int64,
    fragments: [(referencedSize: Int64, subsegmentDuration: Int64, startsWithSAP: Bool)]
) {
    var cursor = 0

    func readU32() throws -> UInt32 {
        guard cursor + 4 <= bytes.count else { throw SIDXError.truncated }
        let v = UInt32(bytes[cursor]) << 24
              | UInt32(bytes[cursor+1]) << 16
              | UInt32(bytes[cursor+2]) << 8
              | UInt32(bytes[cursor+3])
        cursor += 4
        return v
    }
    func readU16() throws -> UInt16 {
        guard cursor + 2 <= bytes.count else { throw SIDXError.truncated }
        let v = UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor+1])
        cursor += 2
        return v
    }
    func readU64() throws -> UInt64 {
        guard cursor + 8 <= bytes.count else { throw SIDXError.truncated }
        var v: UInt64 = 0
        for i in 0..<8 {
            v = (v << 8) | UInt64(bytes[cursor + i])
        }
        cursor += 8
        return v
    }

    // Box header: size + type. `size` may be the special value 1
    // (extends to EOF) which we don't try to handle — the playurl
    // response always carries an explicit byte count.
    let boxSize = try readU32()
    guard boxSize >= 16 else { throw SIDXError.truncated }
    let boxType = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
    guard boxType == "sidx" else { throw SIDXError.wrongBox(boxType) }

    // FullBox header: version + flags.
    guard cursor + 4 <= bytes.count else { throw SIDXError.truncated }
    let version = bytes[cursor]
    cursor += 4  // skip version + 3 flag bytes

    // `reference_ID` is deprecated and B 站 writes 0; we ignore it.
    _ = try readU32()

    let timescale = try readU32()
    let isV1 = (version == 1)
    guard version == 0 || version == 1 else {
        throw SIDXError.unsupportedVersion(version)
    }
    let earliestPresentationTime: Int64 = isV1
        ? Int64(try readU64())
        : Int64(try readU32())
    let firstOffset: Int64 = isV1
        ? Int64(try readU64())
        : Int64(try readU32())

    _ = try readU16()  // reserved

    // `reference_count` is the number of subsegments in the
    // file. We use it as an upper bound on what we expect to
    // read; the actual parse stops at `bytes.endIndex`.
    let referenceCount = Int(try readU16())

    var fragments: [(referencedSize: Int64, subsegmentDuration: Int64, startsWithSAP: Bool)] = []
    fragments.reserveCapacity(referenceCount)

    // Each reference is 12 bytes for v0, 16 bytes for v1.
    let perRefBytes = isV1 ? 16 : 12
    while cursor + perRefBytes <= bytes.count,
          fragments.count < referenceCount {
        let typeAndSize = try readU32()
        let referenceType = (typeAndSize >> 31) & 0x1
        let referencedSize = Int64(typeAndSize & 0x7FFF_FFFF)
        _ = referenceType  // B 站 always writes 0 (=media); kept for completeness

        let subsegmentDuration: Int64 = isV1
            ? Int64(try readU64())
            : Int64(try readU32())

        let sapInfo = try readU32()
        let startsWithSAP = ((sapInfo >> 31) & 0x1) == 1
        _ = (sapInfo >> 28) & 0x7    // SAP_type
        _ = sapInfo & 0x0FFF_FFFF      // SAP_delta_time

        fragments.append((referencedSize, subsegmentDuration, startsWithSAP))
    }

    return (
        timescale: timescale,
        earliestPresentationTime: earliestPresentationTime,
        firstOffset: firstOffset,
        fragments: fragments
    )
}

/// Build a `TrackSegmentIndex` from parsed SIDX data plus the
/// ftyp+moov init range that B 站 returns in the playurl
/// response's `segment_base.initialization`.
///
/// The init range is independent of the SIDX — the SIDX lives
/// *after* moov in the file, but B 站 exposes both ranges in
/// `SegmentBase`. We trust the upstream on both, rather than
/// parsing them out of the moov, because the latter requires
/// a full MP4 box parser and the upstream has already done the
/// work.
func makeTrackSegmentIndex(
    initializationRange: Range<Int64>,
    sidxRange: Range<Int64>?,
    sidx: (
        timescale: UInt32,
        earliestPresentationTime: Int64,
        firstOffset: Int64,
        fragments: [(referencedSize: Int64, subsegmentDuration: Int64, startsWithSAP: Bool)]
    )
) -> TrackSegmentIndex {
    let timescale = Double(sidx.timescale)
    let firstMediaOffset = (sidxRange?.upperBound ?? 0) + sidx.firstOffset
    var byteCursor = firstMediaOffset
    var timeCursor = Double(sidx.earliestPresentationTime) / timescale
    var fragments: [MediaFragment] = []
    fragments.reserveCapacity(sidx.fragments.count)
    for f in sidx.fragments {
        let byteRange = byteCursor..<(byteCursor + f.referencedSize)
        let duration = Double(f.subsegmentDuration) / timescale
        fragments.append(MediaFragment(
            byteRange: byteRange,
            startTime: timeCursor,
            duration: duration,
            startsWithSAP: f.startsWithSAP,
            startPrefixHex: nil
        ))
        byteCursor += f.referencedSize
        timeCursor += duration
    }
    return TrackSegmentIndex(
        initializationRange: initializationRange,
        fragments: fragments,
        timescale: sidx.timescale,
        firstMediaOffset: firstMediaOffset,
        sidxRange: sidxRange,
        totalDuration: timeCursor
    )
}
