import SwiftUI

/// Repeats the selected days forwards or backwards up to a day: the fill handle for touch
/// screens (and the menus). The grid previews the days it fills while the sheet is open.
struct CalendarRepeatSheet: View {
    let store: CalendarStore
    @Environment(\.dismiss) private var dismiss
    @State private var source: [Day] = []
    @State private var backwards = false
    @State private var until = Date()
    @State private var done = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Direction", selection: $backwards) {
                        Text("Forwards").tag(false)
                        Text("Backwards").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if let bounds {
                        DatePicker(backwards ? LocalizedStringKey("Back to") : LocalizedStringKey("Until"),
                                   selection: $until, in: bounds.lowerBound.date...bounds.upperBound.date,
                                   displayedComponents: .date)
                    } else {
                        Text(backwards ? LocalizedStringKey("The selection starts on the first day of the year.")
                                       : LocalizedStringKey("The selection ends on the last day of the year."))
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    if let fill = store.fill {
                        Text(CalendarText.fill(fill))
                    }
                }
                if store.skipWeekends {
                    Section {
                        Label("Weekends are left out (Skip weekends).", systemImage: "calendar.day.timeline.leading")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Repeat days")
            .navigationSubtitleCompat("\(CalendarText.days(source.count)): \(CalendarText.span(source))")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton(hasChanges: false)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Repeat") {
                        done = true
                        store.endFill()
                        dismiss()
                    }
                    .disabled(store.fill?.targets.isEmpty ?? true)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .errorBanner()
        .presentationDetents([.medium])
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 280)
        #endif
        .onAppear {
            source = store.selectedDays
            guard store.beginFill() else { return dismiss() }
            resetUntil()
        }
        .onChange(of: backwards) { resetUntil() }
        .onChange(of: until) { store.dragFill(to: Day(until)) }
        .onDisappear {
            if !done { store.cancelFill() }
        }
    }

    /// The days it can repeat to: after the selection up to the year's end, or before it from
    /// the year's start. Nil when there are none.
    private var bounds: ClosedRange<Day>? {
        Self.bounds(source: source, backwards: backwards, year: store.year)
    }

    static func bounds(source: [Day], backwards: Bool, year: Int) -> ClosedRange<Day>? {
        guard let first = source.first, let last = source.last else { return nil }
        if backwards {
            let start = Day(year: year, month: 1, day: 1)
            let end = CalendarMath.add(first, -1)
            return start <= end ? start...end : nil
        }
        let start = CalendarMath.add(last, 1)
        let end = Day(year: year, month: 12, day: 31)
        return start <= end ? start...end : nil
    }

    /// Starts with one repetition of the selection.
    private func resetUntil() {
        guard let bounds, let first = source.first, let last = source.last else { return }
        let once = backwards ? CalendarMath.add(first, -source.count) : CalendarMath.add(last, source.count)
        let day = min(max(once, bounds.lowerBound), bounds.upperBound)
        until = day.date
        store.dragFill(to: day)
    }
}
