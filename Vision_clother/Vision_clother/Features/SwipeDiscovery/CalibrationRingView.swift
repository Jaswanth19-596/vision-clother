//
//  CalibrationRingView.swift
//  Vision_clother
//
//  Swipe-to-Learn Visual Taste: a minimalist Activity-ring-style meter for
//  `VisualPreferenceState.calibrationProgress` — deliberately not a raw
//  percentage/drift readout (that's `[AI-Stylist-ML]`'s console log, see
//  Data/WardrobeRepository.swift), but a gamified "you're getting closer"
//  signal on the swipe-deck screen itself.
//

import SwiftUI

struct CalibrationRingView: View {
    var progress: Double
    var isTrained: Bool

    private let diameter: CGFloat = 44
    private let lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.15), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    isTrained ? AnyShapeStyle(.green) : AnyShapeStyle(VCAccentColor.brand),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: progress)

            if isTrained {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: isTrained)
    }
}

/// Ring + label, the unit `SwipeDiscoveryView` actually mounts.
struct CalibrationProgressBadge: View {
    var progress: Double
    var isTrained: Bool

    var body: some View {
        HStack(spacing: VCSpacing.sm) {
            CalibrationRingView(progress: progress, isTrained: isTrained)

            VStack(alignment: .leading, spacing: 2) {
                Text("Stylist Calibration")
                    .font(.caption.weight(.semibold))
                Text(isTrained ? "Warmed up — recommendations now use your taste" : "Keep swiping to fine-tune your recommendations")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .premiumCard()
    }
}

/// Transient "the model just moved" toast — shows the actual centroid drift
/// (`SwipeDiscoveryViewModel.lastDriftAmount`, a fraction from
/// `VisualClusterUpdater.update`'s return value) after a swipe, so the
/// feedback is honest, per-swipe evidence that learning happened rather than
/// an inferred milestone. Mounted as an overlay by `SwipeDiscoveryView`,
/// distinct from `CalibrationProgressBadge`'s longer-lived progress meter.
struct DriftFeedbackPill: View {
    var amount: Double
    var isVisible: Bool

    var body: some View {
        Group {
            if isVisible {
                Text("Taste shifted \(formattedAmount)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, VCSpacing.md)
                    .padding(.vertical, VCSpacing.xs)
                    .background(.black.opacity(0.75), in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isVisible)
    }

    private var formattedAmount: String {
        let percent = amount * 100
        return String(format: "%+.1f%%", percent)
    }
}

#Preview("Drift pill") {
    VStack(spacing: VCSpacing.lg) {
        DriftFeedbackPill(amount: 0.034, isVisible: true)
        DriftFeedbackPill(amount: 0.128, isVisible: true)
    }
    .padding()
}

#Preview {
    VStack(spacing: VCSpacing.lg) {
        CalibrationProgressBadge(progress: 0.15, isTrained: false)
        CalibrationProgressBadge(progress: 0.7, isTrained: false)
        CalibrationProgressBadge(progress: 1.0, isTrained: true)
    }
    .padding()
}
