//
//  VCMotion.swift
//  Vision_clother
//
//  The app's single motion vocabulary (2026-07-26). Every animation in the
//  client resolves to one of the four `VCMotion` tokens and one of the
//  `VCTransition` shapes below — no view declares its own `spring(...)` or
//  `easeInOut(...)` literal, so the whole app moves with one rhythm.
//
//  Sizing: the first pass (2026-07-25) used a 0.22s opacity-only budget that
//  read as an instant cut on device — the user reported seeing no animation
//  at all. These values are deliberately larger, and every transition carries
//  *movement* (offset/scale), not just opacity, because opacity alone between
//  two same-background surfaces is invisible.
//
//  Accessibility: use `vcAnimation(_:value:)` rather than SwiftUI's
//  `.animation(_:value:)` — it reads `accessibilityReduceMotion` internally so
//  no call site can forget it. For `withAnimation` call sites, read
//  `@Environment(\.accessibilityReduceMotion)` in the view and pass the token
//  through `vcMotion(_:reduceMotion:)`.
//

import SwiftUI

enum VCMotion {
    /// Button/control press feedback and other immediate tap responses.
    static let interactive = Animation.spring(response: 0.25, dampingFraction: 0.70)
    /// List/grid inserts and removals, discrete state swaps — the default.
    static let standard = Animation.spring(response: 0.38, dampingFraction: 0.78)
    /// Text/segment/tab content crossfades where nothing structural moves.
    static let contentFade = Animation.easeInOut(duration: 0.28)
    /// One-shot appearance (onboarding step content, staggered entrances).
    static let entrance = Animation.spring(response: 0.45, dampingFraction: 0.80)
    /// Settle after a direct-manipulation gesture (drag snap-back, pinch-zoom,
    /// pan re-center) — slightly stiffer so it tracks the finger's last frame
    /// instead of floating away from it.
    static let gesture = Animation.spring(response: 0.32, dampingFraction: 0.82)

    /// A committed fly-off/dismissal that other work must be sequenced
    /// *after* — e.g. `SwipeDiscoveryView` swaps in the next card only once
    /// the current one has left the screen. The duration is exposed
    /// separately because those call sites schedule the follow-up mutation
    /// for exactly when the animation lands; the two must stay equal or the
    /// next card appears mid-flight.
    static let commitDuration: TimeInterval = 0.28
    static let commit = Animation.easeOut(duration: commitDuration)
}

/// Shared transition shapes. Declared here rather than inline so "how a card
/// enters" is one decision made once, not re-guessed per screen.
enum VCTransition {
    /// Cards and grid cells — scales up from slightly small while fading in.
    static let card: AnyTransition = .scale(scale: 0.94).combined(with: .opacity)

    /// Chat rounds and other timeline rows. Asymmetric on purpose: the
    /// insertion rises 14pt into place (small enough that it doesn't fight
    /// `DailyAssistantView`'s animated `proxy.scrollTo`), while removal just
    /// fades so a failed/superseded round doesn't yank the timeline.
    static let message: AnyTransition = .asymmetric(
        insertion: .offset(y: 14).combined(with: .opacity),
        removal: .opacity
    )

    /// Badges, checkmarks, and other small confirmations that should feel like
    /// they pop into existence.
    static let pop: AnyTransition = .scale(scale: 0.6).combined(with: .opacity)

    /// Direction-aware horizontal slide for segmented-control content swaps —
    /// content enters from the side the user moved toward, matching the
    /// direction of their tap on the picker.
    static func lateral(forward: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }
}

extension View {
    /// Reduce-Motion-aware replacement for `.animation(_:value:)`. Use this
    /// everywhere instead of the SwiftUI original: when the user has Reduce
    /// Motion enabled the state change lands instantly rather than animating,
    /// and because the check lives inside the modifier no call site can skip
    /// it.
    func vcAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(VCAnimated(animation: animation, value: value))
    }

    /// Returns `nil` in place of `animation` when the user has Reduce Motion
    /// enabled, so `withAnimation(vcMotion(VCMotion.standard, reduceMotion: reduceMotion)) { ... }`
    /// call sites degrade to an instant state change instead of ignoring the
    /// accessibility setting. Only needed for imperative `withAnimation`
    /// blocks — declarative sites should use `vcAnimation(_:value:)` above.
    func vcMotion(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// Staggers a step/list entrance: fades and slides content up into place
    /// as the view is inserted into the tree, offset by `index * 0.06s` so
    /// sibling elements cascade in rather than appearing simultaneously.
    /// Uses `AnyTransition.animation(_:)` (not `.animation(value:)`) since the
    /// per-element delay must fire on insertion itself — a value-keyed
    /// `.animation` never triggers on a view's very first render.
    func vcStaggeredEntrance(index: Int) -> some View {
        modifier(VCStaggeredEntrance(index: index))
    }

    /// Continuous, scroll-driven depth for a horizontally paged card: the
    /// off-center card sits slightly back and dimmed, resolving to full size
    /// and opacity as it centers. Unlike a state-keyed animation this tracks
    /// the drag frame-by-frame, which is what makes a carousel read as fluid
    /// rather than as a series of snaps.
    func vcCarouselCardTransition() -> some View {
        modifier(VCCarouselCardTransition())
    }

    /// Continuous, scroll-driven entrance for cells in a vertically scrolling
    /// grid or stack — each cell fades and scales up as it crosses into view
    /// instead of appearing fully formed at the edge.
    func vcScrollEntrance() -> some View {
        modifier(VCScrollEntrance())
    }
}

private struct VCAnimated<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

private struct VCCarouselCardTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Read out of the environment *before* the closure — `scrollTransition`'s
        // transition closure is non-isolated and can't reference a main-actor
        // property, but it can capture a plain `Bool`.
        let isReduced = reduceMotion
        return content.scrollTransition(.interactive, axis: .horizontal) { view, phase in
            let isFlat = isReduced || phase.isIdentity
            return view
                .scaleEffect(isFlat ? 1.0 : 0.93)
                .opacity(isFlat ? 1.0 : 0.72)
        }
    }
}

private struct VCScrollEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let isReduced = reduceMotion
        return content.scrollTransition(.interactive, axis: .vertical) { view, phase in
            let isFlat = isReduced || phase.isIdentity
            return view
                .scaleEffect(isFlat ? 1.0 : 0.90)
                .opacity(isFlat ? 1.0 : 0.0)
        }
    }
}

private struct VCStaggeredEntrance: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(
            .opacity.combined(with: .offset(y: 12))
                .animation(reduceMotion ? nil : VCMotion.entrance.delay(Double(index) * 0.06))
        )
    }
}
