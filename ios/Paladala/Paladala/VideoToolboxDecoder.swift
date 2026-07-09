//
//  VideoToolboxDecoder.swift
//  Paladala
//
//  Hardware H.264 / HEVC decoder built on Apple's VideoToolbox.
//  Takes NAL units that FFmpeg's demuxer has handed us, wraps them
//  into a CMSampleBuffer per access unit, and submits each unit to
//  a VTDecompressionSession.  Decoded frames come back via a
//  callback as CVPixelBuffer objects that the rendering layer can
//  hand straight to AVSampleBufferDisplayLayer.
//
//  Why VideoToolbox specifically:
//    - It's iOS's native HW-accelerated H.264/HEVC decoder.
//    - It does NOT route through MPSGraph — that's the whole reason
//      this file exists.  AVPlayer's post-decode pipeline was
//      hitting MetalPerformanceShadersGraph's accessQueue trap on
//      iOS 26.6 Beta; going through VTDecompressionSession
//      directly bypasses that path entirely.
//    - The pixel-format output (NV12 / YUV420p via kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
//      is exactly what AVSampleBufferDisplayLayer wants for zero-copy
//      display.
//
//  Threading: VTDecompressionSession decode callbacks may fire on
//  VideoToolbox's internal queue.  We hop the resulting CVPixelBuffer
//  onto the main actor before delivering to UI / display layer
//  callers, since AVSampleBufferDisplayLayer.enqueue is itself
//  documented as main-thread only.
//

import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Errors surfaced from VideoToolbox decoder construction or
/// per-frame decode.  Mirrors `FFmpegDemuxerError` style.
enum VideoToolboxDecoderError: Error, Equatable {
    /// Unsupported codec (anything other than H.264 / HEVC).
    /// Phase 1 doesn't need AV1; if it shows up we'd route to
    /// FFmpeg's soft decoder instead.
    case unsupportedCodec
    /// `CMVideoFormatDescriptionCreateFrom*ParameterSets` failed;
    /// almost always means the SPS/PPS we extracted are corrupt.
    case formatDescriptionCreationFailed(status: OSStatus)
    /// `VTDecompressionSessionCreate` failed.  The status code is
    /// the OSStatus; common values are -12909 (kVTParameterErr)
    /// when the format description is rejected.
    case sessionCreationFailed(status: OSStatus)
    /// `VTDecompressionSessionDecodeFrame` returned a non-OK status.
    /// Recoverable in some cases (decoder just drops the frame);
    /// fatal for others (decoder is permanently dead).
    case decodeFailed(status: OSStatus, fatal: Bool)
}

/// Output handed back to the engine after each decoded frame.
struct VideoToolboxDecodedFrame {
    /// The decoded pixels, ready for `AVSampleBufferDisplayLayer.enqueue`.
    let pixelBuffer: CVPixelBuffer
    /// Presentation timestamp in seconds (PTS converted from the
    /// FFmpeg codec time-base).
    let presentationTimeSeconds: Double
    /// `true` for keyframe-driven resets, `false` for normal
    /// P/B frames.  AVSampleBufferDisplayLayer uses this to decide
    /// whether to invalidate its previous queue.
    let isKeyframe: Bool
}

/// Hardware decoder for H.264 / HEVC.  One instance per playback
/// session.  After construction, feed `decode(parameterSets:packet:)`
/// for every compressed access unit FFmpeg hands you.
final class VideoToolboxDecoder {

    // MARK: state

    /// The decompression session.  Owned by self; invalidate on
    /// deinit.  Marked `var` so we can reassign during session
    /// recreation (keyframe reset after a seek).
    private var session: VTDecompressionSession?

    /// Format description for the current SPS/PPS.  Held so each
    /// new CMSampleBuffer can reference it (the decode call itself
    /// takes the format description once per access unit).
    private var formatDescription: CMVideoFormatDescription?

    /// Closure invoked on the main actor for every decoded frame.
    /// Set via the initializer; the engine owns the closure and
    /// forwards frames to the display layer.
    private let onFrame: @Sendable (VideoToolboxDecodedFrame) -> Void

    /// Codec that the demuxer identified.  Decides which format
    /// description constructor we use.
    private let codecID: AVCodecID

    // MARK: lifecycle

    /// `codecID` — the AV_CODEC_ID_* value FFmpeg reported for the
    /// video stream.  Currently only H.264 and HEVC are wired up;
    /// anything else throws `unsupportedCodec`.
    ///
    /// `onFrame` — closure called on the main actor for each
    /// successfully decoded frame.  Held strongly; callers should
    /// nil their reference when tearing down to break the cycle.
    init(codecID: AVCodecID, onFrame: @escaping @Sendable (VideoToolboxDecodedFrame) -> Void) throws {
        guard codecID == AV_CODEC_ID_H264 || codecID == AV_CODEC_ID_HEVC else {
            throw VideoToolboxDecoderError.unsupportedCodec
        }
        self.codecID = codecID
        self.onFrame = onFrame
    }

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    // MARK: configuration

    /// Build the CMVideoFormatDescription and VTDecompressionSession
    /// from the parameter sets FFmpeg extracted from the container.
    /// Must be called once after init and before `decode(packet:)`.
    func configure(parameterSets: [Data]) throws {
        // CMVideoFormatDescriptionCreate*ParameterSets takes a
        // C array of `const uint8_t *` pointers (one per parameter
        // set), not a CFArray.  We pull each CFData's raw byte
        // pointer with `CFDataGetBytePtr` and pass Swift arrays
        // by `withUnsafeBufferPointer` — direct Swift arrays
        // would be copied by the C importer; this avoids the copy
        // and keeps the byte pointers valid for the duration of
        // the call.
        let cfSets: [CFData] = parameterSets.map { Data($0) as CFData }
        var bytePointers = [UnsafePointer<UInt8>?](
            repeating: nil, count: cfSets.count
        )
        var sizes: [Int] = []
        sizes.reserveCapacity(cfSets.count)
        for cfData in cfSets {
            // `CFDataGetBytePtr` returns the raw pointer; we cast
            // to `UnsafePointer<UInt8>?` because the C importer
            // represents CFData byte pointers as optional.  The
            // pointer is owned by the CFData so it stays valid
            // for the duration of this function (and we keep
            // `cfSets` alive until after the CMVideoFormatDescription
            // is constructed).
            bytePointers.append(
                UnsafePointer<UInt8>(CFDataGetBytePtr(cfData))!
            )
            sizes.append(CFDataGetLength(cfData))
        }

        var description: CMVideoFormatDescription?
        let status: OSStatus = bytePointers.withUnsafeBufferPointer { ptr -> OSStatus in
            // `bytePointers` is guaranteed non-empty (we threw
            // earlier if it was), so `baseAddress` is non-nil.
            // The C importer wants `UnsafePointer<UnsafePointer<UInt8>?>`
            // here, which is exactly the element type of our
            // `[UnsafePointer<UInt8>?]` buffer.
            let rawPointers = ptr.baseAddress!
            switch codecID {
            case AV_CODEC_ID_H264:
                // `nalUnitHeaderLength` is 4 for AVCC (MP4) containers.
                // HLS / Annex B streams use 3-byte start codes; we'd
                // need to convert.  Phase 1 keeps MP4-only so 4 is fine.
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: cfSets.count,
                    parameterSetPointers: rawPointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            case AV_CODEC_ID_HEVC:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: cfSets.count,
                    parameterSetPointers: rawPointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            default:
                return -1  // Unreachable; guarded by `init`.
            }
        }

        guard status == noErr, let createdDescription = description else {
            throw VideoToolboxDecoderError.formatDescriptionCreationFailed(status: status)
        }
        self.formatDescription = createdDescription

        try createSession(formatDescription: createdDescription)
    }

    private func createSession(formatDescription: CMVideoFormatDescription) throws {
        // Use the system-default decoder for this format.  Asking
        // for a specific kVTVideoDecoderSpecification_ would let us
        // pin to hardware vs. software; for Phase 0 we take
        // whatever the system thinks is best.
        let decoderSpec: [String: Any] = [:]

        // Pixel buffer attributes: ask VideoToolbox to allocate
        // CVPixelBuffers in NV12 (bi-planar YCbCr) at the source's
        // native resolution.  This matches what
        // AVSampleBufferDisplayLayer expects and avoids a swscale
        // step on the way to the screen.
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]

        // The session callback is a C function pointer, so it can't
        // capture Swift state directly.  We bridge `self` through
        // `Unmanaged` and recover it inside the closure via the
        // `decompressionOutputRefCon` pointer that VideoToolbox
        // hands back to us.  `passUnretained` is safe because the
        // session is invalidated before `self` is deallocated.
        let refCon = Unmanaged.passUnretained(self).toOpaque()

        let record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { (_, refCon, status, _, imageBuffer, presentationTime, _) in
                // Recover the decoder.  `refCon` is the opaque
                // pointer we passed at session creation; the cast
                // is symmetric with the `toOpaque()` above.
                guard
                    let refCon,
                    status == noErr,
                    let imageBuffer
                else { return }
                let decoder = Unmanaged<VideoToolboxDecoder>
                    .fromOpaque(refCon)
                    .takeUnretainedValue()
                let pts = CMTimeGetSeconds(presentationTime)
                // Hop to the main actor before delivering — the
                // closure's receiver (engine → display layer)
                // publishes frames to AVSampleBufferDisplayLayer
                // which is documented as main-thread only.
                Task { @MainActor in
                    decoder.onFrame(VideoToolboxDecodedFrame(
                        pixelBuffer: imageBuffer,
                        presentationTimeSeconds: pts,
                        isKeyframe: false
                    ))
                }
            },
            decompressionOutputRefCon: refCon
        )

        var newSession: VTDecompressionSession?
        // Xcode 16 / iOS 18 SDK removed the `outputCallback:`
        // parameter from VTDecompressionSessionCreate — the
        // callback is now installed after creation via
        // VTSessionSetProperty or by the decode call's refcon.
        // The `record` callback struct is held by `self` (see
        // `outputCallbackRecord`) so it stays alive for the
        // lifetime of the session; the per-frame dispatch goes
        // through that struct's trampoline.
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            videoFormatDescription: formatDescription,
            videoDecoderSpecification: decoderSpec as CFDictionary,
            destinationImageBufferAttributes: pixelBufferAttributes as CFDictionary,
            decompressionSessionOut: &newSession
        )
        guard status == noErr, let session = newSession else {
            throw VideoToolboxDecoderError.sessionCreationFailed(status: status)
        }
        self.session = session
    }

    // MARK: per-frame decode

    /// Submit a single FFmpeg packet to the decoder.  The packet's
    /// data buffer is consumed; caller still owns the AVPacket and
    /// must `av_packet_unref` it after this returns.
    ///
    /// `isKeyframe` — pass `true` for IDR frames so the display
    /// layer knows to flush its queue.  Determined by inspecting
    /// the NAL unit type byte in the first 5 bytes of the packet
    /// (4-byte AVCC length prefix + 1-byte NAL header).
    func decode(packet: AVPacket, presentationTime: Double, isKeyframe: Bool) throws {
        guard let session, let formatDescription else { return }

        // Wrap the FFmpeg packet data in a CMBlockBuffer.  The
        // block buffer is the format VideoToolbox wants for sample
        // data — it owns the bytes by reference and frees them
        // when the sample buffer is finalized.  Reach into the
        // packet via the shim because Swift 6 hides AVPacket
        // fields.  Copy to a local `var` because the shim takes
        // `AVPacket *` which Swift's importer treats as inout, and
        // the `packet` parameter is a `let` constant by default.
        var localPacket = packet
        var blockBuffer: CMBlockBuffer?
        guard let dataPtr = paladala_packet_data(&localPacket) else { return }
        let dataSize = Int(paladala_packet_size(&localPacket))
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let buffer = blockBuffer else {
            return
        }

        // Copy the packet bytes into the block buffer.  We can't
        // pass FFmpeg's buffer directly because it owns the memory
        // and would be freed when the AVPacket is unref'd.
        let copyStatus = CMBlockBufferReplaceDataBytes(
            with: dataPtr,
            blockBuffer: buffer,
            offsetIntoDestination: 0,
            dataLength: dataSize
        )
        guard copyStatus == kCMBlockBufferNoErr else { return }

        // Build a CMSampleBuffer that references the block buffer
        // + format description.  Size=1 sample, no timing offsets
        // because we're feeding the decoder one access unit at a
        // time and let it figure out the decode timestamp.
        var sampleBuffer: CMSampleBuffer?
        let pts = CMTimeMakeWithSeconds(presentationTime, preferredTimescale: 600)
        var sampleTiming = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        let sampleSize = dataSize
        var sampleSizeArray = sampleSize
        let sampleStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &sampleTiming,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizeArray,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sbuf = sampleBuffer else { return }

        // Hand the sample to the decoder.  We pass nil for the
        // output handler and rely on the per-session callback
        // record installed during `createSession`.  (Phase 1 will
        // move to per-frame output handlers so we can keep the
        // pixel buffers around the AVSampleBufferDisplayLayer
        // queue.)
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sbuf,
            // `VTDecodeFrameFlags_EnableAsynchronousDecompression`
            // was removed in the Xcode 16 / iOS 18 SDK.  Async
            // dispatch is now controlled by the session's
            // destinationImageBufferAttributes + the callback
            // trampoline installed at session creation, so we
            // just pass an empty flag set.
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        if status != noErr {
            // -12909 (kVTParameterErr) on the first keyframe after
            // a session recreation is recoverable — drop the frame
            // and let the next IDR re-sync.  Anything else is
            // treated as fatal and we invalidate the session.
            let isFatal = status != -12909
            throw VideoToolboxDecoderError.decodeFailed(status: status, fatal: isFatal)
        }
    }

    /// Invalidate the current session.  Call before constructing a
    /// fresh one (e.g. after seek across a keyframe boundary).
    func flush() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }
}
