// File: Persistence.swift
// Elapsed
//
// Robust persistence for Split 2/3/4: per-video stats + global totals.
// - Codable JSON stored in Application Support.
// - Atomic-ish writes via temp file + replace.
// - Debounced saves for time accumulation; immediate saves for structural changes.
// - Safe recovery on load failures.

import Foundation
import Combine

struct VideoStats: Codable, Equatable {
    var boredomDeclared: Bool = false
    var boredomInstance: Int = 0
    var boredomTimeAccumulated: TimeInterval = 0
}

private struct PersistedPayload: Codable {
    var perVideo: [String: VideoStats]
    var totalVideoPlays: Int
    // Versioning/migration hooks can be added here later
}

@MainActor
final class StatsStore: ObservableObject {
    // MARK: - Published state
    @Published var perVideo: [String: VideoStats] = [:]
    @Published var totalVideoPlays: Int = 0

    // Timers paused when video is not visible (stats drawer or app inactive)
    @Published private(set) var isTimersPausedForInvisibility: Bool = false

    // MARK: - Debounce/Save machinery
    private var saveWorkItem: DispatchWorkItem?
    private let saveDebounceInterval: TimeInterval = 1.0 // coalesce frequent ticks

    // MARK: - Init/Load
    init() {
        loadFromDisk()
    }

    // MARK: - Derived totals (do not persist)
    var totalElapsedTime: TimeInterval { perVideo.values.reduce(0) { $0 + $1.boredomTimeAccumulated } }
    var boredomInstancesTotal: Int { perVideo.values.reduce(0) { $0 + $1.boredomInstance } }

    // MARK: - Mutations (Split 2 semantics)
    func incrementPlays() {
        totalVideoPlays += 1
        saveImmediately()
    }

    func setBoredomDeclared(for key: String, _ declared: Bool) {
        var stats = perVideo[key] ?? VideoStats()
        stats.boredomDeclared = declared
        perVideo[key] = stats
        saveImmediately() // structural change
    }

    func addBoredomInstance(for key: String) {
        var stats = perVideo[key] ?? VideoStats()
        stats.boredomInstance += 1
        perVideo[key] = stats
        saveImmediately() // structural change
    }

    func addBoredomTime(for key: String, delta: TimeInterval) {
        guard delta > 0 else { return }
        var stats = perVideo[key] ?? VideoStats()
        stats.boredomTimeAccumulated += delta
        perVideo[key] = stats
        scheduleDebouncedSave() // frequent updates; coalesce
    }

    // MARK: - Visibility pause/resume
    func pauseForInvisibility() {
        isTimersPausedForInvisibility = true
        saveImmediately() // flush when pausing
    }

    func resumeAfterInvisibility() {
        isTimersPausedForInvisibility = false
        // no immediate save needed
    }

    // MARK: - Public save hooks
    func flushNow() { saveImmediately() }

    // MARK: - Persistence paths
    private var directoryURL: URL {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = urls[0].appendingPathComponent("Elapsed", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var fileURL: URL { directoryURL.appendingPathComponent("stats.json") }

    // MARK: - Load/Save
    private func loadFromDisk() {
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(PersistedPayload.self, from: data)
            self.perVideo = decoded.perVideo
            self.totalVideoPlays = decoded.totalVideoPlays
        } catch {
            // Recover to defaults
            self.perVideo = [:]
            self.totalVideoPlays = 0
        }
    }

    private func saveImmediately() {
        saveWorkItem?.cancel()
        performAtomicWrite()
    }

    private func scheduleDebouncedSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.performAtomicWrite()
            }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceInterval, execute: work)
    }

    private func performAtomicWrite() {
        let payload = PersistedPayload(perVideo: perVideo, totalVideoPlays: totalVideoPlays)
        do {
            let data = try JSONEncoder().encode(payload)
            let tmpURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmpURL, options: .atomic)

            // Replace existing file with tmp (best-effort atomic-ish)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: fileURL)
            }
        } catch {
            // Best-effort; ignore errors in Split 4
        }
    }
}
