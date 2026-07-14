//
//  VCButtonStyles.swift
//  Vision_clother
//
//  Shared tactile button styles for the premium UI pass — no custom
//  `ButtonStyle` existed anywhere in the app before this; every button used
//  stock `.bordered`/`.borderedProminent`. These fully replace those two:
//  `.buttonStyle(.borderedProminent)` -> `.buttonStyle(PrimaryButtonStyle())`,
//  `.buttonStyle(.bordered)` -> `.buttonStyle(SecondaryButtonStyle())`.
//
//  Haptics are deliberately NOT baked in here — these styles fire on every
//  press (chips, toggles, etc.), which is exactly what's out of scope for
//  the app's critical-actions-only haptic policy. `.sensoryFeedback` is
//  wired individually at the handful of critical call sites instead.
//

import SwiftUI

private let vcButtonSpring = Animation.spring(response: 0.22, dampingFraction: 0.72)

struct PrimaryButtonStyle: ButtonStyle {
    var isDestructive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.horizontal, VCSpacing.lg)
            .padding(.vertical, VCSpacing.md)
            .frame(maxWidth: .infinity)
            .background(isDestructive ? Color.red : Color.accentColor, in: VCRadius.shape(VCRadius.control))
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(vcButtonSpring, value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    /// Explicit, not environment `.tint()` — a bare `ButtonStyle` does not
    /// inherit `.tint()` the way `.bordered` does, so call sites that encode
    /// semantic meaning in color (e.g. a wear-again yes/no row) must pass
    /// their color here rather than relying on a `.tint()` modifier upstream.
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, VCSpacing.lg)
            .padding(.vertical, VCSpacing.sm)
            .background(.thinMaterial, in: VCRadius.shape(VCRadius.control))
            .foregroundStyle(tint)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.82 : 1.0)
            .animation(vcButtonSpring, value: configuration.isPressed)
    }
}
