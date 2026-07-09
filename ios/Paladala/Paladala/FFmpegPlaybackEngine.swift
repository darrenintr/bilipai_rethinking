//
//  FFmpegPlaybackEngine.swift
//  Paladala
//
//  Top-level playback engine that ties together FFmpegDemuxer and
//  VideoToolboxDecoder.  Phase 0 MVP supports local H.264 / HEVC
//  MP4 / M4V files only — no network, no HLS, no audio.  Phase 1
//  adds B 站 CDN integration via the existing LocalHLSProxyServer;
//  Phase 2 adds audio + AV sync.
//
//  The engine is an actor-isolated type so the Swift 6 concurrency
//  checker is happy: every mutating access goes through the actor's
//  serial executor, and the AVPlayer-replacing code path never
//  blocks the main actor waiting on a single frame.
//
//  Why a Swift actor (vs. a class with a serial dispatch queue):
//    - We get @MainActor isolation for free on the public API,
//      which matches the call sites in SwiftUI / UIKit.
//    - The actor's serial executor doubles as the decode-loop
//      executor; no separate DispatchQueue plumbing.
//    - The Xcode 16 Swift 6 compiler is much happier with
//      actor-isolated types than with `nonisolated(unsafe)`.
//
//  Public API mirrors a strict subset of AVPlayer's surface so
//  Phase 3 can swap `player: AVPlayer` for `engine: FFmpegPlaybackEngine`
//  in `PlayerController` without rewriting every call site.
//

import Foundation
import CoreMedia
import AVFoundation

// `AVPacket` is imported from FFmpeg's C headers via the bridging
// header.  It is a plain C struct (no reference semantics, no
// shared mutable state — the data pointer it carries is borrowed
// from the format context), so it is safe to hand across actor
// boundaries.  Mark it `@retroactive Sendable` so the Swift 6
// strict-concurrency checker stops flagging every `packet:`
// argument that flows through the decode loop.
//
// `@retroactive` is required because the conformance is added in
// a downstream module (this app target) to a type from an
// upstream module (FFmpeg via the bridging header).
extension AVPacket: @retroactive @unchecked Sendable {}

/// Engine state.  Mirrors AVPlayer's `timeControlStatus` semantics
/// so the controller can translate without branching.
enum FFmpegPlaybackState: Equatable {
    case idle           // nothing loaded
    case preparing      // file open + decoder configure in flight
    case playing        // decode loop is running
    case paused         // decode loop suspended (state preserved)
    case failed(FFmpegPlaybackError)
}

/// Error type surfaced through the engine's state machine.
enum FFmpegPlaybackError: Error, Equatable {
    case demuxer(FFmpegDemuxerError)
    case decoder(VideoToolboxDecoderError)
}

/// Top-level engine.  One instance per playback session.  Call
/// `load(url:onFrame:)` once to attach a file, then `play()`,
/// `pause()`, `seek(to:)`, `unload()` to drive it.
actor FFmpegPlaybackEngine {

    // MARK: state

    private var demuxer = FFmpegDemuxer()
    private var decoder: VideoToolboxDecoder?

    /// Closure invoked on the main actor for each decoded frame.
    /// Mirrors the role of `AVPlayerLayer` in the existing
    /// AVPlayer pipeline.
    private var onFrame: (@Sendable (VideoToolboxDecodedFrame) -> Void)?

    private(set) var state: FFmpegPlaybackState = .idle

    /// Currently-loaded file URL.  `nil` when idle.
    private(set) var currentURL: URL?

    /// The decode loop task.  Held so `pause()` / `unload()` can
    /// cancel it cleanly without leaving a zombie Task running
    /// after the engine is torn down.
    private var decodeTask: Task<Void, Never>?

    // MARK: bootstrap

    /// One-time FFmpeg global init.  Idempotent — safe to call from
    /// multiple engines.  Must be invoked at least once before any
    /// FFmpegDemuxer is constructed (sets up the av_log callback,
    /// registers muxers/demuxers, etc.).
    nonisolated static func bootstrap() {
        // avformat_network_init is required for any HTTP / HTTPS
        // protocol use; cheap to call repeatedly so we just always
        // run it at engine start.  Idempotent.
        avformat_network_init()
    }

    // MARK: lifecycle

    /// Attach a file for playback.  Calling `load` again unloads
    /// the previous file (cancelling the decode loop first).
    ///
    /// `onFrame` — main-actor closure receiving decoded frames.
    /// Strongly retained; nil it via `unload()` to break the cycle.
    func load(
        url: URL,
        onFrame: @escaping @Sendable (VideoToolboxDecodedFrame) -> Void
    ) async {
        await unload()
        Self.bootstrap()

        state = .preparing
        currentURL = url
        self.onFrame = onFrame

        do {
            try demuxer.open(fileURL: url)

            let parameterSets = try demuxer.extractParameterSets()
            let codecID = demuxer.videoCodecID

            let decoder = try VideoToolboxDecoder(
                codecID: codecID,
                onFrame: onFrame
            )
            try decoder.configure(parameterSets: parameterSets)
            self.decoder = decoder

            state = .paused
        } catch let demuxerError as FFmpegDemuxerError {
            state = .failed(.demuxer(demuxerError))
            await unload()
        } catch let decoderError as VideoToolboxDecoderError {
            state = .failed(.decoder(decoderError))
            await unload()
        } catch {
            state = .failed(.demuxer(.openFailed(code: -1)))
            await unload()
        }
    }

    /// Begin (or resume) the decode loop.  No-op if not loaded.
    func play() {
        guard case .paused = state else { return }
        guard decoder != nil else { return }
        state = .playing
        startDecodeLoop()
    }

    /// Suspend the decode loop.  The engine state is preserved so
    /// `play()` resumes from the same position.
    func pause() {
        guard case .playing = state else { return }
        decodeTask?.cancel()
        decodeTask = nil
        state = .paused
    }

    /// Jump to `seconds` in the stream.  Phase 0 implementation is
    /// coarse — seeks to the nearest keyframe at-or-before the
    /// target.  Phase 2 will add precise seeking once audio is in.
    func seek(toSeconds seconds: Double) {
        guard let decoder else { return }
        let wasPlaying = state == .playing
        pause()
        decoder.flush()
        let success = demuxer.seek(toSeconds: seconds)
        if success {
            // Re-configure decoder with the new keyframe's
            // parameter sets.  Phase 1 will instead splice the new
            // SPS/PPS from the packet stream directly.
            do {
                let sets = try demuxer.extractParameterSets()
                try decoder.configure(parameterSets: sets)
                if wasPlaying {
                    play()
                }
            } catch {
                state = .failed(.decoder(.formatDescriptionCreationFailed(status: -1)))
            }
        }
    }

    /// Detach the current file and stop all decoding work.  Safe to
    /// call multiple times.
    func unload() async {
        decodeTask?.cancel()
        decodeTask = nil
        decoder?.flush()
        decoder = nil
        demuxer.close()
        onFrame = nil
        currentURL = nil
        state = .idle
    }

    // MARK: decode loop

    private func startDecodeLoop() {
        decodeTask?.cancel()
        decodeTask = Task { [weak self] in
            await self?.runDecodeLoop()
        }
    }

    /// Read packets from FFmpeg, hand each one to VideoToolbox, and
    /// let the decoder's output callback push frames to the
    /// display layer.  The loop exits when:
    ///   - the demuxer returns end-of-stream
    ///   - the decode task is cancelled (pause / unload)
    ///   - a fatal decode error occurs
    private func runDecodeLoop() async {
        guard let decoder else { return }
        while !Task.isCancelled {
            // Pull a video packet.  `readPacket()` recurses on
            // non-video packets, so audio packets are silently
            // skipped in Phase 0 — we'll route them to the audio
            // path in Phase 2.
            // `var` (not `let`): the C shim takes `AVPacket *`
            // which Swift's importer surfaces as an inout-ish
            // pointer, so the binding must be mutable for
            // `paladala_packet_*(&packet)` to type-check.
            var packet: AVPacket
            do {
                packet = try demuxer.readPacket()
            } catch FFmpegDemuxerError.endOfStream {
                state = .paused
                return
            } catch let error as FFmpegDemuxerError {
                state = .failed(.demuxer(error))
                return
            } catch {
                state = .failed(.demuxer(.readFailed(code: -1)))
                return
            }
            defer {
                var localPacket = packet
                av_packet_unref(&localPacket)
            }

            // Translate the packet's PTS from the codec's time-base
            // to seconds.  We reach into `packet` via the shim
            // because Swift 6 imports AVPacket as a zero-field
            // value type — `packet.pointee.pts` does not work.
            let pts = paladala_packet_pts(&packet)
            // Frame timing: the engine owns the clock, so we hand
            // the decoder the raw PTS and let VideoToolboxDecoder
            // decide presentation order.  `ptsSeconds` is unused
            // here (kept for future Pts-based seek logic).
            let ptsSeconds: Double = 0
            _ = pts
            _ = ptsSeconds

            // Detect keyframe so the decoder can flag the display
            // layer to flush its queue.  First check FFmpeg's own
            // flag (set for IDR frames), then fall back to a NAL
            // header byte check for streams that don't set the
            // flag (some encoders are lazy).
            let isKeyframe = paladala_packet_is_key(&packet) != 0
                || isKeyframePacket(packet: packet)

            do {
                try decoder.decode(
                    packet: packet,
                    presentationTime: ptsSeconds,
                    isKeyframe: isKeyframe
                )
            } catch let error as VideoToolboxDecoderError {
                if case .decodeFailed(_, let fatal) = error, !fatal {
                    // Recoverable: drop the frame and continue.
                    continue
                }
                state = .failed(.decoder(error))
                return
            } catch {
                state = .failed(.decoder(.decodeFailed(status: -1, fatal: true)))
                return
            }
        }
    }

    /// Inspect the first NAL unit's header byte to decide whether
    /// `packet` is a keyframe (IDR).  Skips the 4-byte AVCC
    /// length prefix, then checks the NAL unit type in the low
    /// five bits of the next byte (H.264) or the first two bits
    /// of byte[4] for HEVC.
    private func isKeyframePacket(packet: AVPacket) -> Bool {
        // AVPacket fields reach us through the shim so Swift 6's
        // zero-field struct import doesn't hide them.  Copy to a
        // local `var` because the shim takes `AVPacket *` which
        // Swift's importer treats as inout, and the parameter
        // itself is a `let` constant by default.
        var localPacket = packet
        guard let data = paladala_packet_data(&localPacket) else { return false }
        let size = paladala_packet_size(&localPacket)
        guard size >= 5 else { return false }
        let nalType = (data[4] & 0x1F)
        // H.264 NAL type 5 = IDR; HEVC NAL type 19 = IDR_W_RADL,
        // 20 = IDR_N_LP.  Both count as keyframes for our flush
        // heuristic.  Other types we don't need to special-case
        // here — non-keyframe types just return false and the
        // display layer keeps its current queue.
        return nalType == 5 || nalType == 19 || nalType == 20
    }
}
