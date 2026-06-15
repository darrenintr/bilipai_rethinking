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
