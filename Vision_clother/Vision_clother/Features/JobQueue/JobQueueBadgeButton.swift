//
//  JobQueueBadgeButton.swift
//  Vision_clother
//
//  Toolbar affordance for the background job queue — a hand-built badge
//  overlay since SwiftUI's `.badge()` modifier only applies to
//  `tabItem`/List rows, not arbitrary toolbar buttons. Added to every
//  tab-root view's toolbar; opens the single shared `JobQueuePanelView`
//  sheet hosted at `RootTabView` level.
//

import SwiftUI

struct JobQueueBadgeButton: View {
    @Environment(JobQueueStore.self) private var jobQueueStore

    var body: some View {
        Button {
            jobQueueStore.isPanelPresented = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "tray.full")

                if jobQueueStore.activeJobCount > 0 {
                    Text("\(jobQueueStore.activeJobCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Circle().fill(.red))
                        .offset(x: 10, y: -10)
                }
            }
        }
        .accessibilityLabel("Activity, \(jobQueueStore.activeJobCount) in progress")
    }
}
