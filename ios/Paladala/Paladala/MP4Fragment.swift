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
    case unexpectedBox(String)
    case unsupportedVersion(UInt8)
    case referenceCountMismatch
    case invalidBoxSize(UInt64)

    var description: String {
        switch self {
        case .truncated:
            return "SIDX bytes truncated"
        case .unexpectedBox(let actual):
            return "expected sidx box, found \(actual)"
        case .unsupportedVersion(let v):
            return "unsupported SIDX version \(v)"
        case .referenceCountMismatch:
            return "SIDX reference count vs byte length mismatch"
        case .invalidBoxSize(let size):
            return "invalid SIDX box size \(size)"
        }
    }
}

struct SIDXReference: Hashable {
    let referenceType: UInt32
    let referencedSize: UInt32
    let subsegmentDuration: UInt32
    let startsWithSAP: Bool
    let sapType: UInt8
    let sapDeltaTime: UInt32
}

struct SIDX: Hashable {
    let absoluteOffset: UInt64
    let boxSize: UInt64
    let headerSize: UInt64
    let version: UInt8
    let referenceID: UInt32
    let timescale: UInt32
    let earliestPresentationTime: UInt64
    let firstOffset: UInt64
    let references: [SIDXReference]

    var sidxEndOffset: UInt64 {
        absoluteOffset + boxSize
    }

    var firstMediaOffset: UInt64 {
        sidxEndOffset + firstOffset
    }
}

private struct ByteCursor {
    private let data: Data
    private var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset + 1 <= data.count else { throw SIDXError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16BE() throws -> UInt16 {
        guard offset + 2 <= data.count else { throw SIDXError.truncated }
        let value = UInt16(data[offset]) << 8
            | UInt16(data[offset + 1])
        offset += 2
        return value
    }

    mutating func readUInt32BE() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw SIDXError.truncated }
        let value = UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
        offset += 4
        return value
    }

    mutating func readUInt64BE() throws -> UInt64 {
        guard offset + 8 <= data.count else { throw SIDXError.truncated }
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(data[offset + i])
        }
        offset += 8
        return value
    }

    mutating func readFourCC() throws -> String {
        let bytes = try readBytes(count: 4)
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw SIDXError.truncated
        }
        let range = offset..<(offset + count)
        offset += count
        return data.subdata(in: range)
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
///     subsegment_duration (u32)                           4 bytes
///     starts_with_SAP (1 bit) + SAP_type (3 bits)
///                       + SAP_delta_time (28 bits)         4 bytes
/// ```
///
/// B 站 ships version-1 SIDX for both AVC and HEVC video tracks
/// (timescale 1000) and version-1 SIDX for audio (timescale
/// 1000 or 44100). Version-0 is included for completeness even
/// though it is rare in the wild.
///
/// `data` must start at the first byte of the SIDX box header
/// (`size`), not after the header. `absoluteOffset` is the
/// SIDX box's absolute byte offset in the upstream resource.
func parseSIDX(_ data: Data, absoluteOffset: UInt64) throws -> SIDX {
    var cursor = ByteCursor(data)

    let size32 = try cursor.readUInt32BE()
    let type = try cursor.readFourCC()
    guard type == "sidx" else {
        throw SIDXError.unexpectedBox(type)
    }

    let headerSize: UInt64
    let boxSize: UInt64
    if size32 == 1 {
        boxSize = try cursor.readUInt64BE()
        headerSize = 16
    } else {
        boxSize = UInt64(size32)
        headerSize = 8
    }
    guard boxSize >= headerSize + 24 else {
        throw SIDXError.invalidBoxSize(boxSize)
    }
    guard UInt64(data.count) >= boxSize else {
        throw SIDXError.truncated
    }

    let version = try cursor.readUInt8()
    _ = try cursor.readBytes(count: 3)
    let referenceID = try cursor.readUInt32BE()
    let timescale = try cursor.readUInt32BE()

    let earliestPresentationTime: UInt64
    let firstOffset: UInt64
    switch version {
    case 0:
        earliestPresentationTime = UInt64(try cursor.readUInt32BE())
        firstOffset = UInt64(try cursor.readUInt32BE())
    case 1:
        earliestPresentationTime = try cursor.readUInt64BE()
        firstOffset = try cursor.readUInt64BE()
    default:
        throw SIDXError.unsupportedVersion(version)
    }

    _ = try cursor.readUInt16BE()
    let referenceCount = Int(try cursor.readUInt16BE())

    var references: [SIDXReference] = []
    references.reserveCapacity(referenceCount)
    for _ in 0..<referenceCount {
        let rawSize = try cursor.readUInt32BE()
        let referenceType = rawSize >> 31
        let referencedSize = rawSize & 0x7FFF_FFFF
        let subsegmentDuration = try cursor.readUInt32BE()
        let sap = try cursor.readUInt32BE()
        let startsWithSAP = ((sap >> 31) & 1) == 1
        let sapType = UInt8((sap >> 28) & 0x7)
        let sapDeltaTime = sap & 0x0FFF_FFFF
        references.append(SIDXReference(
            referenceType: referenceType,
            referencedSize: referencedSize,
            subsegmentDuration: subsegmentDuration,
            startsWithSAP: startsWithSAP,
            sapType: sapType,
            sapDeltaTime: sapDeltaTime
        ))
    }

    return SIDX(
        absoluteOffset: absoluteOffset,
        boxSize: boxSize,
        headerSize: headerSize,
        version: version,
        referenceID: referenceID,
        timescale: timescale,
        earliestPresentationTime: earliestPresentationTime,
        firstOffset: firstOffset,
        references: references
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
    sidx: SIDX
) -> TrackSegmentIndex {
    let timescale = Double(sidx.timescale)
    let firstMediaOffset = Int64(sidx.firstMediaOffset)
    var byteCursor = firstMediaOffset
    var timeCursor = Double(sidx.earliestPresentationTime) / timescale
    var fragments: [MediaFragment] = []
    fragments.reserveCapacity(sidx.references.count)
    for reference in sidx.references {
        let referencedSize = Int64(reference.referencedSize)
        let byteRange = byteCursor..<(byteCursor + referencedSize)
        let duration = Double(reference.subsegmentDuration) / timescale
        fragments.append(MediaFragment(
            byteRange: byteRange,
            startTime: timeCursor,
            duration: duration,
            startsWithSAP: reference.startsWithSAP,
            startPrefixHex: nil
        ))
        byteCursor += referencedSize
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
