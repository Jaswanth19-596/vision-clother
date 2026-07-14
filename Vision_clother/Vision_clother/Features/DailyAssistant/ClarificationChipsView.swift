//
//  ClarificationChipsView.swift
//  Vision_clother
//
//  Clarification Loop (Stylist Intelligence Engine ADR, Phase 2) — renders
//  the recommendation call's follow-up question plus tappable quick-reply
//  chips instead of the outfit carousel while intent is still ambiguous.
//

import SwiftUI

/// Wraps chip buttons onto new lines instead of a horizontal scroll — a
/// chip like "Job Interview" competing with "Party" for viewport width
/// reads awkwardly in a single scrollable row.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > maxWidth, origin.x > 0 {
                origin.x = 0
                origin.y += rowHeight + spacing
                totalHeight += rowHeight + spacing
                rowHeight = 0
            }
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight

        return CGSize(width: maxWidth.isFinite ? maxWidth : origin.x, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var origin = CGPoint(x: bounds.minX, y: bounds.minY)
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x + size.width > bounds.minX + maxWidth, origin.x > bounds.minX {
                origin.x = bounds.minX
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: origin, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Renders `follow_up_text` + tappable `suggested_chips` inline in the chat
/// timeline (`DailyAssistantView`'s per-round rendering) — a chip tap calls
/// `onSelectChip` with its own label immediately (auto-submit), no separate
/// confirm step. Reset/"New" lives once in the timeline's toolbar rather
/// than duplicated per-round here.
struct ClarificationChipsView: View {
    let followUpText: String
    let chips: [String]
    let onSelectChip: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(followUpText, systemImage: "bubble.left.and.text.bubble.right")
                .font(.body)
                .foregroundStyle(.primary)

            if !chips.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(chips, id: \.self) { chip in
                        Button(chip) { onSelectChip(chip) }
                            .buttonStyle(.bordered)
                            .tint(.accentColor)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
