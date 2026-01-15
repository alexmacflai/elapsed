// File: StatsDrawer.swift
// Elapsed
//
// Bottom drawer that shows three small, live-updating stat cards.
// Uses a single detent height and can be dismissed by swipe or tap outside.

import SwiftUI

struct StatsDrawer: View {
    @EnvironmentObject private var stats: StatsStore

    var body: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(Color.white.opacity(0.3))
                .frame(width: 44, height: 5)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 14) {
                Text("Stats")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.bottom, 4)

                // Cards
                StatCard(title: "Elapsed", value: formattedElapsed(stats.totalElapsedTime))
                StatCard(title: "Plays", value: "\(stats.totalVideoPlays)")
                StatCard(title: "Bored acknowledgements", value: "\(stats.boredomInstancesTotal)")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(.black.opacity(0.9))
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
                    .foregroundStyle(.white.opacity(0.7))
                Text(value)
                    .font(.title3).bold()
                    .foregroundStyle(.white)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
