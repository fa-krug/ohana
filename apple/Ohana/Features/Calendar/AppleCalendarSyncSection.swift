import EventKit
import SwiftUI

/// What the Apple Calendar section asks to show: the calendar picker, the stop dialog. They are
/// presented from the form (`appleCalendarSyncPrompts`), not from the section: a section hands
/// its modifiers to its header, rows and footer, and several presenters of one sheet dismissed it
/// at once, and the settings sheet with it.
@Observable
final class AppleCalendarSyncPrompts {
    var picking = false
    var stopping = false
}

/// Settings → Calendar: this device syncs the family's calendar with an Apple Calendar calendar
/// (`AppleCalendarSync`): which one, the day entries too, its state, sync now, stop. Not in the
/// demo. The form presents its `prompts`.
struct AppleCalendarSyncSection: View {
    let prompts: AppleCalendarSyncPrompts
    @Environment(FamilyContext.self) private var family
    @Environment(\.openURL) private var openURL
    @State private var sync = AppleCalendarSync.shared

    var body: some View {
        if !family.api.client.isDemo {
            Section {
                if let state = sync.state(for: family.api) {
                    syncing(state)
                } else if sync.access == .denied || sync.access == .restricted || sync.access == .writeOnly {
                    Text("Ohana has no access to your calendars. Allow it in the Settings app under Privacy & Security → Calendars.")
                        .foregroundStyle(.secondary)
                    Button("Open Settings", systemImage: "gear") { openURL(Self.settingsURL) }
                } else {
                    Button("Sync with Apple Calendar…", systemImage: "arrow.triangle.2.circlepath") {
                        Task { if await sync.requestAccess() { prompts.picking = true } }
                    }
                }
            } header: {
                Text("Apple Calendar")
            } footer: {
                Text(family.canEdit
                     ? "Events go both ways between Ohana and the calendar you pick, repeating ones and edits and deletions too; when both changed, Ohana’s wins. Day entries go to Apple Calendar only, as all-day events. It syncs on this device while Ohana is open."
                     : "You can view this family only: its events and day entries go to the calendar you pick, nothing comes back. It syncs on this device while Ohana is open.")
            }
        }
    }

    @ViewBuilder
    private func syncing(_ state: AppleCalendarSyncState) -> some View {
        let calendar = sync.calendar(state.calendarID)
        LabeledContent("Calendar") {
            HStack(spacing: 6) {
                if let color = calendar?.cgColor {
                    Circle().fill(Color(cgColor: color)).frame(width: 10, height: 10)
                }
                Text(verbatim: calendar?.title ?? state.calendarTitle)
            }
        }
        Toggle("Day entries as all-day events", isOn: Binding(get: { state.entries }, set: { on in
            Task { await sync.setEntries(on, for: family) }
        }))
        if sync.isRunning(family.api) {
            LabeledContent("Syncing…") { ProgressView().controlSize(.small) }
        } else if let last = state.lastSync {
            LabeledContent("Last synced") { Text(last, format: .relative(presentation: .named)) }
        }
        if let error = sync.error(family.api) {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
        let held = sync.heldBack(family.api)
        if held > 0 {
            Label("\(held) events are missing in Apple Calendar at once. To be safe they weren’t deleted in Ohana.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        Button("Sync now", systemImage: "arrow.clockwise") { Task { await sync.sync(family) } }
            .disabled(sync.isRunning(family.api))
        if calendar == nil {
            Button("Pick another calendar", systemImage: "calendar") {
                Task { if await sync.requestAccess() { prompts.picking = true } }
            }
        }
        Button("Stop syncing", systemImage: "xmark.circle", role: .destructive) { prompts.stopping = true }
    }

    private static var settingsURL: URL {
        #if os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        #else
        URL(string: UIApplication.openSettingsURLString)!
        #endif
    }
}

extension View {
    /// Presents the Apple Calendar section's picker and stop dialog; on the form around it.
    func appleCalendarSyncPrompts(_ prompts: AppleCalendarSyncPrompts) -> some View {
        modifier(AppleCalendarSyncPromptsModifier(prompts: prompts))
    }
}

private struct AppleCalendarSyncPromptsModifier: ViewModifier {
    @Bindable var prompts: AppleCalendarSyncPrompts
    @Environment(FamilyContext.self) private var family

    func body(content: Content) -> some View {
        let sync = AppleCalendarSync.shared
        content
            .sheet(isPresented: $prompts.picking) {
                AppleCalendarPicker(familyName: family.family.name) { calendar, entries in
                    Task { await sync.enable(family, calendar: calendar, entries: entries) }
                }
            }
            .confirmationDialog("Stop syncing with Apple Calendar?", isPresented: $prompts.stopping, titleVisibility: .visible) {
                Button("Stop and remove Ohana’s events from it", role: .destructive) {
                    sync.disable(family, removeCopies: true)
                }
                Button("Stop, keep the events") { sync.disable(family, removeCopies: false) }
            } message: {
                Text("Events that came from Apple Calendar stay in both.")
            }
    }
}

/// Picks the Apple calendar to sync with (one Ohana can write to), or makes a new one named after
/// the family.
private struct AppleCalendarPicker: View {
    let familyName: String
    let done: (EKCalendar, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    @State private var entries = true
    @State private var groups: [(source: String, calendars: [EKCalendar])] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        do {
                            let calendar = try AppleCalendarSync.shared.makeCalendar(title: familyName)
                            done(calendar, entries)
                            dismiss()
                        } catch {
                            ErrorBanner.shared.show(error.localizedDescription)
                        }
                    } label: {
                        Label("New calendar “\(familyName)”", systemImage: "calendar.badge.plus")
                    }
                } footer: {
                    Text("Best a calendar of its own: every event in it goes to Ohana.")
                }
                ForEach(groups, id: \.source) { group in
                    Section {
                        ForEach(group.calendars, id: \.calendarIdentifier) { calendar in
                            Button {
                                selected = calendar.calendarIdentifier
                            } label: {
                                HStack {
                                    Circle().fill(Color(cgColor: calendar.cgColor)).frame(width: 10, height: 10)
                                    Text(verbatim: calendar.title).foregroundStyle(.primary)
                                    Spacer()
                                    if selected == calendar.calendarIdentifier {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(verbatim: group.source)
                    }
                }
                Section {
                    Toggle("Day entries as all-day events", isOn: $entries)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Apple Calendar")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton(hasChanges: false)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sync") {
                        guard let id = selected, let calendar = AppleCalendarSync.shared.calendar(id) else { return }
                        done(calendar, entries)
                        dismiss()
                    }
                    .disabled(selected == nil)
                }
            }
            .onAppear { groups = AppleCalendarSync.shared.calendars() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}
