//
//  VCRadius.swift
//  Vision_clother
//
//  Shared corner-radius tokens for the premium UI pass — consolidates the
//  ad hoc 10/12/14/16/20pt radii previously scattered across Features/ (no
//  shared constant, applied inconsistently to similar-purpose surfaces) into
//  four named tiers, always built with `.continuous` corner style.
//

import SwiftUI

enum VCRadius {
    /// Photo/color-swatch thumbnails.
    static let swatch: CGFloat = 10
    /// Buttons, chips, and other small controls.
    static let control: CGFloat = 12
    /// Standard card/bubble surface — the default premium container radius.
    static let card: CGFloat = 16
    /// Larger primary containers (e.g. slot-row groups, hero cards).
    static let prominent: CGFloat = 20

    static func shape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}
