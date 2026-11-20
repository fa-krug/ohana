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
    @State private var scan: HealthScanReader?
    /// The read under way, cancelled when its sheet is dismissed (`scan` is nil by then).
    @State private var reading: HealthScanReader?

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
            // Reading starts at once, while the camera or the file picker goes.
            let reader = HealthScanReader(member: member, images: images, needsCrop: needsCrop)
            reader.start(family, store: store)
            reading?.cancel()
            reading = reader
            Task {
                // After the camera or the file picker has gone: one presentation at a time.
                try? await Task.sleep(for: .milliseconds(350))
                scan = reader
            }
        }
        .sheet(item: $scan, onDismiss: stopReading, content: scanSheet)
        .alert("Mark earlier ones as done?", isPresented: $markingPast) {
            Button("Mark as Done") {
                perform { try await store.markPastDone(family, member: memberID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every check-up and vaccination whose time has passed is recorded as done, without a date.")
                + Text(verbatim: " ") + Text("You can change each one later.")
        }
    }

    private func scanSheet(_ reader: HealthScanReader) -> some View {
        HealthScanSheet(reader: reader).environment(store).errorBanner()
    }

    private func stopReading() {
        reading?.cancel()
        reading = nil
    }

    private func canScan(_ member: HealthMember) -> Bool {
        member.canEdit && member.birthday != nil && store.overview?.scan == true && store.canChange
    }

    @ViewBuilder private func content(_ member: HealthMember) -> some View {
        List {
            header(member)
            if member.birthday == nil {
                Section {
                    Text("Check-ups and vaccinations are worked out from the birthday.")
                    Button("Add Birthday", systemImage: "birthday.cake") { family.open(.settings(.members)) }
                }
            }
            if member.canEdit, !member.past.isEmpty {
                pastCard(member)
            }
            itemSections(member)
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

    private func header(_ member: HealthMember) -> some View {
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
    }

    /// The windows that closed without a record: all done at once, or the booklet read.
    private func pastCard(_ member: HealthMember) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("\(member.past.count) earlier check-ups and vaccinations aren’t recorded.")
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(ModuleTint.health)
                        .accessibilityHidden(true)
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

    /// Due now, then the check-ups and the vaccinations in the schedule's order.
    @ViewBuilder private func itemSections(_ member: HealthMember) -> some View {
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
                    perform { try await store.doneToday(family, member: member.id, code: item.code) }
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

    private var faded: Bool { [.upcoming, .past, .skipped, .optional].contains(item.status) }

    private var lineStyle: AnyShapeStyle {
        item.status == .due ? AnyShapeStyle(Color.orange) : AnyShapeStyle(HierarchicalShapeStyle.secondary)
    }

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
                    .foregroundStyle(lineStyle)
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
