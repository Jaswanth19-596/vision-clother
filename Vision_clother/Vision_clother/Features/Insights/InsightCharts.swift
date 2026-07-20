//
//  InsightCharts.swift
//  Vision_clother
//
//  Analytics & Insights, Phase 6 — reusable Swift Charts components shared
//  by Overview and Style, replacing the hand-rolled GeometryReader/Capsule
//  bars from Phases 4/5. Built per the dataviz skill's rules:
//
//  - `RankedBarShareChart` is for a single ranked/magnitude series (one bar
//    per row, e.g. "Top Colors," "Dark/Medium/Light") — one consistent hue,
//    direct percentage labels always visible (small row counts here, so
//    every row can be labeled, not just a selective few), no legend needed
//    since rows are already disambiguated by their axis label, not color.
//  - `PeriodComparisonChart` is for a genuine two-series comparison
//    (current vs. previous period) — the only chart here where color
//    actually carries identity beyond the axis label, so it gets a fixed
//    two-color mapping and a one-line legend rendered once by the card that
//    hosts it (`OverviewView`'s Activity card), not repeated per chart.
//
//  Both add a tap-to-highlight interaction via `chartOverlay` — the
//  native-touch equivalent of the skill's "hover layer" rule (this is a
//  touch UI, not a mouse one).
//

import Charts
import SwiftUI

struct RankedBarShareChart: View {
    struct Row: Identifiable, Equatable {
        let id: String
        let label: String
        let percentage: Double
    }

    let rows: [Row]

    @State private var highlightedID: String?

    var body: some View {
        Chart(rows) { row in
            BarMark(
                x: .value("Share", row.percentage),
                y: .value("Label", row.label)
            )
            .foregroundStyle(VCChartPalette.barFill)
            .opacity(highlightedID == nil || highlightedID == row.id ? 1 : 0.45)
            .cornerRadius(4)
            .annotation(position: .trailing) {
                Text("\(Int((row.percentage * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .chartXScale(domain: 0...max(0.08, (rows.map(\.percentage).max() ?? 0.08) * 1.35))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(preset: .aligned) { _ in
                AxisValueLabel()
                    .font(.subheadline)
            }
        }
        .frame(height: CGFloat(rows.count) * 34 + 8)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let plotFrame = geometry[proxy.plotAreaFrame]
                                let yPosition = value.location.y - plotFrame.origin.y
                                highlightedID = proxy.value(atY: yPosition, as: String.self)
                            }
                            .onEnded { _ in highlightedID = nil }
                    )
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct PeriodComparisonChart: View {
    let currentCount: Int
    let previousCount: Int

    private struct Bar: Identifiable {
        let id: String
        let label: String
        let count: Int
        let isCurrent: Bool
    }

    private var bars: [Bar] {
        [
            Bar(id: "previous", label: "Previous", count: previousCount, isCurrent: false),
            Bar(id: "current", label: "Current", count: currentCount, isCurrent: true),
        ]
    }

    @State private var highlightedID: String?

    var body: some View {
        Chart(bars) { bar in
            BarMark(
                x: .value("Period", bar.label),
                y: .value("Count", bar.count)
            )
            .foregroundStyle(bar.isCurrent ? VCChartPalette.barFill : Color(.systemGray3))
            .opacity(highlightedID == nil || highlightedID == bar.id ? 1 : 0.45)
            .cornerRadius(4)
            .annotation(position: .top) {
                Text("\(bar.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned) { _ in
                AxisValueLabel()
                    .font(.caption)
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 90)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let plotFrame = geometry[proxy.plotAreaFrame]
                                let xPosition = value.location.x - plotFrame.origin.x
                                highlightedID = proxy.value(atX: xPosition, as: String.self)?.lowercased()
                            }
                            .onEnded { _ in highlightedID = nil }
                    )
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Analytics & Insights, Phase 7 — multi-series evolution-over-time chart
/// for the Trends sub-tab (color/category/pattern/style engagement
/// frequency per period). A genuine categorical case: up to 3 fixed-order
/// series plotted together need color to disambiguate them, since they
/// share the same x-axis (bucket) positions rather than being separated by
/// row like `RankedBarShareChart`'s rows are — so this is the one other
/// place (besides `PeriodComparisonChart`) that draws from
/// `VCChartPalette.categorical`, assigned by `chart.seriesLabels`' fixed
/// frequency-rank order, never re-sorted per bucket. Swift Charts renders
/// the legend automatically from `foregroundStyle(by:)`.
struct TrendLineChart: View {
    let chart: TrendsAggregator.TrendChart

    private var colors: [Color] {
        (0..<chart.seriesLabels.count).map { VCChartPalette.categorical[$0 % VCChartPalette.categorical.count] }
    }

    var body: some View {
        Chart(chart.points) { point in
            LineMark(
                x: .value("Period", point.bucketLabel),
                y: .value("Count", point.count)
            )
            .foregroundStyle(by: .value("Series", point.seriesLabel))
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 2))
            .symbol(by: .value("Series", point.seriesLabel))
        }
        .chartForegroundStyleScale(domain: chart.seriesLabels, range: colors)
        .chartXAxis {
            AxisMarks(preset: .aligned) { _ in
                AxisValueLabel()
                    .font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .frame(height: 180)
        .accessibilityElement(children: .contain)
    }
}

/// One-line legend for `PeriodComparisonChart` — rendered once by the
/// hosting card rather than per chart instance, since the current/previous
/// color mapping is fixed and shared across every `PeriodComparisonChart`
/// on screen.
struct PeriodLegend: View {
    var body: some View {
        HStack(spacing: VCSpacing.md) {
            legendDot(color: VCChartPalette.barFill, label: "Current")
            legendDot(color: Color(.systemGray3), label: "Previous")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }
}
