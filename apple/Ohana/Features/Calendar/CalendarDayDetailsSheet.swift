import SwiftUI

/// The selected days' details in a sheet (phones, narrow windows; iPad and Mac show
/// `CalendarSelectionDetails` under the grid): full height, a list by day whose events and notes
/// swipe to Edit and Delete, and an event opens its own page in the sheet (back to the list with
/// the caret). Editing opens over the sheet, so it comes back here.
struct CalendarDetailsSheet: View {
    @Environment(FamilyContext.self) private var family
    let store: CalendarStore
    let actions: CalendarActions
    @Environment(\.dismiss) private var dismiss
    @State private var path: [CalendarEventRef] = []
    @State private var editing: CalendarDetailsEdit?
    @State private var deleting: CalendarEvent?

    var body: some View {
        let days = store.selectedDays
        let shown = days.count == 1 ? days : days.filter(hasContent).prefix(CalendarSelectionDetails.maxDays).map { $0 }
        NavigationStack(path: $path) {
            List {
                if shown.isEmpty {
                    Text("Nothing on the selected days yet.").foregroundStyle(.secondary)
                }
                ForEach(shown, id: \.self) { day in
                    Section {
                        dayRows(day)
                    } header: {
                        if days.count > 1 { Text(CalendarText.longDay(day)) }
                    }
                }
                if days.count > 1 && days.filter(hasContent).count > CalendarSelectionDetails.maxDays {
                    Text("Only the first \(CalendarSelectionDetails.maxDays) days are listed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(days.count == 1 ? CalendarText.longDay(days[0]) : CalendarText.span(days))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: CalendarEventRef.self) { ref in
                CalendarEventPage(store: store, ref: ref, edit: { editing = .event(CalendarEventDraft($0)) },
                                  openSearch: openSearch)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                if !store.readOnly {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add event", systemImage: "plus") {
                            editing = .event(.new(on: days.first ?? .today))
                        }
                    }
                }
            }
        }
        .calendarDeleteEventDialog($deleting, store: store)
        .sheet(item: $editing) { edit in
            switch edit {
            case let .event(draft): CalendarEventSheet(store: store, draft: draft)
            case let .note(day): CalendarNoteSheet(store: store, days: [day])
            }
        }
        .errorBanner()
        .presentationDetents([.large])
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func hasContent(_ day: Day) -> Bool {
        store.entries[day] != nil || store.notes[day] != nil || store.events[day] != nil || store.birthdays[day] != nil
            || store.holidays[day] != nil
    }

    @ViewBuilder
    private func dayRows(_ day: Day) -> some View {
        let types = store.types(on: day)
        if store.isGap(day) || !types.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if store.isGap(day) {
                    Label("Not covered", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                }
                if !types.isEmpty {
                    CalendarDayTypes(types: types, store: store)
                }
            }
        }
        ForEach(store.holidays[day] ?? [], id: \.self) { h in
            Text(CalendarText.holiday(h))
        }
        if let note = store.notes[day] {
            Button {
                if !store.readOnly { editing = .note(day) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    CalendarNoteSymbol(icon: note.icon.isEmpty ? "note.text" : note.icon)
                    Text(note.comment.isEmpty ? CalendarSymbol.title(note.icon) : note.comment)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                }
            }
            .disabled(store.readOnly)
            .accessibilityLabel(Text(note.text))
            .swipeActions(edge: .trailing) {
                if !store.readOnly {
                    Button("Delete", systemImage: "trash", role: .destructive) { store.setNote(nil, on: [day]) }
                    Button("Edit", systemImage: "pencil") { editing = .note(day) }
                }
            }
        }
        ForEach((store.events[day] ?? []).sorted { $0.sortKey(on: day) < $1.sortKey(on: day) }, id: \.uid) { event in
            NavigationLink(value: CalendarEventRef(uid: event.uid, day: day)) {
                CalendarEventRowLabel(event: event, day: day)
            }
            .swipeActions(edge: .trailing) {
                if !store.readOnly {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = event }
                    Button("Edit", systemImage: "pencil") { editing = .event(CalendarEventDraft(event)) }
                }
            }
            .contextMenu {
                if !store.readOnly {
                    Button("Edit", systemImage: "pencil") { editing = .event(CalendarEventDraft(event)) }
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = event }
                }
            }
        }
        ForEach(store.birthdays[day] ?? [], id: \.self) { b in
            Text(CalendarText.birthday(b))
        }
    }

    /// The appointment search an event was booked from (the sheet closes first).
    private func openSearch(_ id: String) {
        dismiss()
        family.open(.appointmentSearch(id: id))
    }
}

/// What the details sheet opens over itself.
enum CalendarDetailsEdit: Identifiable {
    case event(CalendarEventDraft)
    case note(Day)

    var id: String {
        switch self {
        case let .event(draft): "event-\(draft.original?.uid ?? draft.eventID ?? "new")"
        case let .note(day): "note-\(day)"
        }
    }
}

/// An event of the details list: its occurrence (`uid`) and the day it was listed on.
struct CalendarEventRef: Hashable {
    var uid: String
    var day: Day
}

/// A day's entry types as tinted capsules, each with its double icon (`CalendarTypeBadge`); whose
/// type it is in the tip (hover, or a long press).
struct CalendarDayTypes: View {
    let types: [CalendarEntryType]
    let store: CalendarStore

    var body: some View {
        HStack(spacing: 6) {
            ForEach(types) { type in
                let badge = CalendarTypeBadge(type: type, member: store.member(of: type), size: 16, help: false)
                HStack(spacing: 4) {
                    badge
                    // The badge reads the name (with the member's).
                    Text(type.name).font(.subheadline).lineLimit(1).accessibilityHidden(true)
                }
                .padding(.leading, 3)
                .padding(.trailing, 8)
                .padding(.vertical, 3)
                .background(Color(calendarHex: type.color).opacity(0.18), in: .capsule)
                .contentShape(.capsule)
                .longPressTip(badge.label)
            }
        }
    }
}

/// An event in a list: what it is, when, how it repeats and where, in a few lines (the note and
/// the link are on its page).
struct CalendarEventRowLabel: View {
    let event: CalendarEvent
    let day: Day

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: event.isAppointment ? "stethoscope" : "clock")
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.person.isEmpty ? event.title : "\(event.title) (\(event.person))")
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Text(event.whenText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let repeatText = event.repeatText {
                    Label(repeatText, systemImage: "repeat")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !event.location.isEmpty {
                    Text(event.location).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// One event in full, pushed in the details sheet: when, who, where, the whole note and the
/// link; Edit and Delete. It follows the event as the calendar changes and goes back to the
/// list once it is gone.
struct CalendarEventPage: View {
    let store: CalendarStore
    let ref: CalendarEventRef
    let edit: (CalendarEvent) -> Void
    let openSearch: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var shown: CalendarEvent?
    @State private var deleting: CalendarEvent?

    var body: some View {
        let event = current ?? shown
        List {
            if let event {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title).font(.title2.weight(.semibold))
                        Text(event.whenText).foregroundStyle(.secondary)
                        if let repeatText = event.repeatText {
                            Label(repeatText, systemImage: "repeat").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    if !event.person.isEmpty {
                        LabeledContent("Who it is for", value: event.person)
                    }
                    if !event.location.isEmpty {
                        LabeledContent("Location", value: event.location)
                    }
                }
                if !event.note.isEmpty {
                    Section("Note") {
                        Text(event.note).textSelection(.enabled)
                    }
                }
                if let url = URL(string: event.url), !event.url.isEmpty {
                    Section {
                        Link(destination: url) {
                            Label(event.url, systemImage: "link").lineLimit(1)
                        }
                    }
                }
                if event.isAppointment, let searchID = event.searchId {
                    Section {
                        Button("Open the appointment search", systemImage: "stethoscope") { openSearch(searchID) }
                    } footer: {
                        Text("Booked from an appointment search.")
                    }
                }
                if !store.readOnly {
                    Section {
                        Button("Delete event", role: .destructive) { deleting = event }
                    }
                }
            }
        }
        .navigationTitle(CalendarText.day(ref.day))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !store.readOnly, let event {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { edit(event) }
                }
            }
        }
        .calendarDeleteEventDialog($deleting, store: store) { dismiss() }
        .onChange(of: current, initial: true) { _, now in
            if let now { shown = now } else if shown != nil { dismiss() }
        }
    }

    /// The event as the calendar has it now: on its day, else wherever an edit moved it.
    private var current: CalendarEvent? {
        store.events[ref.day]?.first { $0.uid == ref.uid }
            ?? store.events.values.lazy.flatMap { $0 }.first { $0.uid == ref.uid }
    }
}
