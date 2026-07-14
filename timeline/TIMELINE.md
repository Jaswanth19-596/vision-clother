# Vision Clother — Change Timeline

---

## 2026-07-14 — Fix: Try-On Button Allows Duplicate Queue Submissions

**Status:** ✅ Shipped — Build Succeeded

### Problem
After tapping "How does it look on me?", the button showed "Added to queue" for 1.5 seconds then reset back to the original label — letting the user submit the same outfit combination to the try-on queue multiple times.

### Fix
Replaced `justQueuedTryOn: Bool` + `Task.sleep` reset with `queuedOutfitIDs: Set<OutfitCombination.ID>`. Each outfit's queued state is now **permanent and per-outfit**:
- Once queued, the button stays locked as "Added to queue ✓" for that outfit forever
- Swiping to a different (unqueued) outfit shows a fresh active button for that card
- Swiping back to an already-queued outfit keeps it locked — no re-submission possible

### Changes

| File | Change |
|---|---|
| `Features/DailyAssistant/DailyAssistantView.swift` | Replaced `@State var justQueuedTryOn: Bool` + `Task.sleep` reset with `@State var queuedOutfitIDs: Set<OutfitCombination.ID>`; removed the Task entirely |

---

## 2026-07-14 — Fix: Outfit Carousel Unswipeable + Screen Scroll Frozen

**Status:** ✅ Shipped — Build Succeeded

### Problem
After the previous UX pass, the outfit recommendation carousel was completely unswipeable and tapping anywhere inside the card area froze the entire screen's vertical scroll. Root cause was a three-layer gesture conflict:

```
ScrollView (vertical)   ← outer chat timeline
  └── TabView(.page)    ← UIKit page controller stealing horizontal drags
       └── OutfitCardView
            └── ScrollView (vertical)  ← inner scroll competing with outer
```

The `TabView(.page)` UIKit gesture recognisers intercept horizontal drags before the outer `ScrollView` can route them correctly. The `highPriorityGesture(DragGesture)` workaround added previously made things worse — it claimed *all* drag directions, freezing the outer vertical scroll entirely.

### Fix
Replaced the entire carousel stack with orthogonal `ScrollView`s — iOS routes horizontal drags to the inner one and vertical drags to the outer one automatically, with no workarounds:

```
ScrollView (vertical)       ← outer chat timeline
  └── ScrollView(.horizontal) ← new carousel, orthogonal = no conflict
       └── OutfitCardView      ← plain VStack, inner scroll removed
```

### Changes

| File | Change |
|---|---|
| `Features/DailyAssistant/DailyAssistantView.swift` | Replaced `TabView(.page)` + broken `highPriorityGesture` with `ScrollView(.horizontal)` + `scrollTargetBehavior(.viewAligned)` + `scrollTargetLayout()`; added custom animated dot-indicator row |
| `Features/DailyAssistant/OutfitCardView.swift` | Removed inner vertical `ScrollView` — was competing with the outer chat `ScrollView` and causing scroll freeze on tap |

---

## 2026-07-14 — UX Polish: Daily Assistant & Recommendations Navigation

**Status:** ✅ Shipped — Build Succeeded

### Problem
Buttons in the Daily Assistant and Recommendations screens felt sticky and unresponsive:
- Swiping between outfit cards in the carousel was intercepted by the outer scroll view
- Collapse/expand of historical outfit rounds had no animation (jarring instant layout jump)
- Clarification chips could be double-tapped with no visual feedback during async wait
- Item picker tiles in Try-On used `.onTapGesture` — no press-down highlight
- Button spring animation was too slow (0.35s response) making all presses feel laggy

### Changes

| File | Change |
|---|---|
| `DesignSystem/VCButtonStyles.swift` | Tightened spring `response: 0.35 → 0.22`, increased scale/opacity travel for crisper press feedback |
| `Features/DailyAssistant/DailyAssistantView.swift` | Added `.highPriorityGesture(DragGesture)` + `.clipped()` to TabView carousel; animated expand/collapse; animated try-on button label transition; added `.scrollBounceBehavior(.basedOnSize)` |
| `Features/DailyAssistant/ClarificationChipsView.swift` | Added `@State private var selectedChip` — tapping a chip immediately shows ✓ checkmark and dims all others, blocking double-taps |
| `Features/Pairing/ManualPairingView.swift` | Replaced `.onTapGesture` with `Button { }.buttonStyle(.plain)` on item cells for proper press feedback; added `.scrollBounceBehavior(.basedOnSize)` |
## 2026-07-14 — UX Polish: Daily Assistant & Recommendations Navigation

**Status:** ✅ Shipped — Build Succeeded

### Problem
Buttons in the Daily Assistant and Recommendations screens felt sticky and unresponsive:
- Swiping between outfit cards in the carousel was intercepted by the outer scroll view
- Collapse/expand of historical outfit rounds had no animation (jarring instant layout jump)
- Clarification chips could be double-tapped with no visual feedback during async wait
- Item picker tiles in Try-On used `.onTapGesture` — no press-down highlight
- Button spring animation was too slow (0.35s response) making all presses feel laggy

### Changes

| File | Change |
|---|---|
| `DesignSystem/VCButtonStyles.swift` | Tightened spring `response: 0.35 → 0.22`, increased scale/opacity travel for crisper press feedback |
| `Features/DailyAssistant/DailyAssistantView.swift` | Added `.highPriorityGesture(DragGesture)` + `.clipped()` to TabView carousel to claim horizontal swipes from the outer ScrollView; animated expand/collapse with `.spring`; animated try-on button label transition; added `.scrollBounceBehavior(.basedOnSize)` |
| `Features/DailyAssistant/ClarificationChipsView.swift` | Added `@State private var selectedChip` — tapping a chip immediately shows ✓ checkmark and dims all others, blocking double-taps before async round completes |
| `Features/Pairing/ManualPairingView.swift` | Replaced `.onTapGesture` with `Button { }.buttonStyle(.plain)` on item cells for proper press feedback; added `.scrollBounceBehavior(.basedOnSize)` to horizontal item picker |
