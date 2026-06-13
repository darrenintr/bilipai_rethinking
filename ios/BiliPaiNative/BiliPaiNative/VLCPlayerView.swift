import SwiftUI
import UIKit
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

/// A robust FFmpeg-based player view using MobileVLCKit.
/// This replaces AVPlayer to support Bilibili's DASH streams and custom headers.
struct VLCPlayerView: UIViewRepresentable {
    let url: URL
    let referer: String
    @Binding var isPlaying: Bool
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        
        #if canImport(MobileVLCKit)
        let mediaPlayer = VLCMediaPlayer()
        mediaPlayer.drawable = view
        
        let media = VLCMedia(url: url)
        // Add Bilibili-specific headers to bypass CDN protection
        media.addOptions([
            "http-referrer": referer,
            "http-user-agent": "bili-universal/iphone (iPhone; iOS 18.0; Scale/3.00)"
        ])
        
        mediaPlayer.media = media
        context.coordinator.mediaPlayer = mediaPlayer
        
        if isPlaying {
            mediaPlayer.play()
        }
        #else
        let label = UILabel()
        label.text = "VLCKit not linked. Please add MobileVLCKit via SPM."
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        view.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
        #endif
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        #if canImport(MobileVLCKit)
        guard let mediaPlayer = context.coordinator.mediaPlayer else { return }
        if isPlaying && !mediaPlayer.isPlaying {
            mediaPlayer.play()
        } else if !isPlaying && mediaPlayer.isPlaying {
            mediaPlayer.pause()
        }
        #endif
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject {
        #if canImport(MobileVLCKit)
        var mediaPlayer: VLCMediaPlayer?
        #endif
    }
}
