import SwiftUI

// MARK: - MusicProgressBar
//
// Moved from MusicHomeView.swift as part of the music section
// reintroduction (Phase 0b — directory regrouping). Behaviour is
// byte-for-byte identical to the original; only the file location
// and the file-level documentation header changed.
//
// Thin scrubber under the play / pause row. Reads
// `currentTime` / `duration` / `isPlaying` straight off the
// `PlayerController` so any other view that drives the player
// (the lock-screen `nowPlaying`, the mini-player) keeps the
// bar in sync.

struct MusicProgressBar: View {
    @ObservedObject var controller: PlayerController

    @State private var dragging: Bool = false
    @State private var dragValue: Double = 0

    var body: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { dragging ? dragValue : controller.currentTime },
                    set: { newValue in
                        if !dragging { return }
                        dragValue = newValue
                    }
                ),
                // `max(0.1, …)` keeps the slider usable while
                // `duration` is still unknown (the very first
                // frame). Showing `0:00 / 0:00` would suggest the
                // track is empty; the placeholder label below
                // makes the loading state explicit.
                in: 0...max(0.1, controller.duration),
                onEditingChanged: { editing in
                    if editing {
                        dragging = true
                        dragValue = controller.currentTime
                    } else {
                        controller.seek(to: dragValue)
                        // Hold the drag value for a tick so the
                        // slider doesn't snap to 0 before the
                        // `currentTime` publisher catches up.
                        // PR-C Task 3: 200 ms hop via structured
                        // sleep. The view is a struct so there is
                        // no `self` to retain; SwiftUI will
                        // discard the @State mutation if the
                        // view is torn down in the meantime.
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            dragging = false
                        }
                    }
                }
            )
            .tint(PaladalaTheme.biliPink)

            HStack {
                Text(formatTime(dragging ? dragValue : controller.currentTime))
                Spacer()
                Text(formatDuration(controller.duration))
            }
            .font(PaladalaTheme.FontRole.labelMono)
            .foregroundStyle(PaladalaTheme.mutedInk)
            .monospacedDigit()
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    /// Mirrors Apple's loading hint for an unknown track length.
    /// The diagnostic logs (Paladala_Diagnostic_*.txt) show the
    /// first frame after the controller init reports
    /// `duration = 0` because the AVPlayer hasn't parsed the
    /// master playlist yet; rendering that as "0:00" implied a
    /// 3-second clip on a 462-second track, which made the
    /// progress bar look broken.
    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—:—" }
        return formatTime(seconds)
    }
}

// MARK: - Liquid-glass nav bar modifier
//
// Moved from MusicHomeView.swift as part of the music section
// reintroduction (Phase 0b — directory regrouping). Behaviour is
// byte-for-byte identical to the original; only the file location
// and the file-level documentation header changed.
//
// Mirrors the modifier LiveRoomsView uses for the same purpose.

struct LiquidGlassNavBarModifier: ViewModifier {
    let materialDesign: MaterialDesign

    func body(content: Content) -> some View {
        if materialDesign == .liquidGlass {
            content.paladalaNavBarGlass(.liquidGlass)
        } else {
            content
        }
    }
}