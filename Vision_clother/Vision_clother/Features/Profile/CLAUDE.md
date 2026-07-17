# Features/Profile Module

User-profile features and visual taste calibration display.
- `ProfileView` uses narrative explanations (e.g. `pairingNarrative()`, `affinityQualifier()`) to present taste profile, formality zones, and color trends. Raw charts have been replaced in full (Swift Charts removed from this view).
- Account management, credit purchases, and diagnostic log sharing live in `AccountSectionView`.
- **Settings Sheet:** `AccountSectionView` is hosted in a dedicated sheet (`isSettingsPresented`) triggered by the toolbar gear button — never in `ProfileView`'s main list flow.
- **Modifier Placement In List:** Any presentation (`.sheet`, `.alert`) or lifecycle (`.task`) modifiers inside `AccountSectionView` must be attached to a single leaf view (e.g., a zero-height `Color.clear` cell) rather than `Section`. Attaching sheet modifiers to `Section` causes SwiftUI to duplicate presentation attempts on every list item, corrupting the navigation/sheet context and causing sheets (like "Buy Credits") to automatically close.
- **Portrait Photo Flow:** User portrait captures are validated via `PersonPhotoValidationService` and saved to `UserPortraitStorage` + Firestore/Cloud Storage metadata (`users/{uid}/portrait/base_portrait.jpg`).
