import SwiftUI

/// Settings → Calendar (the web's calendar and feed tabs): the entry types of a year (name,
/// color, role, away, order; add, delete, copy from another year), the view settings of this
/// device, and the calendar feed (subscription URL with its options, a new address).
struct CalendarSettingsView: View {
    @Environment(FamilyContext.self) private var family
    @State private var store: CalendarStore?

    var body: some View {
        Group {
            if let store {
                CalendarSettingsContent(store: store)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Calendar")
        .onAppear {
            if store == nil { store = CalendarStore(api: family.api, readOnly: !family.canEdit) }
        }
    }
}

private struct CalendarSettingsContent: View {
    @Environment(FamilyContext.self) private var family
    @Environment(AppModel.self) private var app
    @Bindable var store: CalendarStore
    @State private var editing: CalendarEntryType?
    @State private var deleting: CalendarEntryType?
    @State private var rotating: String?
    @AppStorage("ohana.calendar.showWeekdays") private var alwaysWeekdays = false

    var body: some View {
        LoadStateView(state: loadState, retry: { await store.load() }) { _ in
            Form {
                typesSection
                rolesSection
                viewSection
                CalendarFeedSection(store: store, rotating: $rotating)
                if !store.typesReadOnly, let legacy = store.family?.legacyId {
                    legacySection(legacy)
                }
            }
            .formStyle(.grouped)
        }
        .overlay(alignment: .topTrailing) {
            if let copy = store.savedCopy {
                SavedCopyBadge(date: copy.date, updating: copy.updating, retry: { await store.load() })
            }
        }
        .ohanaBackground(ModuleTint.calendar)
        .task(id: [family.revision(.calendar), family.revision(.family)]) { await store.load(quiet: store.isLoaded) }
        .onAppear {
            let family = family
            store.notify = { area in family.didChange(area) }
        }
        // A type just added opens in its editor.
        .navigationDestination(item: $editing) { type in
            CalendarTypeEditor(store: store, type: type).assistantButton()
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { type in
            Button("Delete", role: .destructive) {
                perform { try await store.deleteType(type.id) }
            }
        } message: { type in
            let used = store.daysWith(type.id)
            if used > 0 {
                Text(CalendarText.usedOn(used, year: store.year))
            }
        }
        .confirmationDialog(rotateTitle, isPresented: Binding(get: { rotating != nil }, set: { if !$0 { rotating = nil } }),
                            titleVisibility: .visible, presenting: rotating) { link in
            Button(link == "legacy" ? String(localized: "Remove") : String(localized: "New feed address"), role: .destructive) {
                perform {
                    try await store.rotateLink(link)
                    store.showToast(link == "legacy" ? String(localized: "Old link removed.") : String(localized: "New feed address made."))
                }
            }
        } message: { link in
            Text(link == "legacy"
                 ? LocalizedStringKey("Calendar subscriptions made with the old link stop updating.")
                 : LocalizedStringKey("Calendar subscriptions with the current address stop updating and need to be added again."))
        }
        .overlay(alignment: .bottom) { CalendarToast(store: store) }
    }

    private var loadState: LoadState<Bool> {
        switch store.phase {
        case .loading: .loading
        case .loaded: .loaded(true)
        case let .failed(message): .failed(message)
        case .notFound: .failed(String(localized: "This calendar can’t be loaded: the family doesn’t exist (anymore), or you’re not a member of it."))
        }
    }

    private var deleteTitle: String {
        guard let deleting else { return "" }
        return String(localized: "Delete “\(deleting.name)”?")
    }

    private var rotateTitle: String {
        rotating == "legacy" ? String(localized: "Remove the old calendar link?") : String(localized: "Make a new feed address?")
    }

    // MARK: Types

    private var typesSection: some View {
        Section {
            HStack {
                Button {
                    store.setYear(store.year - 1)
                } label: {
                    Label("Previous year", systemImage: "chevron.left")
                }
                Spacer()
                Text(verbatim: String(store.year)).font(.headline.monospacedDigit())
                Spacer()
                Button {
                    store.setYear(store.year + 1)
                } label: {
                    Label("Next year", systemImage: "chevron.right")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)

            if store.typeYears != nil && store.types.isEmpty {
                Text(store.typesReadOnly ? LocalizedStringKey("No entry types for \(String(store.year)).") : LocalizedStringKey("No entry types for \(String(store.year)) yet."))
                    .foregroundStyle(.secondary)
            }
            let stats = store.stats
            ForEach(Array(store.types.enumerated()), id: \.element.id) { index, type in
                typeRow(type, index: index, stats: stats[type.id] ?? CalendarTypeStats())
            }
            .onMove(perform: store.typesReadOnly ? nil : { from, to in
                perform { try await store.moveTypes(from: from, to: to) }
            })
            if !store.typesReadOnly {
                Button {
                    perform {
                        let type = try await store.addType()
                        editing = type
                    }
                } label: {
                    Label("Add type", systemImage: "plus")
                }
                if store.types.isEmpty, let source = store.copySource {
                    Button {
                        perform { try await store.copyTypes(from: source) }
                    } label: {
                        Label("Copy types from \(String(source))", systemImage: "doc.on.doc")
                    }
                }
                let others = (store.typeYears ?? []).filter { $0 != store.year }
                if !others.isEmpty {
                    Menu {
                        ForEach(others.reversed(), id: \.self) { y in
                            Button(String(y)) {
                                perform {
                                    try await store.copyTypes(from: y)
                                    store.showToast(String(localized: "Types copied."))
                                }
                            }
                        }
                    } label: {
                        Label("Copy from another year", systemImage: "calendar.badge.clock")
                    }
                }
            }
        } header: {
            Text("Entry types")
        } footer: {
            if store.isViewer {
                Text("Only editors of the family can change entry types.")
            } else {
                Text("These types belong to \(String(store.year)) – every year has its own. Changes are saved immediately. Copying from another year adds the types that \(String(store.year)) doesn’t have yet.")
            }
        }
    }

    private func typeRow(_ type: CalendarEntryType, index: Int, stats: CalendarTypeStats) -> some View {
        Group {
            if store.typesReadOnly {
                typeLabel(type, stats: stats)
            } else {
                NavigationLink {
                    CalendarTypeEditor(store: store, type: type).assistantButton()
                } label: {
                    typeLabel(type, stats: stats)
                }
            }
        }
        .contextMenu {
            if !store.typesReadOnly {
                Button("Edit", systemImage: "pencil") { editing = type }
                Button("Move up", systemImage: "arrow.up") {
                    perform { try await store.moveTypes(from: [index], to: index - 1) }
                }
                .disabled(index == 0)
                Button("Move down", systemImage: "arrow.down") {
                    perform { try await store.moveTypes(from: [index], to: index + 2) }
                }
                .disabled(index == store.types.count - 1)
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = type }
            }
        }
        #if os(iOS)
        .swipeActions {
            if !store.typesReadOnly {
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = type }
            }
        }
        #endif
    }

    private func typeLabel(_ type: CalendarEntryType, stats: CalendarTypeStats) -> some View {
        HStack(spacing: 12) {
            CalendarSwatch(type: type, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(type.name).foregroundStyle(.primary)
                Text(type.isAway ? "\(type.role.title) · \(String(localized: "Away"))" : type.role.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            // The counts stacked and on one line each, so they don't squeeze the name; none
            // for a type without days.
            if stats.days > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(CalendarText.days(stats.days)).font(.subheadline)
                    Text(CalendarText.workdays(stats.workdays)).font(.caption)
                }
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
        }
    }

    private var rolesSection: some View {
        Section {
            DisclosureGroup("What do the roles do?") {
                ForEach([CalendarRole.needsCover, .covers, .dayOff, .none]) { role in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(role.title).font(.subheadline.weight(.semibold))
                        Text(role.help).font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Away").font(.subheadline.weight(.semibold))
                    Text("With any role: the whole family is away from home, the meal plan leaves these days out.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var viewSection: some View {
        Section {
            Toggle("Skip weekends", isOn: $store.skipWeekends)
            #if os(macOS)
            Toggle("Always show weekdays", isOn: $alwaysWeekdays)
            #else
            Toggle("Always show weekdays in the year view", isOn: $alwaysWeekdays)
            #endif
        } header: {
            Text("Calendar view")
        } footer: {
            Text("Saved on this device. Weekends are left out when filling, pasting or toggling ranges.")
        }
    }

    private func legacySection(_ legacy: String) -> some View {
        Section {
            if let url = app.client?.url("/api/v1/families/\(legacy)/calendar.ics") {
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            Button("Remove", systemImage: "trash", role: .destructive) { rotating = "legacy" }
        } header: {
            Text("Old calendar link")
        } footer: {
            Text("The feed address of this family in family-planner. Its event ids live on, so subscriptions moved over keep their events.")
        }
    }
}

/// The calendar feed: what it includes, the URL to subscribe to, a new address.
struct CalendarFeedSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    let store: CalendarStore
    @Binding var rotating: String?
    @State private var excluded: Set<String> = []
    @State private var gapsChoice: Bool?
    @State private var notes = true
    @State private var events = false
    @State private var birthdays = false

    var body: some View {
        Section {
            ForEach(store.types) { type in
                Toggle(isOn: Binding(get: { !excluded.contains(type.id) }, set: { on in
                    if on { excluded.remove(type.id) } else { excluded.insert(type.id) }
                })) {
                    HStack(spacing: 8) {
                        CalendarSwatch(type: type, size: 12)
                        Text(type.name)
                    }
                }
            }
            Toggle("“⚠ Not covered” warnings", isOn: Binding(get: { gaps }, set: { gapsChoice = $0 }))
            Toggle("Icons & notes", isOn: $notes)
            Toggle("Booked appointments (with time)", isOn: $events)
                .help("Timed events such as booked doctor’s appointments; they name the doctor and the practice")
            Toggle("Birthdays", isOn: $birthdays)
        } header: {
            Text("Calendar subscription")
        } footer: {
            Text("A read-only calendar feed. Apple Calendar checks it for changes regularly. The only link that works without signing in: it opens the calendar feed, nothing else.")
        }
        if let feed = feedURL {
            Section {
                Text(feed.absoluteString)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(4)
                Button("Subscribe on this device", systemImage: "calendar.badge.plus") {
                    if let webcal = Self.webcal(feed) { openURL(webcal) }
                }
                Button("Copy", systemImage: "doc.on.doc") {
                    CalendarPasteboard.copy(feed.absoluteString)
                    store.showToast(String(localized: "Copied"))
                }
                ShareLink(item: feed) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                if !store.typesReadOnly {
                    Button("New feed address", systemImage: "arrow.triangle.2.circlepath") { rotating = "feed" }
                }
                DisclosureGroup("How to add it to iCloud") {
                    Text("iPhone / iPad: tap “Subscribe on this device” (or Settings → Apps → Calendar → Calendar Accounts → Add Account → Other → Add Subscribed Calendar, and paste the URL).")
                    Text("Mac: Calendar → File → New Calendar Subscription…, paste the URL, set Location to iCloud so it syncs to all your devices, and pick an auto-refresh interval.")
                    Text("A subscription stored in iCloud appears on all your Apple devices and on iCloud.com.")
                }
                .font(.footnote)
            } header: {
                Text("Subscription URL")
            }
        }
    }

    /// Gap warnings are on by default when the year has a type that needs cover.
    private var gaps: Bool { gapsChoice ?? store.types.contains { $0.role == .needsCover } }

    private var feedURL: URL? {
        guard let feedID = store.family?.feedId, let client = app.client else { return nil }
        return client.url("/api/v1/families/\(feedID)/calendar.ics", query: Self.query(
            types: store.types, excluded: excluded, gaps: gaps, notes: notes, events: events, birthdays: birthdays,
            language: Locale.current.language.languageCode?.identifier
        ))
    }

    /// The feed's options as query parameters (the web's FeedCard).
    static func query(types: [CalendarEntryType], excluded: Set<String>, gaps: Bool, notes: Bool, events: Bool,
                      birthdays: Bool, language: String?) -> [String: String?] {
        var q: [String: String?] = [:]
        let included = types.filter { !excluded.contains($0.id) }
        if included.count != types.count { q["types"] = included.map(\.id).joined(separator: ",") }
        if gaps { q["gaps"] = "1" }
        if notes { q["notes"] = "1" }
        if events { q["events"] = "1" }
        if birthdays { q["birthdays"] = "1" }
        if language == "de" { q["lang"] = "de" }
        return q
    }

    /// The feed as webcal:// (subscribes in the Calendar app).
    static func webcal(_ url: URL) -> URL? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = "webcal"
        return c.url
    }
}

/// Edits one type: name, color, role, away; deletes it. A page pushed from the list of types,
/// with Cancel and Done instead of the back button.
struct CalendarTypeEditor: View {
    let store: CalendarStore
    let type: CalendarEntryType
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = ""
    @State private var role = CalendarRole.none
    @State private var away = false
    @State private var confirmDelete = false
    /// The fields hold the type's values (only once: the color picker's sheet would reset them).
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
            } header: {
                Text("Name")
            } footer: {
                if name.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Give it a name.").foregroundStyle(.red)
                }
            }
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(CalendarMath.palette, id: \.self) { hex in
                        Button {
                            color = hex
                        } label: {
                            Circle()
                                .fill(Color(calendarHex: hex))
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if color.lowercased() == hex {
                                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(hex)
                    }
                }
                .padding(.vertical, 4)
                ColorPicker("Other color", selection: Binding(
                    get: { Color(calendarHex: color) },
                    set: { color = $0.calendarHex() }
                ), supportsOpacity: false)
            } header: {
                Text("Color")
            }
            Section {
                Picker("Role", selection: $role) {
                    ForEach(CalendarRole.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Away", isOn: $away)
            } footer: {
                Text(role.help + "\n" + String(localized: "Away: the whole family is away from home on these days, the meal plan plans no meals for them."))
            }
            Section {
                Button("Delete type", role: .destructive) { confirmDelete = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(type.name)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                CancelButton(hasChanges: hasChanges)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .confirmationDialog("Delete “\(type.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                perform {
                    try await store.deleteType(type.id)
                    dismiss()
                }
            }
        } message: {
            let used = store.daysWith(type.id)
            if used > 0 {
                Text(CalendarText.usedOn(used, year: store.year))
            }
        }
        .discardGuard(hasChanges: hasChanges)
        .errorBanner()
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = type.name
            color = type.color
            role = type.role
            away = type.isAway
        }
    }

    private var hasChanges: Bool {
        loaded && (name.trimmingCharacters(in: .whitespaces) != type.name || color.lowercased() != type.color.lowercased()
            || role != type.role || away != type.isAway)
    }

    private func save() {
        var patch = CalendarTypePatch()
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed != type.name { patch.name = trimmed }
        if color.lowercased() != type.color.lowercased() { patch.color = color.lowercased() }
        if role != type.role { patch.role = role }
        if away != type.isAway { patch.away = away }
        dismiss()
        guard patch.name != nil || patch.color != nil || patch.role != nil || patch.away != nil else { return }
        perform { try await store.updateType(type.id, patch) }
    }
}
