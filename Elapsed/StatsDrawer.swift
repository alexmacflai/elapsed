// File: StatsDrawer.swift
// Elapsed
//
// Bottom drawer that shows three small, live-updating stat cards.
// Uses a single detent height and can be dismissed by swipe or tap outside.

import SwiftUI

struct StatsDrawer: View {
    @EnvironmentObject private var stats: StatsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stats")
                .font(.headline)
                .foregroundStyle(.primary)

            StatCard(title: "Elapsed", value: formattedElapsed(stats.totalElapsedTime))
            StatCard(title: "Plays", value: "\(stats.totalVideoPlays)")
            StatCard(title: "Bored acknowledgements", value: "\(stats.boredomInstancesTotal)")
        }
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - Formatting helpers
    private func formattedElapsed(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        let m = s / 60
        let r = s % 60
        if m < 60 { return "\(m)m \(r)s" }
        let h = m / 60
        let rm = m % 60
        return "\(h)h \(rm)m"
    }
}

private struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3).bold()
                    .foregroundStyle(.primary)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}
