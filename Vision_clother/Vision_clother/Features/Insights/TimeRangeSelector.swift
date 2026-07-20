//
//  TimeRangeSelector.swift
//  Vision_clother
//
//  Analytics & Insights — shared time-range control (30d/3mo/6mo/1yr/all-time)
//  built once here per the Phase 1 plan's note that every Insights sub-tab
//  reuses it, wrapping the pure `Domain/AnalyticsTimeRange.swift` enum.
//

import SwiftUI

struct TimeRangeSelector: View {
    @Binding var selection: AnalyticsTimeRange

    var body: some View {
        Picker("Time Range", selection: $selection) {
            ForEach(AnalyticsTimeRange.allCases) { range in
                Text(range.shortLabel)
                    .accessibilityLabel(range.label)
                    .tag(range)
            }
        }
        .pickerStyle(.segmented)
    }
}

#Preview {
    @Previewable @State var selection: AnalyticsTimeRange = .threeMonths
    return TimeRangeSelector(selection: $selection)
        .padding()
}
