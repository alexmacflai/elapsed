// File: VideoQueue.swift
// Elapsed
//
// Provides a lightweight shuffled queue for local .mp4 files with preloading.
// Update `videoFilenames` below to match the files you add to the project target.
// Missing files are skipped automatically.

import Foundation
import AVFoundation

// 1) Add your 9:16 videos to the Xcode project and ensure they are included in the app target.
// 2) To make this auto-discover ONLY the files inside a bundled subfolder named "Videos":
//    - In Xcode, make `Videos` a *Folder Reference* (blue folder), not just a Group (yellow).
//    - If it's a Group, iOS bundles resources flat and there is no real "Videos" folder to enumerate.
//
// This app will auto-load all bundled .mp4 and .mov video resources.
// Each video ID = filename (lastPathComponent) for persistence.

private enum VideoLibrary {
    /// Returns unique, sorted URLs for all bundled videos (.mp4 + .mov).
    /// Prefers a real bundle subdirectory named "Videos" when present.
    static func bundledVideoURLs() -> [URL] {
        let exts = ["mp4", "mov"]

        // Prefer enumerating within a real bundle subdirectory (works only with Folder Reference).
        var urls: [URL] = []
        for ext in exts {
            urls.append(contentsOf: Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Videos") ?? [])
        }

        // Fallback: enumerate all bundled videos (works for Groups too).
        if urls.isEmpty {
            for ext in exts {
                urls.append(contentsOf: Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [])
            }
        }

        // De-dupe + stable order
        let unique = Array(Set(urls))
        return unique.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Stable IDs used by persistence
    static func bundledVideoIDs() -> [String] {
        bundledVideoURLs().map { $0.lastPathComponent }
    }

    /// Resolve an ID back to a URL.
    static func url(forVideoID id: String) -> URL? {
        // Try a real bundle subdir first
        if let url = Bundle.main.url(forResource: id, withExtension: nil, subdirectory: "Videos") {
            return url
        }
        // Fallback (flat bundle)
        return Bundle.main.url(forResource: id, withExtension: nil)
    }
}

/// Auto-discovered stable video IDs (filenames with extension). Use these for persistence keys.
public let videoFilenames: [String] = VideoLibrary.bundledVideoIDs()

/// A simple queue that shuffles local video filenames and prepares AVPlayers.
struct VideoQueue {
    // Current shuffled order
    private var order: [String] = []

    // Keep track to avoid immediate repeats across reshuffles
    private var lastPlayed: String? = nil

    // Prepared next player cache
    private var preparedNextPlayer: AVPlayer? = nil

    init() {
        resetAndReshuffle()
    }

    /// Rebuilds the shuffled order with a fresh seed and clears caches.
    mutating func resetAndReshuffle() {
        order = shuffledAvoidingImmediateRepeat(last: lastPlayed)
        preparedNextPlayer = nil
        // Do not call prepare recursively; let caller or next call prepare.
        prepareNextIfNeeded()
    }

    /// Returns a prepared AVPlayer for the next item and advances the queue.
    /// If none available, tries to reshuffle and attempt again.
    mutating func dequeuePreparedPlayer() -> AVPlayer? {
        if preparedNextPlayer == nil {
            prepareNextIfNeeded()
        }
        guard let player = preparedNextPlayer else {
            // Attempt a single reshuffle and try again
            order = shuffledAvoidingImmediateRepeat(last: lastPlayed)
            prepareNextIfNeeded()
            let p = preparedNextPlayer
            preparedNextPlayer = nil
            return p
        }
        preparedNextPlayer = nil
        return player
    }

    /// Returns the next prepared player without consuming it.
    mutating func peekPreparedNextPlayer() -> AVPlayer? {
        if preparedNextPlayer == nil {
            prepareNextIfNeeded()
        }
        return preparedNextPlayer
    }

    /// Ensures we have a prepared player ready for the next item.
    mutating func prepareNextIfNeeded() {
        guard preparedNextPlayer == nil else { return }

        // First pass: try current order
        if let player = prepareFromCurrentOrder() {
            preparedNextPlayer = player
            return
        }

        // Second pass: reshuffle once and try again if we have filenames
        guard !videoFilenames.isEmpty else { return }
        order = shuffledAvoidingImmediateRepeat(last: lastPlayed)
        preparedNextPlayer = prepareFromCurrentOrder()
        // If still nil, we stop; caller can decide what to do.
    }

    /// Attempts to pop the next valid filename from `order` and create a prepared AVPlayer.
    private mutating func prepareFromCurrentOrder() -> AVPlayer? {
        while !order.isEmpty {
            let filename = order.removeFirst()

            // Resolve from bundle (prefer Videos/ subdir when present)
            guard let url = VideoLibrary.url(forVideoID: filename) else {
                // Skip missing files
                continue
            }

            // Prepare the player
            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true

            // Kick off loading work so it's ready by the time we switch (async load)
            Task.detached {
                do {
                    let _ = try await asset.load(.isPlayable)
                    // no-op; just ensuring asset begins to load
                } catch {
                    // Ignore; failure to preload shouldn't crash
                }
            }

            lastPlayed = filename
            return player
        }
        return nil
    }

    /// Utility: returns a shuffled array avoiding an immediate repeat of `last` when possible.
    private func shuffledAvoidingImmediateRepeat(last: String?) -> [String] {
        var shuffled = videoFilenames.shuffled()
        if let last, shuffled.first == last, shuffled.count > 1 {
            shuffled.swapAt(0, 1)
        }
        return shuffled
    }
}
