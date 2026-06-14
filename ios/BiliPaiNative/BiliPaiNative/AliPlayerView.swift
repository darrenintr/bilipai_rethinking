import SwiftUI
import UIKit

// =============================================================================
// VLCPlayerContainerView — no player-specific code, reused verbatim
// =============================================================================

/// A plain UIView that fires `onReadyForDrawable` once it has a window
/// and non-zero bounds. Used by both `VLCPlayerView` representables as
/// the container that hosts the render surface.
final class VLCPlayerContainerView: UIView {
    var onReadyForDrawable: ((VLCPlayerContainerView) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        notifyIfReady()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        notifyIfReady()
    }

    private func notifyIfReady() {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        onReadyForDrawable?(self)
    }
}

// =============================================================================
// VLCPlayerView — AliPlayer-backed UIViewRepresentable
// =============================================================================

/// SwiftUI wrapper around `AliPlayer`'s render surface.
///
/// The `PlayerController` (AliPlayerController) is created and owned by
/// `VideoDetailView` so the same player is shared with the
/// `FullscreenPlayerView`. The user can go inline → fullscreen → inline
/// and the playhead and play/pause state stay continuous across the
/// transition — the same `AliPlayer` keeps playing while only the
/// `playerView` (the visible `UIView`) is swapped.
struct VLCPlayerView: UIViewRepresentable {
    @ObservedObject var controller: PlayerController
    let surface: PlayerDrawableSurface

    init(controller: PlayerController, surface: PlayerDrawableSurface = .standalone) {
        self.controller = controller
        self.surface = surface
    }

    func makeUIView(context: Context) -> UIView {
        let view = VLCPlayerContainerView()
        view.backgroundColor = .black

        let coordinator = context.coordinator
        view.onReadyForDrawable = { [weak coordinator] readyView in
            coordinator?.attachIfReady(controller: controller, view: readyView, surface: surface)
        }
        context.coordinator.attachIfReady(controller: controller, view: view, surface: surface)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let playerView = uiView as? VLCPlayerContainerView else { return }
        let coordinator = context.coordinator
        playerView.onReadyForDrawable = { [weak coordinator] readyView in
            coordinator?.attachIfReady(controller: controller, view: readyView, surface: surface)
        }
        // Re-attach on every re-render. AliPlayer's playerView is a simple
        // property — reassignment is cheap and the renderer rebinds
        // automatically. This is essential for the inline ↔ fullscreen
        // handoff: when the fullscreen is dismissed, the inline view
        // re-renders and needs to re-claim the surface.
        if controller.player.playerView !== playerView {
            context.coordinator.attachIfReady(controller: controller, view: playerView, surface: surface)
        }
    }

    /// SwiftUI calls this when it is recycling the UIViewRepresentable
    /// instance. Do NOT call detach here — the same reasoning as the VLC
    /// version: SwiftUI recycles during the inline ↔ fullscreen
    /// transition, and `updateUIView` re-attaches on the next render.
    /// `tearDown()` (via `VideoDetailView.onDisappear`) handles the
    /// true navigate-away case.
    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        // No-op: AliPlayer handles surface swap via property reassignment.
        // Calling detach() here would race with updateUIView on the new view.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    class Coordinator {
        weak var controller: PlayerController?
        weak var view: VLCPlayerContainerView?
        var surface: PlayerDrawableSurface = .standalone

        func attachIfReady(controller: PlayerController, view: VLCPlayerContainerView, surface: PlayerDrawableSurface) {
            self.controller = controller
            self.view = view
            self.surface = surface
            guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else {
                diagLog(.playback, "AliPlayer drawable attach deferred until layout", details: [
                    "surface": surface.rawValue,
                    "view": String(describing: view)
                ])
                return
            }
            controller.attach(drawable: view, surface: surface)
        }

        func detach() {
            guard let controller = controller, let view = view else { return }
            view.onReadyForDrawable = nil
            controller.detach(currentView: view, surface: surface)
        }
    }
}
