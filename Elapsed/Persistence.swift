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
#if canImport(UIKit)
import UIKit
#endif

struct VideoStats: Codable, Equatable {
    var boredomDeclared: Bool = false
    var boredomInstance: Int = 0
    var boredomTimeAccumulated: TimeInterval = 0
}

private struct PersistedPayload: Codable {
    var perVideo: [String: VideoStats]
    var totalVideoPlays: Int
    // New in Split 4: total real playback time in seconds (app foreground time)
    var realPlaybackTimeTotal: TimeInterval?
    var boredAcknowledgementTimes: [TimeInterval]?
}

@MainActor
final class StatsStore: ObservableObject {
    // Snapshot used to drive synchronized UI updates for the drawer
    struct SyncedTimes: Equatable {
        var elapsedSeconds: Int
        var realSeconds: Int
    }

    // MARK: - Published state
    @Published var perVideo: [String: VideoStats] = [:]
    @Published var totalVideoPlays: Int = 0
    // Total real playback time (foreground time), persisted
    @Published var realPlaybackTimeTotal: TimeInterval = 0
    @Published var boredAcknowledgementTimes: [TimeInterval] = []

    // Published once per second to render both timers in perfect sync
    @Published var syncedTimes: SyncedTimes = SyncedTimes(elapsedSeconds: 0, realSeconds: 0)

    // Published UI tick so views can update in sync once per second
    @Published var uiSecondTick: Int = 0

    // Timers paused when video is not visible (stats drawer or app inactive)
    @Published private(set) var isTimersPausedForInvisibility: Bool = false

    // Published integers for perfectly synchronized UI updates
    @Published var syncedElapsedSeconds: Int = 0
    @Published var syncedRealSeconds: Int = 0

    // MARK: - Debounce/Save machinery
    private var saveWorkItem: DispatchWorkItem?
    private let saveDebounceInterval: TimeInterval = 1.0 // coalesce frequent ticks

    // MARK: - Real elapsed timer
    private var realElapsedTimer: Timer? = nil

    // MARK: - Lifecycle observers
    private var lifecycleObservers: [Any] = []

    // MARK: - Init/Load
    init() {
        loadFromDisk()
        publishSyncedTimes()

        // Start immediately; lifecycle notifications will adjust as needed
        startRealElapsedTimer()

        #if canImport(UIKit)
        let center = NotificationCenter.default
        // App-level notifications
        let obs1 = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.startRealElapsedTimer()
            }
        }
        let obs2 = center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.startRealElapsedTimer()
            }
        }
        let obs3 = center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.stopRealElapsedTimer()
            }
        }
        // Scene-level notifications (for multi-scene apps)
        let obs4 = center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.startRealElapsedTimer()
            }
        }
        let obs5 = center.addObserver(forName: UIScene.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.startRealElapsedTimer()
            }
        }
        let obs6 = center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.stopRealElapsedTimer()
            }
        }
        lifecycleObservers.append(contentsOf: [obs1, obs2, obs3, obs4, obs5, obs6])
        #endif
    }

    // MARK: - Derived totals (do not persist)
    var totalElapsedTime: TimeInterval { perVideo.values.reduce(0) { $0 + $1.boredomTimeAccumulated } }
    var boredomInstancesTotal: Int { perVideo.values.reduce(0) { $0 + $1.boredomInstance } }

    private func publishSyncedTimes() {
        let elapsed = Int(floor(totalElapsedTime))
        let real = Int(floor(realPlaybackTimeTotal))
        syncedTimes = SyncedTimes(elapsedSeconds: elapsed, realSeconds: real)
        syncedElapsedSeconds = elapsed
        syncedRealSeconds = real
    }

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
        boredAcknowledgementTimes.append(realPlaybackTimeTotal)
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
            self.realPlaybackTimeTotal = decoded.realPlaybackTimeTotal ?? 0
            self.boredAcknowledgementTimes = decoded.boredAcknowledgementTimes ?? []
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
            guard let self else { return }
            Task { @MainActor in
                self.performAtomicWrite()
            }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceInterval, execute: work)
    }

    private func performAtomicWrite() {
        let payload = PersistedPayload(
            perVideo: perVideo,
            totalVideoPlays: totalVideoPlays,
            realPlaybackTimeTotal: realPlaybackTimeTotal,
            boredAcknowledgementTimes: boredAcknowledgementTimes
        )
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

    // MARK: - Real elapsed accumulation API
    func startRealElapsedTimer() {
        // Avoid multiple timers
        if realElapsedTimer != nil { return }
        realElapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.tickRealElapsed()
            }
        }
        if let t = realElapsedTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    func stopRealElapsedTimer() {
        realElapsedTimer?.invalidate()
        realElapsedTimer = nil
    }

    private func tickRealElapsed() {
        realPlaybackTimeTotal += 1
        // Advance a published tick to drive UI updates once per second in sync
        uiSecondTick &+= 1
        publishSyncedTimes()
        // Frequent updates; use debounced save to reduce I/O
        scheduleDebouncedSave()
    }
}
