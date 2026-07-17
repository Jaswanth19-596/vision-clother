# Features/Pairing Module

Manual outfit building and prospective try-on pipeline.
- `ManualPairingView` allows the user to manually select garments for slot-based combinations (accessory, top, bottom, outerwear, bag, footwear, headwear).
- **Try-On Gate:** "Try On" enqueues background rendering via `JobQueueStore`. The flow requires a linked user account (non-anonymous) and a valid user portrait photo uploaded on the Profile tab.
- Replaced manual tap gestures with standard buttons (`.buttonStyle(.plain)`) for proper press highlights in SwiftUI list/grid container cells.
