import SwiftUI

/// How the calendar works (the web's help-dialog.tsx): its gestures and shortcuts, for what
/// this device has: touch on iPhone and iPad, pointer and keyboard on iPad and Mac. The keys
/// without ⌘ work while the calendar has the focus; the ⌘ ones are in the Calendar menu.
struct CalendarHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    struct Row {
        let what: LocalizedStringKey
        let does: LocalizedStringKey
    }

    enum Section: CaseIterable {
        case touch, pointer, keyboard
    }

    /// The sections this device shows: the iPhone touch, the iPad touch, pointer (a trackpad
    /// click is a tap there, with Shift and ⌘ as on the Mac) and keyboard, the Mac pointer and
    /// keyboard.
    static func sections(mac: Bool, compact: Bool) -> [Section] {
        if mac { return [.pointer, .keyboard] }
        return compact ? [.touch] : [.touch, .pointer, .keyboard]
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(Self.sections(mac: Self.isMac, compact: sizeClass == .compact), id: \.self) { section in
                    SwiftUI.Section {
                        ForEach(Array(Self.rows(section, mac: Self.isMac).enumerated()), id: \.offset) { _, row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.what).font(.subheadline.weight(.semibold))
                                Text(row.does).font(.subheadline).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 1)
                        }
                    } header: {
                        Text(title(section))
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("How the calendar works")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .errorBanner()
        .presentationDetents([.large])
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    private static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private func title(_ section: Section) -> LocalizedStringKey {
        switch section {
        case .touch: "Touch"
        case .pointer: "Mouse and trackpad"
        case .keyboard: "Keyboard"
        }
    }

    static func rows(_ section: Section, mac: Bool) -> [Row] {
        switch section {
        case .touch:
            [
                Row(what: "Tap", does: "Select a day; tap another day to move the selection"),
                Row(what: "Long-press + drag", does: "Select a range of days (across months)"),
                Row(what: "Range", does: "Tap a start day, then “Range”, then the end day"),
                Row(what: "Multi-select", does: "Turn it on, then tap days to add or remove them; long-press + drag adds a range"),
                Row(what: "Type button", does: "Toggle that entry on the selected days (a day can have several)"),
                Row(what: "Drag the ▪ handle, or “Repeat…”", does: "Repeat the selected days forwards or backwards"),
                Row(what: "Pinch", does: "Zoom the year view in or out (iPad)"),
                Row(what: "↶ / ↷, shake, or swipe with three fingers", does: "Undo / redo"),
            ]
        case .pointer where mac:
            [
                Row(what: "Click / drag", does: "Select a day / a range of days (across months)"),
                Row(what: "Shift + click", does: "Extend the selection"),
                Row(what: "⌘ + click", does: "Add single days to the selection"),
                Row(what: "Double-click", does: "Add an icon or comment to the day"),
                Row(what: "Type button", does: "Toggle that entry on the selected days (a day can have several)"),
                Row(what: "Drag the ▪ handle", does: "Repeat the selected days forwards or backwards"),
                Row(what: "Right-click", does: "The day’s actions: details, note, event, repeat, clear"),
                Row(what: "Pinch", does: "Zoom the year view in or out"),
            ]
        case .pointer:
            [
                Row(what: "Shift + click", does: "Extend the selection"),
                Row(what: "⌘ + click", does: "Add single days to the selection"),
                Row(what: "Secondary click, or touch and hold", does: "The day’s actions: details, note, event, repeat, clear"),
            ]
        case .keyboard:
            [
                Row(what: "1 – 9 (⌥⌘1 – 9)", does: "Toggle that entry on the selected days"),
                Row(what: "Delete", does: "Clear the selected days"),
                Row(what: "⌘C / ⌘X / ⌘V", does: "Copy / cut / paste. Pasting onto a larger selection repeats the copied days to fill it."),
                Row(what: "Arrow keys", does: "Move (with Shift: extend the selection)"),
                Row(what: "⌘A", does: "Select the whole year"),
                Row(what: "⌘Z / ⇧⌘Z", does: "Undo / redo"),
                Row(what: "N", does: "Add an icon or comment to the selected days"),
                Row(what: "E / ⌘N", does: "Add a timed event"),
                Row(what: "I / Return / ⌘I", does: "Show the selected days’ details"),
                Row(what: "⌘+ / ⌘− / ⌘0", does: "Zoom the year view in / out (fewer or more days at once) / reset"),
                Row(what: "⌘T", does: "Show today"),
                Row(what: "Page Up / Page Down, ⌘[ / ⌘]", does: "Previous / next year"),
                Row(what: "G", does: "Jump to the next day that still needs cover"),
                Row(what: "?", does: "Show this help"),
                Row(what: "Esc / ⇧⌘A", does: "Stop dragging the handle, or clear the selection"),
            ]
        }
    }
}
