//
//  FFmpegDemuxer.swift
//  Paladala
//
//  Swift wrapper around FFmpeg's libavformat demuxer.  Owns the
//  AVFormatContext + codec parameters for a single media file and
//  yields AVPacket objects on demand.
//
//  Threading: `@unchecked Sendable` so it can move across actor
//  boundaries (see FFmpegPlaybackEngine).  All FFmpeg interaction
//  happens on the engine's serial executor — libavformat is not
//  reentrant across shared objects.
//
//  Replaces the demuxer role AVPlayer previously owned, so the
//  iOS 26 Beta MetalPerformanceShadersGraph accessQueue trap can
//  no longer fire from our playback path.
//
//  Swift 6 type access
//  -------------------
//  FFmpeg forward-declares its structs (`typedef struct
//  AVFormatContext AVFormatContext;`) and Xcode 16 / Swift 6
//  imports each as a *zero-field value type*.  So we cannot read
//  members like `ctx->duration` or `streams[i]->codecpar` from
//  Swift at all.  The native C functions we actually need are
//  too few to wrangle an `@_alwaysEmitIntoClient` workaround,
//  so we rely on the `PaladalaFFmpegShim.h` C API instead:
//  call the `paladala_*` helpers for any field we need, treat
//  FFmpeg pointers as `OpaquePointer` everywhere else.
//

import Foundation
import CoreMedia

/// Errors surfaced from the FFmpeg demuxer.  Mirrors the project's
/// existing `PlayerPlaybackError` style but scoped to FFmpeg so the
/// engine can route them without leaking libavformat error codes
/// into the UI layer.
enum FFmpegDemuxerError: Error, Equatable {
    /// File not found / unreadable / avformat_open_input failed.
    case openFailed(code: Int32)
    /// No stream could be identified as video — almost certainly
    /// a container FFmpeg's `--enable-demuxer` list doesn't cover.
    case noVideoStream
    /// SPS/PPS extraction failed (H.264 / HEVC).  Without these the
    /// VideoToolbox session can't be created, so this is fatal.
    case parameterSetExtractionFailed
    /// av_read_frame returned AVERROR_EOF — stream has ended.
    case endOfStream
    /// av_read_frame failed for some other reason (network drop,
    /// corrupted segment, etc.).  `code` is the libavformat AVERROR.
    case readFailed(code: Int32)
}

/// Wrapper around libavformat.  Holds the AVFormatContext and the
/// index of the video stream (audio is found but not yet consumed —
/// Phase 2 will route audio packets).
final class FFmpegDemuxer: @unchecked Sendable {

    // MARK: state

    /// Held as `UnsafeMutableRawPointer` because Swift sees the
    /// underlying `AVFormatContext` as a zero-field struct (see
    /// file-level note).  C code treats it as a `AVFormatContext*`
    /// throughout.  The lifetype is `close()` — we own the
    /// libavformat allocation.
    private var fmtCtx: UnsafeMutableRawPointer?

    /// Index of the video stream inside `fmtCtx->streams`.  -1
    /// when no video stream could be found.
    private var videoStreamIndex: Int32 = -1

    /// Borrowed pointer to the video stream's codec parameters.
    /// Owned by the format context; valid only while the demuxer
    /// is open.  Held as `UnsafeMutablePointer<AVCodecParameters>?`
    /// because the shim functions in `PaladalaFFmpegShim.h` all
    /// take `AVCodecParameters*` (Swift 6 sees that as
    /// `UnsafeMutablePointer<AVCodecParameters>?` because of the
    /// empty-struct import quirk).
    private var videoCodecPar: UnsafeMutablePointer<AVCodecParameters>?

    /// The duration of the longest stream in `AV_TIME_BASE` units
    /// (microseconds).  Set on `open()`.
    private var durationUs: Int64 = 0

    // MARK: lifecycle

    init() {
        // No-op; init the FFmpeg internals once globally in
        // `FFmpegPlaybackEngine.bootstrap()` before any demuxer
        // is constructed.
    }

    deinit {
        close()
    }

    /// Open a local file and locate the video stream.  Throws
    /// `FFmpegDemuxerError` on failure; on success the demuxer is
    /// ready for `readPacket()`.
    func open(fileURL: URL) throws {
        close()

        // `avformat_open_input` takes `AVFormatContext **` — Swift
        // imports that as
        // `UnsafeMutablePointer<UnsafeMutablePointer<AVFormatContext>?>`
        // because of the empty-struct import quirk.  We allocate
        // the inner pointer as an `OpaquePointer?` and bit-cast
        // it to the exact nested-pointer type the function expects.
        // Bit-casting is safe here because both types are binary-
        // compatible on Apple Silicon (raw pointer to raw pointer)
        // — Swift's type checker can't see the equivalence, but
        // the C compiler will.
        var ctxOpaque: OpaquePointer?
        let openResult = withUnsafeMutablePointer(
            to: &ctxOpaque
        ) { p -> Int32 in
            let outer = unsafeBitCast(
                p,
                to: UnsafeMutablePointer<UnsafeMutablePointer<AVFormatContext>?>.self
            )
            return avformat_open_input(outer, fileURL.path, nil, nil)
        }
        guard openResult >= 0, let ctxOpaque else {
            throw FFmpegDemuxerError.openFailed(code: openResult)
        }
        self.fmtCtx = UnsafeMutableRawPointer(ctxOpaque)

        // Pull stream info (this parses the container; fast for MP4,
        // slow for HLS because the playlist has to be fetched).
        // Swift 6 imports `avformat_find_stream_info`'s
        // `AVFormatContext*` as `UnsafeMutablePointer<AVFormatContext>?`
        // so rebind the OpaquePointer first.
        let ctxPtr = UnsafeMutableRawPointer(ctxOpaque)
            .assumingMemoryBound(to: AVFormatContext.self)
        let infoResult = avformat_find_stream_info(ctxPtr, nil)
        guard infoResult >= 0 else {
            close()
            throw FFmpegDemuxerError.openFailed(code: infoResult)
        }

        // Find the best video stream.  Returns -1 if no video
        // stream is present; we want the highest-resolution match
        // when multiple video tracks exist.  We pass `nil` for the
        // AVCodec** output — we don't need the decoder pointer
        // (we look up the codec ourselves from codecpar.codec_id)
        // and Swift 6's struct import for AVCodec** is awkward.
        let bestVideo = av_find_best_stream(
            ctxPtr, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0
        )
        guard bestVideo >= 0 else {
            close()
            throw FFmpegDemuxerError.noVideoStream
        }
        self.videoStreamIndex = bestVideo

        // Pull codec params via the shim helper so Swift never
        // touches `ctx->streams[]->codecpar` directly.  We hold
        // the borrowed pointer; it lives as long as the format
        // context does.  Shim expects `AVFormatContext*` which
        // Swift imports as `UnsafeMutablePointer<AVFormatContext>?`,
        // so lift ctxPtr (non-optional) to optional.
        let par = paladala_format_stream_codecpar(
            ctxPtr as UnsafeMutablePointer<AVFormatContext>?,
            UInt32(bestVideo)
        )
        self.videoCodecPar = par

        // Duration (microseconds, AV_TIME_BASE).  For VOD streams
        // this is reliable; for live HLS it's AV_NOPTS_VALUE and
        // Phase 1 will fall back to last-seen PTS.
        let dur = paladala_format_duration(
            ctxPtr as UnsafeMutablePointer<AVFormatContext>?
        )
        self.durationUs = (dur == Int64(AV_NOPTS_VALUE)) ? 0 : dur
    }

    /// Release the AVFormatContext.  Safe to call multiple times.
    func close() {
        if let ctxRaw = fmtCtx {
            // `avformat_close_input` takes `AVFormatContext**` —
            // bit-cast our raw pointer slot to the exact nested-
            // pointer type Swift's bridge expects.  Safe because
            // both layouts are raw pointers (no addressable state).
            var opaque: OpaquePointer? = OpaquePointer(ctxRaw)
            withUnsafeMutablePointer(to: &opaque) { p in
                let outer = unsafeBitCast(
                    p,
                    to: UnsafeMutablePointer<UnsafeMutablePointer<AVFormatContext>?>.self
                )
                avformat_close_input(outer)
            }
        }
        fmtCtx = nil
        videoStreamIndex = -1
        // videoCodecPar is borrowed — not freed here; it dies with the
        // format context we just released.
        videoCodecPar = nil
        durationUs = 0
    }

    // MARK: accessors

    /// Total media duration in seconds.  Returns `nil` when FFmpeg
    /// couldn't determine the duration (typical for live streams).
    var durationSeconds: Double? {
        guard durationUs > 0 else { return nil }
        return Double(durationUs) / Double(AV_TIME_BASE)
    }

    /// Borrowed pointer to the video stream's codec parameters.
    /// Owned by the format context — only valid while the demuxer
    /// is open.  Phase 1 may hand this to VideoToolboxDecoder for
    /// HEVC profile/level reads; Phase 0 doesn't need it.
    var videoCodecParameters: UnsafeMutablePointer<AVCodecParameters>? {
        videoCodecPar
    }

    /// Codec ID of the video stream (H.264 / HEVC / …).
    var videoCodecID: AVCodecID {
        guard let par = videoCodecPar else { return AV_CODEC_ID_NONE }
        return paladala_codecpar_codec_id(par)
    }

    /// Codec tag — useful when constructing an MVC/HEVC VideoToolbox
    /// session that wants the container-side FourCC.
    var videoCodecTag: UInt32 {
        guard let par = videoCodecPar else { return 0 }
        return paladala_codecpar_codec_tag(par)
    }

    // MARK: parameter set extraction (for VideoToolbox)

    /// Extract the SPS/PPS (H.264) or VPS/SPS/PPS (HEVC) parameter
    /// sets from the container's extradata.  FFmpeg has already
    /// parsed these into `codecpar->extradata` for MP4/M4V; for
    /// HLS we fall back to parsing them out of the first keyframe.
    ///
    /// Returns one buffer per parameter set.  The first buffer
    /// is always the SPS-equivalent (for HEVC this is the VPS).
    func extractParameterSets() throws -> [Data] {
        guard let par = videoCodecPar else {
            throw FFmpegDemuxerError.parameterSetExtractionFailed
        }
        guard let extradataRaw = paladala_codecpar_extradata(par) else {
            throw FFmpegDemuxerError.parameterSetExtractionFailed
        }
        let extradataSize = paladala_codecpar_extradata_size(par)
        guard extradataSize > 0 else {
            throw FFmpegDemuxerError.parameterSetExtractionFailed
        }

        // Copy the bytes into Swift-managed storage immediately —
        // `extradataRaw` is borrowed from the format context and we
        // don't want to keep it pinned across `readPacket()` calls.
        let buffer = UnsafeBufferPointer(
            start: extradataRaw, count: extradataSize
        )
        let bytes = Data(buffer: buffer)

        // The AVCC/HVCC layout puts each parameter set as
        // [4-byte length big-endian][N bytes of NALU].  Walk the
        // buffer and split.  Same format VideoToolbox consumes
        // when given an AVCC-style configuration record.
        var parameterSets: [Data] = []
        var cursor = 0
        while cursor + 4 <= bytes.count {
            let length = (Int(bytes[cursor]) << 24)
                      | (Int(bytes[cursor + 1]) << 16)
                      | (Int(bytes[cursor + 2]) << 8)
                      |  Int(bytes[cursor + 3])
            cursor += 4
            guard length > 0, cursor + length <= bytes.count else { break }
            parameterSets.append(bytes.subdata(in: cursor..<(cursor + length)))
            cursor += length
        }

        guard !parameterSets.isEmpty else {
            throw FFmpegDemuxerError.parameterSetExtractionFailed
        }
        return parameterSets
    }

    // MARK: packet reading

    /// Read the next packet from the container.  The caller is
    /// responsible for `av_packet_unref`ing the returned AVPacket.
    ///
    /// Filters out non-video packets — Phase 0 has no audio path
    /// yet.  Phase 2 will route audio packets to the audio decoder.
    func readPacket() throws -> AVPacket {
        guard let fmtCtxRaw = fmtCtx else {
            throw FFmpegDemuxerError.readFailed(code: -1)
        }
        // `av_read_frame` takes `AVFormatContext*` which Swift 6
        // imports as `UnsafeMutablePointer<AVFormatContext>?` because
        // of the empty-struct import quirk.  We rebind the raw
        // pointer to that type so the call type-matches.  Lifetime
        // is implicit — the underlying allocation is owned by
        // FFmpeg and stays put across the call.
        let ctxPtr = fmtCtxRaw
            .assumingMemoryBound(to: AVFormatContext.self)
        var packet = AVPacket()
        let result = av_read_frame(ctxPtr, &packet)
        if result < 0 {
            if result == AVERROR_EOF {
                throw FFmpegDemuxerError.endOfStream
            }
            throw FFmpegDemuxerError.readFailed(code: result)
        }

        // Skip non-video packets.  Loop until we find a video
        // packet or hit EOF — audio packets usually arrive close
        // to their video counterparts so the extra iteration cost
        // is small and Phase 0 has no place to put audio frames.
        if paladala_packet_stream_index(&packet) != videoStreamIndex {
            av_packet_unref(&packet)
            return try readPacket()
        }

        return packet
    }

    /// Seek to `seconds` in the container.  Phase 0 implementation
    /// seeks to the nearest keyframe at-or-before the target.
    /// Phase 2 will add precise seeking once audio is in.
    func seek(toSeconds seconds: Double) -> Bool {
        guard let fmtCtxRaw = fmtCtx, videoStreamIndex >= 0 else {
            return false
        }
        // Reinterpret the raw pointer as a typed format-context
        // pointer — matches what Swift 6's bridge expects for
        // `AVFormatContext*`.
        let ctxPtr = fmtCtxRaw
            .assumingMemoryBound(to: AVFormatContext.self)

        // Pull the stream's time base via the shim.  The shim is
        // declared as taking `UnsafeMutablePointer<AVFormatContext>?`
        // (Swift 6's import of `AVFormatContext *`) so lift our
        // non-optional typed pointer.
        let tb = paladala_format_stream_time_base(
            ctxPtr as UnsafeMutablePointer<AVFormatContext>?,
            UInt32(videoStreamIndex)
        )
        guard tb.den != 0 else { return false }
        let targetTs: Int64
        if tb.num == 0 {
            // Defensive: zero numerator is nonsense for a stream
            // time base.  Fall back to AV_TIME_BASE so the seek
            // still produces a meaningful value.
            targetTs = Int64(seconds * Double(AV_TIME_BASE))
        } else {
            targetTs = Int64(seconds * Double(tb.den) / Double(tb.num))
        }
        // AVSEEK_FLAG_BACKWARD asks the demuxer for the keyframe
        // at-or-before the target — avoids "snaps to nearest
        // I-frame a second earlier than you tapped" UX surprise.
        let result = av_seek_frame(
            ctxPtr, videoStreamIndex, targetTs, AVSEEK_FLAG_BACKWARD
        )
        return result >= 0
    }
}
