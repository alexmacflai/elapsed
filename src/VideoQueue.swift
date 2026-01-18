// File: VideoQueue.swift
// Elapsed
//
// Provides a lightweight shuffled queue for local video files with preloading.
// STRICT: Scan ONLY the bundled "Videos" folder (blue folder reference), non-recursively.
// Missing files are skipped automatically.

import Foundation
import AVFoundation

// Allowed video extensions (case-insensitive)
private let allowedVideoExts: Set<String> = ["mp4", "mov", "m4v"]

private enum VideoLibrary {
    // Allowed video extensions (case-insensitive)
    private static let allowedExts: Set<String> = ["mp4", "mov", "m4v"]

    /// Locate the bundled "Videos" folder (blue folder reference). If not at bundle root, search recursively for a directory named "Videos" (case-insensitive).
    private static func videosFolderURL() -> URL? {
        // Try expected root location first
        if let direct = Bundle.main.resourceURL?.appendingPathComponent("Videos", isDirectory: true),
           FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }
        // Fallback: search the bundle recursively for a directory named "Videos"
        if let root = Bundle.main.resourceURL,
           let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in e {
                if url.lastPathComponent.lowercased() == "videos" {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                        return url
                    }
                }
            }
        }
        return nil
    }

    /// Returns URLs for all videos directly inside the bundled "Videos" folder (non-recursive).
    static func videosFolderURLs() -> [URL] {
        guard let folder = videosFolderURL() else {
            #if DEBUG
            print("[VideoQueue] Videos folder not found in bundle")
            #endif
            return []
        }
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            let filtered = contents.filter { allowedExts.contains($0.pathExtension.lowercased()) }
            #if DEBUG
            let names = filtered.map { $0.lastPathComponent }
            print("[VideoQueue] Videos folder at \(folder.path) contains (\(names.count)):", names)
            #endif
            return filtered.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            #if DEBUG
            print("[VideoQueue] ERROR reading Videos folder:", error.localizedDescription)
            #endif
            return []
        }
    }

    /// Stable IDs = filenames (with extension) from the Videos folder
    static func videoIDs() -> [String] {
        videosFolderURLs().map { $0.lastPathComponent }
    }

    /// Resolve an ID back to a URL inside the Videos folder
    static func url(forVideoID id: String) -> URL? {
        guard let folder = videosFolderURL() else { return nil }
        let direct = folder.appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        #if DEBUG
        print("[VideoQueue] Could not resolve video ID in Videos folder:", id)
        #endif
        return nil
    }
}

/// Dynamic discovery of filenames in the Videos folder each time it's called.
public func videoFilenames() -> [String] { VideoLibrary.videoIDs() }

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
        #if DEBUG
        print("[VideoQueue] Initial IDs (\(videoFilenames().count)):", videoFilenames())
        #endif
    }

    /// Rebuilds the shuffled order with a fresh seed and clears caches.
    mutating func resetAndReshuffle() {
        order = shuffledAvoidingImmediateRepeat(last: lastPlayed)
        preparedNextPlayer = nil
        prepareNextIfNeeded()
    }

    /// Returns a prepared AVPlayer for the next item and advances the queue.
    /// If none available, tries to reshuffle and attempt again.
    mutating func dequeuePreparedPlayer() -> AVPlayer? {
        if preparedNextPlayer == nil { prepareNextIfNeeded() }
        guard let player = preparedNextPlayer else {
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
        if preparedNextPlayer == nil { prepareNextIfNeeded() }
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
        guard !videoFilenames().isEmpty else { return }
        order = shuffledAvoidingImmediateRepeat(last: lastPlayed)
        preparedNextPlayer = prepareFromCurrentOrder()
    }

    /// Attempts to pop the next valid filename from `order` and create a prepared AVPlayer.
    private mutating func prepareFromCurrentOrder() -> AVPlayer? {
        while !order.isEmpty {
            let filename = order.removeFirst()

            // Resolve from Videos folder only
            guard let url = VideoLibrary.url(forVideoID: filename) else {
                #if DEBUG
                print("[VideoQueue] Skipping missing file in Videos folder:", filename)
                #endif
                continue
            }

            // Prepare the player
            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true

            // Kick off loading work so it's ready by the time we switch (async load)
            Task.detached {
                _ = try? await asset.load(.isPlayable)
            }

            lastPlayed = filename
            return player
        }
        return nil
    }

    /// Utility: returns a shuffled array avoiding an immediate repeat of `last` when possible.
    private func shuffledAvoidingImmediateRepeat(last: String?) -> [String] {
        var shuffled = videoFilenames().shuffled()
        if let last, shuffled.first == last, shuffled.count > 1 {
            shuffled.swapAt(0, 1)
        }
        return shuffled
    }
}
