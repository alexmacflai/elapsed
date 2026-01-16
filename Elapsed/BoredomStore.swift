// File: BoredomStore.swift
// Elapsed
//
// Split 2 persistence for per-video boredom state and global totals.
// - Persists per-video boredom flags, instance counts, and accumulated time (by filename)
// - Persists global totalVideoPlays
// - Provides simple APIs for ContentView to mutate and query
// - Uses UserDefaults + Codable; debounced saves for accumulation

import Foundation
import Combine

// MARK: - Per-video record
struct BoredomRecord: Codable, Equatable {
    var boredomDeclared: Bool = false
    var boredomInstance: Int = 0
    var boredomTimeAccumulated: Double = 0 // seconds
}

// MARK: - Store
@MainActor
final class BoredomStore: ObservableObject {
    @Published private(set) var records: [String: BoredomRecord] = [:] // key: filename
    @Published private(set) var totalVideoPlays: Int = 0

    private let recordsKey = "BoredomStore.records"
    private let totalPlaysKey = "BoredomStore.totalPlays"

    private var saveWorkItem: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "BoredomStore.saveQueue")

    init() {
        load()
    }

    // MARK: - Public API
    func record(for filename: String) -> BoredomRecord {
        if let rec = records[filename] { return rec }
        let new = BoredomRecord()
        records[filename] = new
        scheduleSave()
        return new
    }

    func declareBoredomIfNeeded(for filename: String) {
        var rec = record(for: filename)
        if !rec.boredomDeclared {
            rec.boredomDeclared = true
            records[filename] = rec
            scheduleSave()
        }
    }

    func incrementInstance(for filename: String) {
        var rec = record(for: filename)
        rec.boredomInstance += 1
        records[filename] = rec
        scheduleSave()
    }

    func accumulateTime(for filename: String, delta: Double) {
        guard delta > 0 else { return }
        var rec = record(for: filename)
        rec.boredomTimeAccumulated += delta
        records[filename] = rec
        scheduleSaveDebounced()
    }

    func getBoredomTime(for filename: String) -> Double {
        records[filename]?.boredomTimeAccumulated ?? 0
    }

    func isDeclared(for filename: String) -> Bool {
        records[filename]?.boredomDeclared ?? false
    }

    func instanceCount(for filename: String) -> Int {
        records[filename]?.boredomInstance ?? 0
    }

    func incrementTotalVideoPlays() {
        totalVideoPlays += 1
        scheduleSave()
    }

    // MARK: - Persistence
    private func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: recordsKey) {
            do {
                let decoded = try JSONDecoder().decode([String: BoredomRecord].self, from: data)
                self.records = decoded
            } catch {
                self.records = [:]
            }
        }
        self.totalVideoPlays = defaults.integer(forKey: totalPlaysKey)
    }

    private func scheduleSave() {
        let snapshotRecords = records
        let snapshotTotal = totalVideoPlays
        let rKey = recordsKey
        let tKey = totalPlaysKey
        saveQueue.async {
            let defaults = UserDefaults.standard
            do {
                let data = try JSONEncoder().encode(snapshotRecords)
                defaults.set(data, forKey: rKey)
                defaults.set(snapshotTotal, forKey: tKey)
            } catch {
                // ignore errors for this simple store
            }
        }
    }

    private func scheduleSaveDebounced() {
        saveWorkItem?.cancel()
        let snapshotRecords = records
        let snapshotTotal = totalVideoPlays
        let rKey = recordsKey
        let tKey = totalPlaysKey
        let work = DispatchWorkItem {
            let defaults = UserDefaults.standard
            do {
                let data = try JSONEncoder().encode(snapshotRecords)
                defaults.set(data, forKey: rKey)
                defaults.set(snapshotTotal, forKey: tKey)
            } catch {
                // ignore errors for this simple store
            }
        }
        saveWorkItem = work
        saveQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

