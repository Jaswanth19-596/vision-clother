//
//  VCLoadingStageView.swift
//  Vision_clother
//
//  Shared themed loading indicator for the smooth-motion pass (2026-07-25) —
//  promoted from `DailyAssistantView`'s private `LoadingStageView` (originally
//  built to replace a generic `ProgressView` + static caption during LLM
//  waits) so other multi-second waits — try-on rendering, background item
//  tagging — get the same pulsing icon + crossfading label instead of a bare
//  spinner. Generalized from `DailyAssistantViewModel.LoadingStage` to a
//  plain `(systemImage, label)` pair so callers can drive it off their own
//  state enums (`TryOnStage`, etc.) without depending on DailyAssistant.
//

import SwiftUI

struct VCLoadingStageView: View {
    let systemImage: String
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(VCAccentColor.brand)
                .symbolEffect(.pulse, options: .repeating)
                .contentTransition(.symbolEffect(.replace))

            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .premiumCard()
        .frame(maxWidth: .infinity, alignment: .leading)
        .vcAnimation(VCMotion.contentFade, value: systemImage)
        .vcAnimation(VCMotion.contentFade, value: label)
    }
}
