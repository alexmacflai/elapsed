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
        record(for: filename).boredomTimeAccumulated
    }

    func isDeclared(for filename: String) -> Bool {
        record(for: filename).boredomDeclared
    }

    func instanceCount(for filename: String) -> Int {
        record(for: filename).boredomInstance
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

    private func save() {
        let defaults = UserDefaults.standard
        do {
            let data = try JSONEncoder().encode(records)
            defaults.set(data, forKey: recordsKey)
            defaults.set(totalVideoPlays, forKey: totalPlaysKey)
        } catch {
            // ignore errors for this simple store
        }
    }

    private func scheduleSave() {
        saveQueue.async { [weak self] in
            self?.save()
        }
    }

    private func scheduleSaveDebounced() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.save()
        }
        saveWorkItem = work
        saveQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
