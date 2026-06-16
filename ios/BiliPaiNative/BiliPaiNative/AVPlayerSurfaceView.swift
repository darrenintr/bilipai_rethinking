//
//  AVPlayerSurfaceView.swift
//  BiliPaiNative
//
//  SwiftUI wrapper around a `UIView` whose backing layer is an
//  `AVPlayerLayer` managed by the shared `PlayerController`.
//
//  Why this exists
//  ---------------
//  The pre-AVPlayer code path used `VLCPlayerView` (a UIKit
//  wrapper around `VLCMediaPlayer`'s drawable). With the move to
//  `AVPlayer`, the drawable needs to be an `AVPlayerLayer`. We
//  keep the surface API of the controller (`attach` / `detach`)
//  unchanged so the views that consume the controller do not
//  need to know whether the underlying engine is VLC, Aliyun,
//  or `AVPlayer` — they just hand in a `UIView` and the
//  controller mounts its drawable on it.
//

import AVFoundation
import SwiftUI
import UIKit

/// A `UIView` that the `PlayerController` will mount an
/// `AVPlayerLayer` onto.  The view is otherwise empty — its
/// `CALayer` is the default `CALayer`, not an
/// `AVPlayerLayer`; the controller adds the player layer as a
/// sublayer in `attach(drawable:surface:)`.
///
/// `layoutSubviews` keeps the player layer's frame in sync
/// with the view's bounds.  This is necessary because
/// `AVPlayerSurfaceView.makeUIView` constructs the view with
/// zero bounds and calls `attach` immediately, so the player
/// layer is first added at `(0, 0, 0, 0)`.  SwiftUI then runs
/// Auto Layout, but the second `attach` in `updateUIView`
/// short-circuits via the "same target" guard and never
/// refreshes the layer frame.  Without this override the
/// layer would stay at zero size and the user would see a
/// black frame with audio playing.
final class PlayerDrawableView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        // AVPlayer is layer-based; the layer host is opaque so
        // we do not get a flash of the SwiftUI surface behind
        // the player while the first frame is decoded.
        isOpaque = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Resize every sublayer to match the new bounds.
        // The controller adds at most one `AVPlayerLayer`
        // but we walk the sublayer list so any future
        // overlay (e.g. a loading spinner layer) tracks
        // the view too.
        for sub in layer.sublayers ?? [] {
            sub.frame = bounds
        }
    }
}

/// SwiftUI host for `PlayerDrawableView`.  One instance per
/// surface (inline / fullscreen).  The controller's `attach`
/// API swaps the player layer between surfaces as the user
/// enters or leaves fullscreen, so the actual `AVPlayer`
/// instance stays alive and the playhead does not jump.
struct AVPlayerSurfaceView: UIViewRepresentable {
    let controller: PlayerController
    let surface: PlayerDrawableSurface

    func makeUIView(context: Context) -> PlayerDrawableView {
        let view = PlayerDrawableView()
        controller.attach(drawable: view, surface: surface)
        return view
    }

    func updateUIView(_ uiView: PlayerDrawableView, context: Context) {
        // The controller only re-mounts the layer if the
        // surface or the target view actually changes; see
        // `PlayerController.attach(drawable:surface:)`.  A
        // no-op update is cheap.
        controller.attach(drawable: uiView, surface: surface)
    }

    static func dismantleUIView(_ uiView: PlayerDrawableView, coordinator: ()) {
        // The controller's `tearDown` is the only place that
        // actually releases the player layer.  Dismantling
        // the SwiftUI wrapper just means the UIView leaves
        // the view tree; the layer is still attached until
        // `tearDown` removes it.
    }
}
