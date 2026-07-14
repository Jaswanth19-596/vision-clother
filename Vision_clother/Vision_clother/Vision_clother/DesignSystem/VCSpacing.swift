//
//  VCSpacing.swift
//  Vision_clother
//
//  Shared 4pt-grid spacing tokens for the premium UI pass — retires the
//  ad hoc padding values (4, 6, 8, 10, 12, 14, 16, 20, 24) scattered across
//  Features/ with no shared constant.
//

import Foundation

enum VCSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    /// Default horizontal margin.
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    /// Section-level spacing.
    static let xxl: CGFloat = 24
}
