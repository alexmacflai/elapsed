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
        let total = max(0, Int(seconds.rounded()))

        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600

        if h > 0 {
            return "\(h)h \(m)m \(s)s"
        } else if m > 0 {
            return "\(m)m \(s)s"
        } else {
            return "\(s)s"
        }
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
