//
//  PremiumCard.swift
//  Vision_clother
//
//  Shared elevated-surface treatment for the premium UI pass — the one
//  mechanical target every ad hoc
//  `.background(.thinMaterial/.regularMaterial/.ultraThinMaterial, in: RoundedRectangle(cornerRadius: N))`
//  call site across Features/ converts to, so every card in the app draws
//  from the same radius/material/shadow tokens.
//

import SwiftUI

private struct OptionalShadow: ViewModifier {
    let style: VCShadowStyle?

    func body(content: Content) -> some View {
        if let style {
            content.vcShadow(style)
        } else {
            content
        }
    }
}

extension View {
    /// Wraps content in a material-backed, continuous-corner card with a
    /// hairline edge for definition and an optional subtle shadow.
    func premiumCard(
        radius: CGFloat = VCRadius.card,
        material: Material = .thinMaterial,
        padding: CGFloat = VCSpacing.lg,
        shadow: VCShadowStyle? = VCShadow.subtle
    ) -> some View {
        self
            .padding(padding)
            .background(material, in: VCRadius.shape(radius))
            .overlay(
                VCRadius.shape(radius).strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
            )
            .modifier(OptionalShadow(style: shadow))
    }
}
