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
                .vcAnimation(VCMotion.entrance, value: progress)

            if isTrained {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.green)
                    .transition(VCTransition.pop)
            } else {
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(width: diameter, height: diameter)
        .vcAnimation(VCMotion.entrance, value: isTrained)
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


#Preview {
    VStack(spacing: VCSpacing.lg) {
        CalibrationProgressBadge(progress: 0.15, isTrained: false)
        CalibrationProgressBadge(progress: 0.7, isTrained: false)
        CalibrationProgressBadge(progress: 1.0, isTrained: true)
    }
    .padding()
}
