import SwiftUI

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
            let input = HealthRecordInput(code: item.code, day: day, status: status.rawValue, note: text)
            if let existing {
                try await store.update(family, record: existing.id, input)
            } else {
                try await store.record(family, member: member.id, [input])
            }
            dismiss()
        }
    }

    private func delete(_ record: HealthRecord) {
        perform { try await store.delete(family, record: record.id) }
    }
}
