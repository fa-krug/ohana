import SwiftUI

/// Settings → Calendar (the web's calendar tab): the entry types of a year (name, member, role,
/// away, order; add, delete, copy from another year), the view settings of this device, the
/// imported public and school holidays and this device's sync with Apple Calendar.
struct CalendarSettingsView: View {
    @Environment(FamilyContext.self) private var family
    @State private var store: CalendarStore?

    var body: some View {
        Group {
            if let store {
                CalendarSettingsContent(store: store)
            } else {
                PageLoadingView()
            }
        }
        .navigationTitle("Calendar")
        .onAppear {
            if store == nil { store = CalendarStore(api: family.api, readOnly: !family.canEdit) }
        }
    }
}

/// Settings → Calendar → Year view's weekdays: over `ohana.calendar.showWeekdays` and
/// `CalendarWeekdayAlignment`.
private enum CalendarWeekdays: Hashable {
    case automatic, always, columns
}

private struct CalendarSettingsContent: View {
    @Environment(FamilyContext.self) private var family
    @Bindable var store: CalendarStore
    @State private var editing: CalendarEntryType?
    @State private var deleting: CalendarEntryType?
    /// The type a dragged one hovers over (Mac).
    @State private var dropTarget: String?
    @State private var appleSync = AppleCalendarSyncPrompts()
    @State private var holidays = CalendarHolidaysModel()
    @AppStorage("ohana.calendar.showWeekdays") private var alwaysWeekdays = false
    @AppStorage(CalendarWeekdayAlignment.key) private var alignWeekdays = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        LoadStateView(state: loadState, retry: { await store.load() }) { _ in
            Form {
                typesSection
                if !compact { viewSection }
                CalendarHolidaysSection(model: holidays)
                AppleCalendarSyncSection(prompts: appleSync)
            }
            .formStyle(.grouped)
            .readableWidth()
            .appleCalendarSyncPrompts(appleSync)
            .calendarHolidays(holidays)
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
                    .listRowBackground(dropTarget == type.id ? Color.accentColor.opacity(0.15) : nil)
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
                let years = copyYears
                if !years.isEmpty {
                    Menu {
                        ForEach(years, id: \.self) { y in
                            Button(String(y)) {
                                perform { try await store.copyTypes(from: y) }
                            }
                        }
                    } label: {
                        Label("Copy from…", systemImage: "doc.on.doc")
                    }
                }
            }
        } header: {
            Text("Entry types")
        } footer: {
            if store.isViewer {
                Text("Only editors of the family can change entry types.")
            } else {
                Text("These types belong to \(String(store.year)) – every year has its own. The switch decides whether a type’s days go to Apple Calendar.")
            }
        }
    }

    /// The years to copy types from, the closest first (`copySource`, the one an empty year
    /// starts with, before the others).
    private var copyYears: [Int] {
        let year = store.year
        let others = (store.typeYears ?? []).filter { $0 != year }
            .sorted { (abs($0 - year), -$0) < (abs($1 - year), -$1) }
        guard let first = store.copySource else { return others }
        return [first] + others.filter { $0 != first }
    }

    private func typeRow(_ type: CalendarEntryType, index: Int, stats: CalendarTypeStats) -> some View {
        // Not a NavigationLink: the row holds the Apple Calendar switch, and on the Mac it is
        // dragged to reorder (a grouped Form there ignores `onMove`).
        HStack(spacing: 12) {
            typeLabel(type, stats: stats)
                .contentShape(.rect)
                .onTapGesture { if !store.typesReadOnly { editing = type } }
                .accessibilityAddTraits(store.typesReadOnly ? [] : .isButton)
                .accessibilityAction { if !store.typesReadOnly { editing = type } }
            if type.appleSync != nil {
                appleSyncToggle(type)
            }
            if !store.typesReadOnly {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .contentShape(.rect)
                    .onTapGesture { editing = type }
                    .accessibilityHidden(true)
            }
        }
        #if os(macOS)
        .modifier(CalendarTypeReorder(store: store, type: type, targeted: $dropTarget))
        #endif
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

    /// Whether the type's days go to Apple Calendar (on the devices that sync the family's
    /// calendar there); saved at once, for the whole family.
    private func appleSyncToggle(_ type: CalendarEntryType) -> some View {
        Toggle("Sync with Apple Calendar", isOn: Binding(get: { type.syncsToApple }, set: { on in
            perform { try await store.updateType(type.id, CalendarTypePatch(appleSync: on)) }
        }))
        .labelsHidden()
        .toggleStyle(.switch)
        #if os(macOS)
        .controlSize(.small)
        #endif
        .disabled(store.typesReadOnly)
        .help("Sync with Apple Calendar")
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

    /// The year grid's weekday letters: by the zoom, always, or in columns (aligned, the header
    /// names them). One choice over the two stored settings. The phone never shows the year grid.
    private var viewSection: some View {
        Section {
            Picker("Weekdays", selection: weekdays) {
                Text("Automatic").tag(CalendarWeekdays.automatic)
                Text("Always").tag(CalendarWeekdays.always)
                Text("In columns").tag(CalendarWeekdays.columns)
            }
        } header: {
            Text("Calendar view")
        } footer: {
            Text("Saved on this device.")
        }
    }

    private var weekdays: Binding<CalendarWeekdays> {
        Binding(get: {
            alignWeekdays ? .columns : alwaysWeekdays ? .always : .automatic
        }, set: { choice in
            alignWeekdays = choice == .columns
            if choice != .columns { alwaysWeekdays = choice == .always }
        })
    }

    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

}

#if os(macOS)
/// Drags a type onto another one's place in the list (editors): it takes that place, the ones
/// between move up or down. `targeted` is the type it hovers over.
private struct CalendarTypeReorder: ViewModifier {
    let store: CalendarStore
    let type: CalendarEntryType
    @Binding var targeted: String?

    func body(content: Content) -> some View {
        if store.typesReadOnly {
            content
        } else {
            content
                .draggable(store.typeDragItem(type)) {
                    HStack(spacing: 8) {
                        CalendarTypeBadge(type: type, member: store.member(of: type), size: 18)
                        Text(type.name)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: .capsule)
                }
                .dropDestination(for: CalendarTypeDragItem.self) { items, _ in
                    targeted = nil
                    guard let item = items.first else { return false }
                    perform { try await store.dropType(item, onto: type.id) }
                    return true
                } isTargeted: { over in
                    if over { targeted = type.id } else if targeted == type.id { targeted = nil }
                }
        }
    }
}
#endif

/// Edits one type: name, member (whose color it takes; a nobody's type a color of its own), role,
/// icon, away; deletes it. A page pushed
/// from the list of types, with Cancel and Done instead of the back button.
struct CalendarTypeEditor: View {
    let store: CalendarStore
    let type: CalendarEntryType
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var memberId: String?
    /// A nobody's type's own color (a `MemberColor` key); nil: gray.
    @State private var colorKey: String?
    @State private var role = CalendarRole.none
    /// The icon picked on this page; until one is, the type keeps its own (or its role's default,
    /// following the role chosen here).
    @State private var pickedIcon: String?
    /// Whether an icon was tapped here: until then a renamed type that shows its role's icon takes
    /// the new name's best suggestion.
    @State private var iconTouched = false
    @State private var away = false
    @State private var confirmDelete = false
    /// The fields hold the type's values (only once: coming back to the page would reset them).
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .onChange(of: name) { _, value in suggestIcon(for: value) }
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
            } header: {
                Text("Member")
            }
            if memberId == nil {
                Section {
                    FamilyColorChoice(selection: colorKey, used: [:]) { color in
                        colorKey = colorKey == color.rawValue ? nil : color.rawValue
                    }
                } header: {
                    Text("Color")
                } footer: {
                    Text("Without a color the type is gray. Tap the chosen one again to remove it.")
                }
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
                                   selection: Binding(get: { icon }, set: { pickedIcon = $0; iconTouched = true }),
                                   suggested: CalendarSymbol.suggestions(for: name))
            } header: {
                Text("Icon")
            }
            Section {
                Button("Delete type", role: .destructive) { confirmDelete = true }
            }
        }
        .formStyle(.grouped)
        .readableWidth()
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
            colorKey = type.colorKey
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
                    FamilyAvatar(name: member.name, tint: MemberColor.color(member.color), photo: member.photo, size: 28)
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

    /// The type's color as it stands (the Icon section's preview): for another member theirs (a
    /// nobody's type the color chosen here), until the server works out the shade.
    private var previewHex: String {
        if memberId == type.memberId && (memberId != nil || colorKey == type.colorKey) { return type.color }
        if memberId == nil { return MemberColor(key: colorKey)?.hex ?? "#8e8e93" }
        return MemberColor(key: store.member(memberId)?.color)?.hex ?? "#8e8e93"
    }

    /// The own color to save: only a nobody's type keeps one.
    private var keptColorKey: String? { memberId == nil ? colorKey : nil }

    /// The icon the type would have without one picked here: its own, or the chosen role's
    /// default while it shows its role's.
    private var keptIcon: String {
        type.icon == type.role.defaultIcon ? role.defaultIcon : type.icon
    }

    private var icon: String { pickedIcon ?? keptIcon }

    private func suggestIcon(for value: String) {
        guard loaded, !iconTouched, type.icon == type.role.defaultIcon, value != type.name else { return }
        pickedIcon = CalendarSymbol.suggestions(for: value).first
    }

    private var hasChanges: Bool {
        loaded && (name.trimmingCharacters(in: .whitespaces) != type.name || memberId != type.memberId
            || keptColorKey != type.colorKey || role != type.role || icon != keptIcon || away != type.isAway)
    }

    private func save() {
        var patch = CalendarTypePatch()
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed != type.name { patch.name = trimmed }
        if memberId != type.memberId { patch.memberId = .some(memberId) }
        if keptColorKey != type.colorKey && memberId == nil { patch.colorKey = .some(keptColorKey) }
        if role != type.role { patch.role = role }
        if let pickedIcon, pickedIcon != keptIcon { patch.icon = .some(pickedIcon) }
        if away != type.isAway { patch.away = away }
        dismiss()
        guard !patch.isEmpty else { return }
        perform { try await store.updateType(type.id, patch) }
    }
}
