import CoreGraphics
import SwiftUI

/// One member's check-ups and vaccinations (pushed from the health page, or a notification's
/// link): what's due, then the check-ups and the vaccinations in the schedule's order. The
/// windows that closed without a record are "not recorded", never overdue, and one button marks
/// them all done; the booklet's pages can be read with the camera instead (`HealthScanSheet`).
struct HealthMemberView: View {
    @Environment(FamilyContext.self) private var family
    @Environment(HealthStore.self) private var store
    let memberID: String
    @State private var editing: HealthEditTarget?
    @State private var markingPast = false
    @State private var scanning = false
    @State private var scan: HealthScanReview?

    private var member: HealthMember? { store.member(memberID) }

    var body: some View {
        Group {
            if let member {
                content(member)
            } else if store.overview == nil {
                PageLoadingView()
            } else {
                ContentUnavailableView("Not found", systemImage: "person.crop.circle.badge.questionmark")
            }
        }
        .ohanaBackground(ModuleTint.health)
        .navigationTitle(member?.name ?? String(localized: "Health"))
        .toolbar {
            if let member, canScan(member) {
                ToolbarItem(placement: .primaryAction) {
                    Button("Scan Booklet", systemImage: "doc.viewfinder") { scanning = true }
                        .help("Read the vaccination booklet or U-Heft with the camera")
                }
            }
        }
        .sheet(item: $editing) { target in
            HealthRecordSheet(target: target).environment(store)
        }
        .paperScanner(isPresented: $scanning, maxPages: HealthScanPages.maxPages) { images, needsCrop in
            guard let member else { return }
            Task {
                // After the camera or the file picker has gone: one presentation at a time.
                try? await Task.sleep(for: .milliseconds(350))
                scan = HealthScanReview(member: member, images: images, needsCrop: needsCrop)
            }
        }
        .sheet(item: $scan) { review in
            HealthScanSheet(review: review).environment(store).errorBanner()
        }
        .alert("Mark earlier ones as done?", isPresented: $markingPast) {
            Button("Mark as Done") {
                perform { try await store.markPastDone(family, member: memberID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every check-up and vaccination whose time has passed is recorded as done, without a date. You can change each one later.")
        }
    }

    private func canScan(_ member: HealthMember) -> Bool {
        member.canEdit && member.birthday != nil && store.overview?.scan == true && store.canChange
    }

    @ViewBuilder private func content(_ member: HealthMember) -> some View {
        List {
            Section {
                HStack(spacing: 14) {
                    MemberIcon(name: member.name, color: member.color, photo: member.photo, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.name).font(.title3.weight(.semibold))
                        if let birthday = member.birthday, let age = member.age() {
                            Text(verbatim: HealthText.date(birthday) + " · " + String(localized: "\(age) years"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }

            if member.birthday == nil {
                Section {
                    Text("Check-ups and vaccinations are worked out from the birthday.")
                    Button("Add Birthday", systemImage: "birthday.cake") { family.open(.settings(.members)) }
                }
            }

            if member.canEdit, !member.past.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label {
                            Text("\(member.past.count) earlier check-ups and vaccinations aren’t recorded.")
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(ModuleTint.health)
                        }
                        Text("Were they all done? Then mark them at once, or read the booklet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("All Done") { markingPast = true }
                                .buttonStyle(.glassProminent)
                                .disabled(!store.canChange)
                            if canScan(member) {
                                Button("Scan Booklet") { scanning = true }
                                    .buttonStyle(.glass)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if !member.due.isEmpty {
                Section("Due now") {
                    ForEach(member.due) { item in row(member, item) }
                }
            }

            let checkups = member.checkups.filter { $0.status != .due }
            if !checkups.isEmpty {
                Section("Check-ups") {
                    ForEach(checkups) { item in row(member, item) }
                }
            }

            let vaccinations = member.vaccinations.filter { $0.status != .due }
            if !vaccinations.isEmpty {
                Section {
                    ForEach(vaccinations) { item in row(member, item) }
                } header: {
                    Text("Vaccinations")
                } footer: {
                    HealthFooter(asOf: store.overview?.asOf ?? "")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .readableWidth()
        .scrollContentBackground(.hidden)
        .refreshable { await store.load(family) }
    }

    private func row(_ member: HealthMember, _ item: HealthItem) -> some View {
        let edit = { editing = HealthEditTarget(member: member, item: item) }
        return Button(action: edit) {
            HealthItemRow(item: item)
        }
        .buttonStyle(.plain)
        .disabled(!member.canEdit)
        .swipeActions(edge: .leading) {
            if member.canEdit, store.canChange, !item.status.isRecorded || item.repeats {
                Button("Done Today", systemImage: "checkmark") {
                    perform { try await store.record(family, member: member.id, [HealthRecordInput(code: item.code, day: .today)]) }
                }
                .tint(.green)
            }
        }
        .contextMenu { HealthItemMenu(member: member, item: item, edit: edit) }
    }
}

/// An item: its status, title, what it is and its date line.
struct HealthItemRow: View {
    let item: HealthItem

    private var faded: Bool { item.status == .upcoming || item.status == .past || item.status == .skipped }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: HealthText.systemImage(item.status))
                .foregroundStyle(HealthText.tint(item.status))
                .frame(width: 22)
                .accessibilityLabel(Text(HealthText.label(item.status)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).fontWeight(item.status == .due ? .semibold : .regular)
                    if item.notAlwaysPaid {
                        Text("Not always paid")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                    }
                }
                let what = item.vaccines.isEmpty ? item.detail : item.vaccines.joined(separator: ", ")
                if !what.isEmpty, what != item.title {
                    Text(what)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(HealthText.line(item))
                    .font(.caption)
                    .foregroundStyle(item.status == .due ? AnyShapeStyle(Color.orange) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                if let note = item.latest?.note, !note.isEmpty, item.status.isRecorded {
                    Text(note).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .opacity(faded ? 0.75 : 1)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Recording

/// Records an item (done or skipped, on a day or without one, with a note), or changes its
/// record. A repeating one (tetanus, flu) gets a new record each time and lists the earlier ones.
struct HealthRecordSheet: View {
    @Environment(FamilyContext.self) private var family
    @Environment(HealthStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: HealthEditTarget
    @State private var date = Date()
    @State private var unknownDate = false
    @State private var skipped = false
    @State private var note = ""
    @State private var saving = false
    @State private var removing = false

    private var item: HealthItem { target.item }
    private var member: HealthMember { target.member }
    /// The record this changes: a once-only item's (a repeating one always gets a new one).
    private var existing: HealthRecord? { item.repeats ? nil : item.latest }

    init(target: HealthEditTarget) {
        self.target = target
        let record = target.item.repeats ? nil : target.item.latest
        _date = State(initialValue: record?.day?.date ?? Date())
        _unknownDate = State(initialValue: record != nil && record?.day == nil)
        _skipped = State(initialValue: record?.status == .skipped)
        _note = State(initialValue: record?.note ?? "")
    }

    private var range: ClosedRange<Date> {
        (member.birthday?.date ?? .distantPast)...max(Date(), member.birthday?.date ?? .distantPast)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.vaccines.isEmpty ? item.detail : item.vaccines.joined(separator: ", "))
                        Text(HealthText.line(item)).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Picker("Status", selection: $skipped) {
                        Text("Completed").tag(false)
                        Text("Skipped").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Date unknown", isOn: $unknownDate)
                    if !unknownDate {
                        DatePicker("Date", selection: $date, in: range, displayedComponents: .date)
                    }
                    TextField("Note (e.g. the vaccine or the doctor)", text: $note, axis: .vertical)
                }

                if item.repeats, !item.records.isEmpty {
                    Section("Earlier") {
                        ForEach(item.records) { record in
                            HStack {
                                Text(record.day.map { HealthText.date($0) } ?? String(localized: "Date unknown"))
                                if !record.note.isEmpty {
                                    Text(record.note).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if record.status == .skipped { Text("Skipped").foregroundStyle(.secondary) }
                            }
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) { delete(record) }
                            }
                            .contextMenu {
                                Button("Delete", systemImage: "trash", role: .destructive) { delete(record) }
                            }
                        }
                    }
                }

                if existing != nil {
                    Section {
                        Button("Remove Record", role: .destructive) { removing = true }
                    }
                }

                if item.status == .due, HealthBooking.canBook(family) {
                    Section {
                        Button("Find an Appointment", systemImage: "stethoscope") {
                            dismiss()
                            HealthBooking.book(family, member: member, item: item)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text(verbatim: "\(item.title) · \(member.name)"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton(hasChanges: false)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(saving || !store.canChange)
                }
            }
            .alert("Remove this record?", isPresented: $removing) {
                Button("Remove", role: .destructive) {
                    guard let existing else { return }
                    delete(existing)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }

    private func save() {
        saving = true
        let day: Day? = unknownDate ? nil : Day(date)
        let status: HealthStatus = skipped ? .skipped : .done
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        perform {
            defer { saving = false }
            if let existing {
                try await store.update(family, record: existing.id, day: day, status: status, note: text)
            } else {
                try await store.record(family, member: member.id,
                                       [HealthRecordInput(code: item.code, day: day, status: status.rawValue, note: text)])
            }
            dismiss()
        }
    }

    private func delete(_ record: HealthRecord) {
        perform { try await store.delete(family, record: record.id) }
    }
}

// MARK: Scanning a booklet

/// Pages of a booklet to read for a member.
struct HealthScanReview: Identifiable {
    let id = UUID()
    let member: HealthMember
    let images: [CGImage]
    let needsCrop: Bool
}

/// Reads a booklet's pages with the family's AI (only the pictures go to the server, which asks
/// the family's AI), then lists what it found to tick: those already recorded unticked. Save
/// records the ticked ones.
struct HealthScanSheet: View {
    @Environment(FamilyContext.self) private var family
    @Environment(HealthStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let review: HealthScanReview
    @State private var phase: Phase = .reading
    @State private var ticked: Set<String> = []
    @State private var saving = false

    enum Phase {
        case reading
        case found([HealthScanSuggestion])
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .reading:
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Reading the booklet…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .failed(message):
                    ContentUnavailableView {
                        Label("Couldn’t read the booklet", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await read() } }
                            .buttonStyle(.glassProminent)
                    }
                case let .found(items) where items.isEmpty:
                    ContentUnavailableView("Nothing found",
                                           systemImage: "doc.text.magnifyingglass",
                                           description: Text("No check-ups or vaccinations could be read on these pages."))
                case let .found(items):
                    list(items)
                }
            }
            .navigationTitle(Text(verbatim: review.member.name))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton(hasChanges: !ticked.isEmpty)
                }
                if case .found = phase {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }
                            .disabled(ticked.isEmpty || saving)
                    }
                }
            }
        }
        .task { await read() }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
    }

    private func list(_ items: [HealthScanSuggestion]) -> some View {
        Form {
            Section {
                ForEach(items) { item in
                    Toggle(isOn: Binding(get: { ticked.contains(item.id) },
                                         set: { if $0 { ticked.insert(item.id) } else { ticked.remove(item.id) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            Text(item.day.map { HealthText.date($0) } ?? String(localized: "Date not readable"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if item.known {
                                Text("Already recorded").font(.caption).foregroundStyle(.secondary)
                            } else if !item.note.isEmpty {
                                Text(item.note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: {
                Text("Read by the family’s AI. Check each one against the booklet before you save.")
            }
        }
        .formStyle(.grouped)
    }

    private func read() async {
        phase = .reading
        do {
            let pages = await HealthScanPages.encode(review.images, crop: review.needsCrop)
            guard !pages.isEmpty else { throw LetterScanError.unreadable }
            let answer = try await store.scan(family, member: review.member.id, pages: pages)
            guard answer.ai else {
                phase = .failed(String(localized: "Set up the assistant’s AI in the settings to read booklets."))
                return
            }
            ticked = Set(answer.items.filter { !$0.known }.map(\.id))
            phase = .found(answer.items)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func save() {
        guard case let .found(items) = phase else { return }
        saving = true
        let records = items.filter { ticked.contains($0.id) }
            .map { HealthRecordInput(code: $0.code, day: $0.day, note: $0.note) }
        perform {
            defer { saving = false }
            try await store.record(family, member: review.member.id, records)
            dismiss()
        }
    }
}
