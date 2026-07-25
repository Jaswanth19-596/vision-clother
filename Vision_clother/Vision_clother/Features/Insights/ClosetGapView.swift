//
//  ClosetGapView.swift
//  Vision_clother
//
//  Analytics & Insights — Closet Gap Analysis UI Card.
//  Renders wardrobe health score, gap priorities (Critical, Recommended, Optional),
//  and provides direct action links to check potential new items against gaps.
//

import SwiftUI

struct ClosetGapView: View {
    let report: ClosetGapReport

    var body: some View {
        VStack(alignment: .leading, spacing: VCSpacing.md) {
            headerRow

            healthGaugeCard

            if !report.gaps.isEmpty {
                VStack(alignment: .leading, spacing: VCSpacing.sm) {
                    Text("Identified Closet Gaps (\(report.gaps.count))")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)

                    ForEach(report.gaps) { gap in
                        gapCard(gap)
                    }
                }
            } else {
                HStack(spacing: VCSpacing.sm) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Balanced Wardrobe!")
                            .font(.subheadline.bold())
                        Text("No major category or seasonal gaps detected in your closet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(VCSpacing.md)
                .background(.green.opacity(0.08), in: VCRadius.shape(VCRadius.control))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Closet Gap Analysis")
                    .font(.headline)
                Spacer()
                Text("\(report.totalRealItems) Items")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
            }
            InsightSourceCaption(text: "Multi-dimensional analysis of slot coverage, seasonality & formality")
        }
    }

    private var healthGaugeCard: some View {
        HStack(spacing: VCSpacing.lg) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: CGFloat(report.healthScore) / 100.0)
                    .stroke(
                        healthColor(report.healthScore),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 0) {
                    Text("\(report.healthScore)%")
                        .font(.title3.bold())
                    Text("Health")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 76, height: 76)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Seasonal Coverage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(report.seasonalCoveragePercent)%")
                        .font(.caption.bold())
                }
                ProgressView(value: Double(report.seasonalCoveragePercent), total: 100)
                    .tint(healthColor(report.seasonalCoveragePercent))

                HStack {
                    Text("Formality Balance")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(report.formalityBalancePercent)%")
                        .font(.caption.bold())
                }
                ProgressView(value: Double(report.formalityBalancePercent), total: 100)
                    .tint(healthColor(report.formalityBalancePercent))
            }
        }
        .padding(VCSpacing.md)
        .background(.ultraThinMaterial, in: VCRadius.shape(VCRadius.control))
    }

    private func gapCard(_ gap: ClosetGap) -> some View {
        HStack(alignment: .top, spacing: VCSpacing.sm) {
            Image(systemName: iconName(for: gap))
                .font(.headline)
                .foregroundStyle(badgeColor(for: gap.priority))
                .frame(width: 28, height: 28)
                .background(badgeColor(for: gap.priority).opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(gap.title)
                        .font(.subheadline.bold())
                    Spacer()
                    Text(gap.priority.rawValue.capitalized)
                        .font(.caption2.bold())
                        .foregroundStyle(badgeColor(for: gap.priority))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badgeColor(for: gap.priority).opacity(0.15), in: Capsule())
                }

                Text(gap.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(VCSpacing.md)
        .background(Color.primary.opacity(0.03), in: VCRadius.shape(VCRadius.control))
        .overlay(
            VCRadius.shape(VCRadius.control)
                .strokeBorder(badgeColor(for: gap.priority).opacity(0.2), lineWidth: 1)
        )
    }

    private func healthColor(_ score: Int) -> Color {
        switch score {
        case 80...: return .green
        case 50..<80: return .orange
        default: return .red
        }
    }

    private func badgeColor(for priority: GapPriority) -> Color {
        switch priority {
        case .critical: return .red
        case .recommended: return .orange
        case .optional: return .blue
        }
    }

    private func iconName(for gap: ClosetGap) -> String {
        switch gap.category {
        case .bottleneck: return "exclamationmark.triangle.fill"
        case .seasonal: return "cloud.sun.fill"
        case .formality: return "briefcase.fill"
        case .colorPalette: return "paintpalette.fill"
        }
    }
}
