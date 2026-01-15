// File: PlayerView.swift
// Elapsed
//
// A lightweight UIKit-backed view that hosts an AVPlayer via AVPlayerLayer.
// Ensures reliable fullscreen rendering with aspectFill and no controls.

import SwiftUI
import AVFoundation
import UIKit

struct PlayerView: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.player = player
    }
}

final class PlayerContainerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            playerLayer.player = newValue
            playerLayer.videoGravity = .resizeAspectFill // crop to fill screen
            // Prevents unintended controls; this is a plain layer-backed view.
        }
    }
}
