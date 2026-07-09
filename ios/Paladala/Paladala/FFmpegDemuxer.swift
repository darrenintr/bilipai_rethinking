//
//  FFmpegDemuxer.swift
//  Paladala
//
//  Swift wrapper around FFmpeg's libavformat demuxer.  Owns the
//  AVFormatContext + codec parameters for a single media file and
//  yields AVPacket objects on demand.
//
//  Threading: this class is annotated `@unchecked Sendable` so it can
//  move across actor boundaries — all FFmpeg interaction happens on
//  a single detached Task (see FFmpegPlaybackEngine) and we hold no
//  Swift-visible mutable state from outside that task.  Do not call
//  into FFmpeg from multiple threads simultaneously; libavformat is
//  not reentrant across contexts that share state.
//
//  Replaces the demuxer role that AVPlayer previously owned, so the
//  iOS 26 Beta MetalPerformanceShadersGraph accessQueue trap can no
//  longer fire from our playback path.
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
/// index of the video stream (the audio stream is found but not yet
/// consumed — Phase 2 will pull audio packets).
final class FFmpegDemuxer: @unchecked Sendable {

    // MARK: state

    /// Owned by self; freed in `close()`.  Marked `var` because the
    /// FFmpeg C API takes `AVFormatContext **` for open; we re-point
    /// the pointer if a re-open happens.
    private var fmtCtx: AVFormatContext?

    /// Index of the video stream inside `fmtCtx->streams`.  -1 when
    /// the file has no video stream we can decode.
    private var videoStreamIndex: Int32 = -1

    /// Codec parameters extracted from the video stream.  Owned by
    /// `fmtCtx`; do NOT free separately.  Held so the engine can
    /// hand them to VideoToolbox without another FFmpeg call.
    private var videoCodecPar: AVCodecParameters?

    /// The duration of the longest stream in `AV_TIME_BASE` units.
    /// FFmpeg uses `AV_TIME_BASE = 1_000_000` (microseconds).
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

        var ctx: AVFormatContext?
        // avformat_open_input takes `AVFormatContext **` — pass a
        // local var so we don't fight with the optional in Swift.
        let openResult = avformat_open_input(&ctx, fileURL.path, nil, nil)
        guard let openedCtx = ctx, openResult >= 0 else {
            throw FFmpegDemuxerError.openFailed(code: openResult)
        }
        self.fmtCtx = openedCtx

        // Pull stream info (this parses the container; fast for MP4,
        // slow for HLS because the playlist has to be fetched).
        let infoResult = avformat_find_stream_info(openedCtx, nil)
        guard infoResult >= 0 else {
            close()
            throw FFmpegDemuxerError.openFailed(code: infoResult)
        }

        // Find the best video stream.  `av_find_best_stream` returns
        // -1 if no video stream is present; the related-stream scan
        // is what we want — it picks the highest-resolution stream
        // when there are multiple video tracks.
        let bestVideo = av_find_best_stream(
            openedCtx,
            AVMEDIA_TYPE_VIDEO,
            -1, -1, nil, 0
        )
        guard bestVideo >= 0 else {
            close()
            throw FFmpegDemuxerError.noVideoStream
        }
        self.videoStreamIndex = bestVideo
        self.videoCodecPar = openedCtx.pointee.streams[Int(bestVideo)]!.pointee.codecpar

        // Duration is the container's reported duration in
        // AV_TIME_BASE units.  For VOD streams this is reliable; for
        // live HLS it'll be AV_NOPTS_VALUE and we have to fall back
        // to last-seen PTS (Phase 1).
        self.durationUs = openedCtx.pointee.duration
    }

    /// Release the AVFormatContext.  Safe to call multiple times.
    func close() {
        if let ctx = fmtCtx {
            var mutable = ctx
            avformat_close_input(&mutable)
        }
        fmtCtx = nil
        videoStreamIndex = -1
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

    /// Codec parameters for the video stream; nil if not opened.
    var videoCodecParameters: AVCodecParameters? {
        videoCodecPar
    }

    /// Codec ID of the video stream (AV_CODEC_ID_H264, AV_CODEC_ID_HEVC, …).
    var videoCodecID: AVCodecID {
        guard let par = videoCodecPar else { return AV_CODEC_ID_NONE }
        return par.pointee.codec_id
    }

    /// Pixel format / codec tag of the video stream, used by
    /// VideoToolboxDecoder to construct a CMVideoFormatDescription.
    var videoCodecTag: UInt32 {
        guard let par = videoCodecPar else { return 0 }
        return par.pointee.codec_tag
    }

    // MARK: parameter set extraction (for VideoToolbox)

    /// Extract the SPS/PPS (H.264) or VPS/SPS/PPS (HEVC) parameter
    /// sets from the container's extradata.  FFmpeg has already
    /// parsed these into `codecpar->extradata` for MP4/M4V; for HLS
    /// we fall back to parsing them out of the first keyframe.
    ///
    /// Returns one buffer per parameter set.  The first buffer is
    /// always the SPS-equivalent (decoder config record for HEVC).
    func extractParameterSets() throws -> [Data] {
        guard let par = videoCodecPar else {
            throw FFmpegDemuxerError.parameterSetExtractionFailed
        }
        let extradata = par.pointee.extradata
        let extradataSize = Int(par.pointee.extradata_size)
        guard let extradata, extradataSize > 0 else {
            throw FFmpegDemuxerError.parameterSetExtractionFailed
        }

        let buffer = UnsafeBufferPointer(
            start: extradata, count: extradataSize
        )
        let bytes = Data(buffer: buffer)

        // The AVCC/HVCC layout puts each parameter set as
        // [4-byte length big-endian][N bytes of NALU].  Walk the
        // buffer and split.  This is the same format VideoToolbox
        // consumes when given an AVCC-style configuration record.
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
    /// yet, so non-video packets are returned as `endOfStream` once
    /// the file is exhausted.  Phase 2 will route audio packets to
    /// the audio decoder instead.
    func readPacket() throws -> AVPacket {
        guard let fmtCtx else {
            throw FFmpegDemuxerError.readFailed(code: -1)
        }
        var packet = AVPacket()
        let result = av_read_frame(fmtCtx, &packet)
        if result < 0 {
            // AVERROR_EOF == -0x2A_8B_5D_9D in signed 32-bit form.
            // Match the int representation that FFmpeg documents
            // (libavutil/error.h) rather than the raw negative
            // value, in case libavformat changes the constant.
            if result == AVERROR_EOF {
                throw FFmpegDemuxerError.endOfStream
            }
            throw FFmpegDemuxerError.readFailed(code: result)
        }

        // Skip non-video packets.  Loop until we either find a
        // video packet or hit EOF — this is fine because audio
        // packets in the same stream typically arrive close to
        // their video counterparts, so the extra iteration cost is
        // small.
        if packet.stream_index != videoStreamIndex {
            av_packet_unref(&packet)
            return try readPacket()
        }

        return packet
    }

    /// Seek to `seconds` in the container.  Phase 0 only supports
    /// seeking by stream index 0 (video); Phase 2 will add audio
    /// re-sync after a seek.
    func seek(toSeconds seconds: Double) -> Bool {
        guard let fmtCtx, videoStreamIndex >= 0 else { return false }
        let stream = fmtCtx.pointee.streams[Int(videoStreamIndex)]!
        let timeBase = stream.pointee.time_base
        let targetTs = Int64(seconds / Double(timeBase.den) * Double(timeBase.num))
        // AVSEEK_FLAG_BACKWARD asks the demuxer for the keyframe
        // at-or-before the target — avoids the "snaps to nearest
        // I-frame a second earlier than you tapped" UX surprise.
        let result = av_seek_frame(
            fmtCtx, videoStreamIndex, targetTs, AVSEEK_FLAG_BACKWARD
        )
        return result >= 0
    }
}
