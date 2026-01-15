// File: ElapsedApp.swift
// Elapsed
//
// How to add videos:
// 1) Drag your 9:16 .mp4 files into the Xcode project (ensure they are added to the app target).
// 2) Open VideoQueue.swift and update the `videoFilenames` array with your actual filenames.
//    Example: let videoFilenames = ["myClip1.mp4", "intro.mp4", "city_night.mp4"]
//
// Split 1 delivers: playback + shuffle + preload + swipe-up transition.
// Split 3 adds: stats drawer + interaction lock + visibility pause + live stats.
//
// Created by Alex Cruz on 15/01/2026.

import SwiftUI

@main
struct ElapsedApp: App {
    @StateObject private var stats = StatsStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(stats)
        }
    }
}
