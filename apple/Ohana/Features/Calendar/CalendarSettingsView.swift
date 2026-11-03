import SwiftUI

/// Settings → Calendar (the web's calendar tab): the entry types of a year (name, member, role,
/// away, order; add, delete, copy from another year), the view settings of this device and this
/// device's sync with Apple Calendar.
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
    @Bindable var store: CalendarStore
    @State private var editing: CalendarEntryType?
    @State private var deleting: CalendarEntryType?
    @State private var appleSync = AppleCalendarSyncPrompts()
    @AppStorage("ohana.calendar.showWeekdays") private var alwaysWeekdays = false

    var body: some View {
        LoadStateView(state: loadState, retry: { await store.load() }) { _ in
            Form {
                typesSection
                rolesSection
                viewSection
                AppleCalendarSyncSection(prompts: appleSync)
            }
            .formStyle(.grouped)
            .appleCalendarSyncPrompts(appleSync)
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
            CalendarTypeBadge(type: type, member: store.member(of: type), size: 22)
            VStack(alignment: .leading, spacing: 2) {
                // The badge reads the name (with the member's).
                Text(type.name).foregroundStyle(.primary).accessibilityHidden(true)
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

}

/// Edits one type: name, member (whose color it takes), role, icon, away; deletes it. A page pushed
/// from the list of types, with Cancel and Done instead of the back button.
struct CalendarTypeEditor: View {
    let store: CalendarStore
    let type: CalendarEntryType
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var memberId: String?
    @State private var role = CalendarRole.none
    /// The icon picked on this page; until one is, the type keeps its own (or its role's default,
    /// following the role chosen here).
    @State private var pickedIcon: String?
    @State private var away = false
    @State private var confirmDelete = false
    /// The fields hold the type's values (only once: coming back to the page would reset them).
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
                memberRow(nil)
                ForEach(store.members) { memberRow($0) }
                LabeledContent("Color") {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(previewColor)
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                }
            } header: {
                Text("Member")
            } footer: {
                Text("The type takes the member’s color: their first type of the year has it, further ones a shade of it.")
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
                LabeledContent("Preview") {
                    CalendarTypeBadge(name: name, color: previewHex, icon: icon, member: store.member(memberId), size: 28)
                }
                CalendarSymbolGrid(symbols: CalendarSymbol.typeIcons,
                                   selection: Binding(get: { icon }, set: { pickedIcon = $0 }))
            } header: {
                Text("Icon")
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
            memberId = type.memberId
            role = type.role
            away = type.isAway
        }
    }

    /// A member to pick (nil: nobody), with a check on the chosen one.
    private func memberRow(_ member: CalendarMember?) -> some View {
        Button {
            memberId = member?.id
        } label: {
            HStack(spacing: 12) {
                if let member {
                    FamilyAvatar(name: member.name, tint: MemberColor.color(member.color), size: 28)
                    Text(member.name).foregroundStyle(.primary)
                } else {
                    Image(systemName: "person.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.gray.opacity(0.18), in: .circle)
                    Text("Nobody").foregroundStyle(.primary)
                }
                Spacer(minLength: 8)
                if memberId == member?.id {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(memberId == member?.id ? .isSelected : [])
    }

    /// The type's color as it stands; for another member theirs, until the server works out the
    /// shade.
    private var previewColor: Color { Color(calendarHex: previewHex) }

    private var previewHex: String {
        if memberId == type.memberId { return type.color }
        return MemberColor(key: store.member(memberId)?.color)?.hex ?? "#8b8d98"
    }

    /// The icon the type would have without one picked here: its own, or the chosen role's
    /// default while it shows its role's.
    private var keptIcon: String {
        type.icon == type.role.defaultIcon ? role.defaultIcon : type.icon
    }

    private var icon: String { pickedIcon ?? keptIcon }

    private var hasChanges: Bool {
        loaded && (name.trimmingCharacters(in: .whitespaces) != type.name || memberId != type.memberId
            || role != type.role || icon != keptIcon || away != type.isAway)
    }

    private func save() {
        var patch = CalendarTypePatch()
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed != type.name { patch.name = trimmed }
        if memberId != type.memberId { patch.memberId = .some(memberId) }
        if role != type.role { patch.role = role }
        if let pickedIcon, pickedIcon != keptIcon { patch.icon = .some(pickedIcon) }
        if away != type.isAway { patch.away = away }
        dismiss()
        guard !patch.isEmpty else { return }
        perform { try await store.updateType(type.id, patch) }
    }
}
