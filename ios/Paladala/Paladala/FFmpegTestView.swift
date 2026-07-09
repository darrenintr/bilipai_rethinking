//
//  FFmpegTestView.swift
//  Paladala
//
//  Phase 0 MVP test surface.  A SwiftUI sheet that lets you pick a
//  local H.264 / HEVC MP4 file, hands it to FFmpegPlaybackEngine,
//  and renders the decoded frames through an
//  AVSampleBufferDisplayLayer.  This is intentionally separate from
//  the production `VideoPlayer` so we can iterate on the FFmpeg
//  stack without touching the AVPlayer path that the rest of the
//  app depends on.
//
//  When this view is stable we wire it back into PlayerController
//  as an alternate playback path (Phase 3) so iOS 26 Beta users
//  have an escape hatch from the MetalPerformanceShadersGraph
//  trap.  See the project AGENTS.md / docs for the rollout plan.
//

import SwiftUI
import AVFoundation
import CoreMedia
import CoreVideo
import UniformTypeIdentifiers

/// Top-level test view.  Drives the engine + renders the output.
struct FFmpegTestView: View {
    @StateObject private var bridge = FFmpegTestBridge()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                FFmpegVideoSurface(bridge: bridge)
                    .background(Color.black)
                    .aspectRatio(16.0/9.0, contentMode: .fit)
                    .cornerRadius(12)

                stateRow
                transportRow

                if let error = bridge.errorText {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("FFmpeg Test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $bridge.showingFileImporter,
                allowedContentTypes: [
                    UTType.movie,
                    UTType.mpeg4Movie,
                    UTType.quickTimeMovie,
                    UTType.audiovisualContent
                ]
            ) { result in
                bridge.handleFilePick(result)
            }
        }
    }

    private var stateRow: some View {
        HStack {
            Circle()
                .fill(stateColor)
                .frame(width: 10, height: 10)
            Text(bridge.stateLabel)
                .font(.subheadline)
            Spacer()
            if let fileName = bridge.loadedFileName {
                Text(fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var transportRow: some View {
        HStack(spacing: 24) {
            Button {
                bridge.pickFile()
            } label: {
                Label("Open file", systemImage: "folder")
            }
            .buttonStyle(.bordered)

            Button {
                bridge.togglePlay()
            } label: {
                Image(systemName: bridge.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!bridge.canTogglePlay)

            Spacer()
        }
    }

    private var stateColor: Color {
        switch bridge.stateKind {
        case .idle: return .gray
        case .preparing: return .yellow
        case .playing: return .green
        case .paused: return .blue
        case .failed: return .red
        }
    }
}

// MARK: - UIViewRepresentable bridge for AVSampleBufferDisplayLayer

/// Renders the engine's frames into an AVSampleBufferDisplayLayer
/// hosted inside a UIView.  The view swaps its backing layer class
/// to AVSampleBufferDisplayLayer at construction; frames are
/// enqueued by the bridge on the main actor.
private struct FFmpegVideoSurface: UIViewRepresentable {
    @ObservedObject var bridge: FFmpegTestBridge

    func makeUIView(context: Context) -> FFmpegDisplayView {
        let view = FFmpegDisplayView()
        bridge.attachDisplayLayer(view.displayLayer)
        return view
    }

    func updateUIView(_ uiView: FFmpegDisplayView, context: Context) {
        // No view-state to push; the bridge enqueues frames
        // directly to the display layer as they arrive.
    }
}

/// UIView whose backing layer is an AVSampleBufferDisplayLayer.
private final class FFmpegDisplayView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

// MARK: - Bridge (state holder, owns engine + forwards frames)

/// Holds the FFmpegPlaybackEngine, receives decoded frames, and
/// forwards them to the AVSampleBufferDisplayLayer.  SwiftUI views
/// observe its published state via `@StateObject`.
@MainActor
final class FFmpegTestBridge: ObservableObject {
    enum StateKind: Equatable { case idle, preparing, playing, paused, failed }

    @Published private(set) var stateKind: StateKind = .idle
    @Published private(set) var loadedFileName: String?
    @Published private(set) var errorText: String?
    @Published var showingFileImporter = false

    private var engine: FFmpegPlaybackEngine?
    private var displayLayer: AVSampleBufferDisplayLayer?

    var isPlaying: Bool { stateKind == .playing }
    var canTogglePlay: Bool {
        if case .paused = stateKind { return true }
        if case .preparing = stateKind { return true }
        return false
    }

    var stateLabel: String {
        switch stateKind {
        case .idle:      return "No file loaded"
        case .preparing: return "Preparing…"
        case .playing:   return "Playing"
        case .paused:    return "Paused"
        case .failed:    return "Failed"
        }
    }

    func attachDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        self.displayLayer = layer
        // Default to a sane colour space; explicit here so the
        // first decoded frame doesn't pop in with the wrong gamma.
        layer.videoGravity = .resizeAspect
        layer.controlTimebase = nil
    }

    func pickFile() {
        errorText = nil
        showingFileImporter = true
    }

    func handleFilePick(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            errorText = "File pick failed: \(error.localizedDescription)"
        case .success(let url):
            // Security-scoped resource access — required for any
            // URL the fileImporter hands back.  Without this the
            // FFmpeg open fails with EACCES because the URL's
            // backing file is outside our sandbox.
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }

            stateKind = .preparing
            loadedFileName = url.lastPathComponent
            errorText = nil

            Task { @MainActor in
                let engine = FFmpegPlaybackEngine()
                self.engine = engine
                await engine.load(url: url) { [weak self] frame in
                    // The engine's decode trampoline runs on a
                    // background thread; hop to the main actor
                    // before touching `self` (a SwiftUI View, which
                    // is @MainActor-isolated in Swift 6).
                    Task { @MainActor in
                        self?.handleDecodedFrame(frame)
                    }
                }
                if case .failed = await engine.state {
                    stateKind = .failed
                    errorText = describeFailure(await engine.state)
                } else if case .idle = await engine.state {
                    stateKind = .failed
                    errorText = "Engine returned to idle — open failed"
                } else {
                    stateKind = .paused
                    await engine.play()
                    stateKind = .playing
                }
            }
        }
    }

    func togglePlay() {
        guard let engine else { return }
        Task { @MainActor in
            switch await engine.state {
            case .playing:
                await engine.pause()
                stateKind = .paused
            case .paused:
                await engine.play()
                stateKind = .playing
            default:
                break
            }
        }
    }

    private func handleDecodedFrame(_ frame: VideoToolboxDecodedFrame) {
        guard let layer = displayLayer else { return }

        // Wrap the decoded CVPixelBuffer in a CMSampleBuffer that
        // AVSampleBufferDisplayLayer can enqueue.  PTS comes from
        // the decoder so the layer can apply frame-perfect timing
        // on its next flush; for Phase 0 we just rely on the
        // arrival order.
        var sampleBuffer: CMSampleBuffer?
        let pts = CMTimeMakeWithSeconds(
            frame.presentationTimeSeconds, preferredTimescale: 600
        )
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        let formatDescription = CMVideoFormatDescription.create(from: frame.pixelBuffer)
        guard let formatDescription else { return }

        let createStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let buffer = sampleBuffer else { return }

        if frame.isKeyframe {
            // IDR flush — drop any partial frames queued behind
            // the previous keyframe so we don't decode garbage
            // while the layer is re-syncing.
            layer.flush()
        }
        layer.enqueue(buffer)
    }

    private func describeFailure(_ state: FFmpegPlaybackState) -> String {
        switch state {
        case .failed(.demuxer(.openFailed(let code))):
            return "Open failed (FFmpeg error \(code)).  Make sure the file is H.264 or HEVC and isn't DRM-protected."
        case .failed(.demuxer(.noVideoStream)):
            return "No video stream found.  The file's container / codec isn't enabled in scripts/build-ffmpeg.sh."
        case .failed(.demuxer(.parameterSetExtractionFailed)):
            return "Couldn't read SPS/PPS.  The file may be HLS (Phase 1) or corrupted."
        case .failed(.decoder(.unsupportedCodec)):
            return "Codec isn't H.264 or HEVC.  Phase 0 only supports those two."
        case .failed(.decoder(.formatDescriptionCreationFailed(let status))):
            return "VideoToolbox rejected the format description (OSStatus \(status))."
        case .failed(.decoder(.sessionCreationFailed(let status))):
            return "Couldn't create VTDecompressionSession (OSStatus \(status))."
        case .failed(.decoder(.decodeFailed(let status, _))):
            return "Decode failed (OSStatus \(status))."
        default:
            return "Unknown engine failure."
        }
    }
}

// MARK: - CMVideoFormatDescription helper

private extension CMVideoFormatDescription {
    /// Build a CMVideoFormatDescription from a CVPixelBuffer using
    /// its native pixel format + dimensions.  VideoToolbox uses
    /// this internally for output buffers, so it round-trips
    /// cleanly through CMSampleBufferCreateForImageBuffer.
    static func create(from pixelBuffer: CVPixelBuffer) -> CMVideoFormatDescription? {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &description
        )
        guard status == noErr else { return nil }
        return description
    }
}
