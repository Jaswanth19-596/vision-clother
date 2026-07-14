//
//  VCShadow.swift
//  Vision_clother
//
//  Shared subtle-shadow tokens for the premium UI pass — no `.shadow(...)`
//  existed anywhere in Features/ before this; per the premium-UI guidance,
//  shadows must stay subtle, never harsh/dark.
//

import SwiftUI

struct VCShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

enum VCShadow {
    /// Standard card elevation.
    static let subtle = VCShadowStyle(color: .black.opacity(0.04), radius: 10, x: 0, y: 4)
    /// Reserved for the single most important CTA on a screen.
    static let elevated = VCShadowStyle(color: .black.opacity(0.08), radius: 16, x: 0, y: 6)
}

extension View {
    func vcShadow(_ style: VCShadowStyle = VCShadow.subtle) -> some View {
        shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }
}
