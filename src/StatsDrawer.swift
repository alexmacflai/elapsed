// File: StatsDrawer.swift
// Elapsed
//
// Bottom drawer that shows three small, live-updating stat cards.
// Uses a single detent height and can be dismissed by swipe or tap outside.

import SwiftUI
import Charts

struct StatsDrawer: View {
    @EnvironmentObject private var stats: StatsStore

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {

                // Access the synchronized snapshot published by StatsStore
                let elapsedSec = TimeInterval(stats.syncedElapsedSeconds)
                let realSec = TimeInterval(stats.syncedRealSeconds)


                HStack(spacing: 8) {
                    StatTile(title: "Elapsed", value: formattedElapsed(realSec))
                    StatTile(title: "Time bored", value: formattedElapsed(elapsedSec))
                    StatTile(title: "Plays", value: formattedPlays(stats.totalVideoPlays))
//                StatTile(title: "Bored acknowledgements", value: "\(stats.boredomInstancesTotal)")
                }

                GraphTile(title: "Dopamine-free time", elapsed: realSec, bored: elapsedSec)
                
                GraphLineTile(title: "Bored cries over time", times: stats.boredAcknowledgementTimes, totalTime: realSec)
            }
        }
        .padding(.top, 0)
        .padding(.horizontal, 16)
        .padding(.bottom, 0)
        
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Formatting helpers
    private func formattedElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))

        let s = total % 60
        let m = (total / 60) % 60
        let hTotal = total / 3600
        let d = hTotal / 24
        let h = hTotal % 24

        if d > 0 {
            return "\(d)d \(h)h"
        } else if hTotal > 0 {
            return "\(hTotal)h \(m)m"
        } else if m > 0 {
            return "\(m)m \(s)s"
        } else {
            return "\(s)s"
        }
    }

    private func formattedPlays(_ plays: Int) -> String {
        let n = max(0, plays)

        // Millions: 1_000_000 or more -> "3M 15K"
        if n >= 1_000_000 {
            let millions = n / 1_000_000
            let thousands = (n % 1_000_000) / 1_000

            if thousands > 0 {
                return "\(millions)M \(thousands)K"
            } else {
                return "\(millions)M"
            }
        }

        // Thousands (and below): group with thin spaces -> "35 020"
        let thinSpace = "\u{2009}"
        let s = String(n)
        var out: [Character] = []
        out.reserveCapacity(s.count + s.count / 3)

        for (idx, ch) in s.reversed().enumerated() {
            if idx > 0 && idx % 3 == 0 {
                out.append(Character(thinSpace))
            }
            out.append(ch)
        }

        return String(out.reversed())
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3).bold()
                .foregroundStyle(.primary)
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
        )
    }
}

private struct GraphTile: View {
    let title: String
    let elapsed: Double
    let bored: Double

    var body: some View {
        let elapsedValue = max(0, elapsed)
        let boredValue = max(0, bored)

        let segments: [(label: String, value: Double)] = [
            ("Elapsed", elapsedValue),
            ("Bored", boredValue)
        ]

        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Chart(segments, id: \.label) { segment in
                SectorMark(
                    angle: .value("Time", segment.value),
                    innerRadius: .ratio(0.6)
                )
                .foregroundStyle(by: .value("Type", segment.label))
            }
            .chartForegroundStyleScale([
                "Elapsed": Color.purple.opacity(0.3),
                "Bored": Color.purple
            ])
            .chartLegend(.visible)
            .frame(height: 180)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
        )
    }
}

private struct GraphLineTile: View {
    let title: String
    let times: [TimeInterval]
    let totalTime: TimeInterval
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if times.isEmpty {
                Text("No data yet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            } else {
                let sorted = times.sorted()
                let points: [(t: Double, c: Int)] = [(0.0, 0)] + sorted.enumerated().map { (idx, t) in (t, idx + 1) }
                let useHours = totalTime >= 3600
                let unit: Double = useHours ? 3600 : 60

                Chart {
                    ForEach(points.indices, id: \.self) { idx in
                        let p = points[idx]
                        AreaMark(
                            x: .value("Time", p.t),
                            y: .value("Count", p.c)
                        )
                        .foregroundStyle(Gradient(colors: [Color.purple.opacity(0.25), Color.purple.opacity(0.05)]))
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Time", p.t),
                            y: .value("Count", p.c)
                        )
                        .foregroundStyle(.purple)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.catmullRom)
                    }
                }
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(position: .bottom, values: .automatic(desiredCount: 6)) { value in
                        AxisGridLine()
                        AxisTick()
                        if let seconds = value.as(Double.self) {
                            let v = seconds / unit
                            let label = useHours
                                ? String(format: v < 10 ? "%.1fh" : "%.0fh", v)
                                : String(format: v < 10 ? "%.1fm" : "%.0fm", v)
                            AxisValueLabel { Text(label) }
                        }
                    }
                }
                .chartXScale(domain: 0...(max(totalTime, times.max() ?? 0)))
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 180)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
        )
    }
}
