import SwiftUI
import UniformTypeIdentifiers

/// A bank statement picked or dropped on the finance page: its name and bytes.
nonisolated struct FinanceImportFile: Identifiable, Transferable, Sendable {
    let id = UUID()
    var name: String
    var data: Data

    /// What the file picker offers and a drop takes.
    static let contentTypes: [UTType] = [.commaSeparatedText, .tabSeparatedText, .plainText, .text]

    init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    /// Reads a file the picker handed out (security-scoped) or a dropped copy.
    init(url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        self.init(name: url.lastPathComponent, data: try Data(contentsOf: url))
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .commaSeparatedText) { try FinanceImportFile(url: $0.file) }
        FileRepresentation(importedContentType: .tabSeparatedText) { try FinanceImportFile(url: $0.file) }
        FileRepresentation(importedContentType: .plainText) { try FinanceImportFile(url: $0.file) }
    }
}

/// Where an import starts once its file is read.
enum FinanceImportStep: Equatable {
    case file, map, review

    /// The bank's saved mapping, when one was saved for the file's header row.
    static func savedMapping(for guess: FinanceCSVMapping, in saved: [FinanceCSVMapping]) -> FinanceCSVMapping? {
        guard !guess.signature.isEmpty else { return nil }
        return saved.first { $0.signature == guess.signature }
    }

    /// Straight to the review when a saved mapping reads rows from the file; else the mapping
    /// has to be checked first.
    static func first(saved: FinanceCSVMapping?, readableRows: Int) -> FinanceImportStep {
        saved != nil && readableRows > 0 ? .review : .map
    }
}

/// Imports a bank statement (import-dialog.tsx): check how the file's columns map (with a
/// preview), then see what is new and what was imported before, and import the new rows into
/// an account. Mappings are remembered per bank (by the file's header), with the account and
/// whether transfers and split bookings are combined; a file of a known bank skips straight to
/// the review.
struct FinanceImportSheet: View {
    @Bindable var store: FinanceStore
    let file: FinanceImportFile
    @Environment(\.dismiss) private var dismiss
    @Environment(FamilyContext.self) private var family

    private struct Parsed {
        var header: [String] = []
        var width = 0
        var ok: [FinanceParsedRow] = []
        var errors = 0
    }

    @State private var step = FinanceImportStep.file
    @State private var loaded = false
    @State private var data: Data?
    @State private var fileName = ""
    @State private var mapping: FinanceCSVMapping?
    /// The mapping as the file brought it (saved or guessed): changes to it are work to keep.
    @State private var original: FinanceCSVMapping?
    @State private var usedSaved = false
    @State private var parsed = Parsed()
    @State private var accountId: String?
    @State private var auto = true
    @State private var remember = true
    @State private var categorize = true
    @State private var duplicates: Set<Int> = []
    @State private var transfers = 0
    @State private var splits = 0
    @State private var picking = false
    @State private var busy = false
    @State private var problem: String?

    private var hasChanges: Bool { mapping != original }

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .file: fileStep
                case .map: mapStep
                case .review: reviewStep
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Import bank statement")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
            .fileImporter(isPresented: $picking, allowedContentTypes: FinanceImportFile.contentTypes) { result in
                do {
                    let file = try FinanceImportFile(url: result.get())
                    Task { await load(file) }
                } catch {
                    problem = error.localizedDescription
                }
            }
            .onChange(of: mapping) { reparse() }
            .task {
                guard !loaded else { return }
                loaded = true
                await load(file)
            }
        }
        .errorBanner()
        .discardGuard(hasChanges: hasChanges)
        .presentationDetents([.large])
        .financeSheetFrame(minWidth: 560, minHeight: 620)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { CancelButton(hasChanges: hasChanges) }
        ToolbarItem(placement: .confirmationAction) {
            switch step {
            case .file:
                EmptyView()
            case .map:
                Button("Next") { Task { await check() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || parsed.ok.isEmpty)
            case .review:
                Button("Import \(parsed.ok.count - duplicates.count)") { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || parsed.ok.count == duplicates.count)
            }
        }
    }

    // MARK: Steps

    /// Only when the file couldn't be read: another one.
    @ViewBuilder
    private var fileStep: some View {
        if loaded && !busy {
            Section {
                Text("Export the transactions from your online banking as a CSV file and pick it here. Rows imported before are skipped.")
                    .foregroundStyle(.secondary)
                Button {
                    picking = true
                } label: {
                    Label("Choose CSV file", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(ModuleTint.finance)
            }
        } else {
            Section { ProgressView().frame(maxWidth: .infinity) }
        }
    }

    @ViewBuilder
    private var mapStep: some View {
        if let mapping {
            let binding = Binding { mapping } set: { self.mapping = $0 }
            Section {
                LabeledContent("File", value: fileName)
                Picker("Character set", selection: binding.encoding) {
                    ForEach(FinanceCSVEncoding.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Delimiter", selection: binding.delimiter) {
                    ForEach(FinanceCSV.delimiters, id: \.0) { Text(verbatim: $0.1).tag($0.0) }
                }
                Stepper(value: binding.skipRows, in: 0...50) {
                    LabeledContent("Rows before the table", value: "\(mapping.skipRows)")
                }
                Toggle("First row holds the column names", isOn: binding.hasHeader)
            }
            Section("Columns") {
                columnPicker("Date", selection: Binding { Optional(mapping.date) } set: { self.mapping?.date = $0 ?? 0 })
                Picker("Date format", selection: binding.dateFormat) {
                    ForEach(FinanceDateFormat.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
                }
                Picker("Amounts", selection: Binding { mapping.amount == nil } set: { split in
                    if split {
                        self.mapping?.debit = mapping.debit ?? 0
                        self.mapping?.credit = mapping.credit ?? 0
                        self.mapping?.amount = nil
                    } else {
                        self.mapping?.amount = mapping.amount ?? mapping.debit ?? 0
                        self.mapping?.debit = nil
                        self.mapping?.credit = nil
                    }
                }) {
                    Text("One column (+/−)").tag(false)
                    Text("Debit and credit").tag(true)
                }
                Picker("Number format", selection: binding.decimal) {
                    Text(verbatim: "1.234,56").tag(",")
                    Text(verbatim: "1,234.56").tag(".")
                }
                if mapping.amount == nil {
                    columnPicker("Debit (out)", selection: binding.debit)
                    columnPicker("Credit (in)", selection: binding.credit)
                } else {
                    columnPicker("Amount", selection: Binding { mapping.amount } set: { self.mapping?.amount = $0 ?? 0 })
                }
                columnPicker("Payee", selection: binding.payee, optional: true)
                columnPicker("Description", selection: Binding { mapping.description.first } set: {
                    self.mapping?.description = $0.map { [$0] } ?? []
                }, optional: true)
            }
            Section {
                preview(Array(parsed.ok.prefix(6)))
            } header: {
                Text("First rows")
            } footer: {
                Text(verbatim: FinanceText.inflected("^[\(parsed.ok.count) row](inflect: true) read")
                     + (parsed.errors > 0 ? String(localized: ", \(parsed.errors) couldn’t be read") : ""))
                    .foregroundStyle(parsed.ok.isEmpty ? .red : .secondary)
            }
        }
    }

    @ViewBuilder
    private var reviewStep: some View {
        Section {
            LabeledContent("File", value: fileName)
            Button("Change mapping", systemImage: "tablecells") { step = .map }
                .disabled(busy)
        } footer: {
            if usedSaved && !hasChanges {
                Text("Read with the format saved for this bank.")
            }
        }
        Section {
            Label("^[\(parsed.ok.count - duplicates.count) new transaction](inflect: true)", systemImage: "plus.circle")
                .font(.headline)
            if !duplicates.isEmpty {
                Label("\(duplicates.count) already imported – skipped", systemImage: "arrow.uturn.left.circle")
                    .foregroundStyle(.secondary)
            }
            if parsed.errors > 0 {
                Label("^[\(parsed.errors) row](inflect: true) without a date or amount – skipped", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
            if transfers > 0 {
                Label("^[\(transfers) transfer](inflect: true) will be combined", systemImage: "link").foregroundStyle(.secondary)
            }
            if splits > 0 {
                Label("^[\(splits) split booking](inflect: true) will be combined", systemImage: "rectangle.split.3x1")
                    .foregroundStyle(.secondary)
            }
        }
        Section {
            if !store.accounts.isEmpty {
                Picker("Account", selection: Binding { accountId } set: { id in
                    accountId = id
                    Task { await check() } // duplicates are per account
                }) {
                    Text("Without account").tag(String?.none)
                    ForEach(store.accounts) { Text($0.label).tag(Optional($0.id)) }
                }
                .disabled(busy)
                Toggle("Combine transfers and split bookings automatically", isOn: Binding { auto } set: { on in
                    auto = on
                    Task { await check() }
                })
                .disabled(busy)
            }
            if mapping?.signature.isEmpty == false {
                Toggle("Remember this format for the next statement", isOn: $remember)
            }
            // Sorting goes through the assistant's routes: not without it.
            if !store.categories.isEmpty, family.isEnabled(.assistant) {
                Toggle(store.aiConfigured
                       ? String(localized: "Sort the new transactions into categories (like similar ones, the rest with AI)")
                       : String(localized: "Sort the new transactions into categories like similar earlier ones"),
                       isOn: $categorize)
                if !store.aiConfigured {
                    // Settings → AI (closes the import without importing).
                    Button("Set up the assistant to sort the rest too", systemImage: "gearshape.2") {
                        dismiss()
                        family.open(.settings(.assistant))
                    }
                    .font(.callout)
                }
            }
        }
        Section("Rows") {
            preview(Array(parsed.ok.prefix(50)), duplicates: duplicates)
        }
    }

    private func columnPicker(_ title: LocalizedStringKey, selection: Binding<Int?>, optional: Bool = false) -> some View {
        let count = max(parsed.width, parsed.header.count)
        return Picker(title, selection: selection) {
            if optional { Text(verbatim: "—").tag(Int?.none) }
            ForEach(0..<count, id: \.self) { i in
                Text(parsed.header.indices.contains(i) && !parsed.header[i].isEmpty
                     ? parsed.header[i] : String(localized: "Column \(i + 1)"))
                    .tag(Optional(i))
            }
        }
    }

    @ViewBuilder
    private func preview(_ rows: [FinanceParsedRow], duplicates: Set<Int> = []) -> some View {
        if rows.isEmpty {
            Text("No readable rows yet: check the columns.").foregroundStyle(.secondary)
        }
        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
            let dupe = duplicates.contains(i)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.payee.isEmpty ? row.description : row.payee).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(Day(row.date)?.formatted(.dateTime.day().month(.abbreviated).year()) ?? row.date)
                        if !row.payee.isEmpty && !row.description.isEmpty { Text(row.description).lineLimit(1) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(store.money(row.amountCents, sign: row.amountCents > 0))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(FinanceMoney.color(row.amountCents, muted: dupe))
            }
            .strikethrough(dupe)
            .opacity(dupe ? 0.5 : 1)
            .help(dupe ? Text("Imported before") : Text(verbatim: ""))
            .accessibilityElement(children: .combine)
            .accessibilityValue(dupe ? Text("Imported before") : Text(verbatim: ""))
        }
    }

    // MARK: Work

    /// Reads the file and maps it; a bank seen before goes straight to the review.
    private func load(_ file: FinanceImportFile) async {
        problem = nil
        do {
            let (text, encoding) = try FinanceCSV.decode(file.data)
            let guess = FinanceCSV.guessMapping(text, encoding: encoding)
            let saved = FinanceImportStep.savedMapping(for: guess, in: store.overview?.mappings ?? [])
            data = file.data
            fileName = file.name
            // Its account as last time, else the one the list shows.
            let known = { (id: String?) in id.flatMap { store.account($0)?.id } }
            accountId = known(saved?.accountId) ?? known(store.filter.account)
            auto = saved?.autoTransfers ?? true
            usedSaved = saved != nil
            mapping = saved ?? guess
            original = mapping
            reparse()
            if FinanceImportStep.first(saved: saved, readableRows: parsed.ok.count) == .review {
                await check()
                // The dry run failed (its problem shows): check the mapping by hand.
                if step != .review { step = .map }
            } else {
                step = .map
            }
        } catch {
            problem = error.localizedDescription
            step = .file
        }
    }

    private func reparse() {
        guard let data, let mapping else { return }
        guard let text = try? FinanceCSV.decode(data, encoding: mapping.encoding).text else {
            parsed = Parsed()
            return
        }
        let table = FinanceCSV.table(text, mapping: mapping)
        let result = FinanceCSV.map(table.rows, mapping: mapping)
        parsed = Parsed(header: table.header, width: table.rows.first?.count ?? 0, ok: result.ok, errors: result.errors.count)
    }

    /// A dry run: which rows are there already, and how many transfers and split bookings
    /// would be combined.
    private func check() async {
        guard !parsed.ok.isEmpty else { return }
        busy = true
        problem = nil
        do {
            let res = try await store.checkImport(parsed.ok, accountId: accountId, auto: auto)
            duplicates = Set(res.duplicates)
            transfers = res.transfers ?? 0
            splits = res.splits ?? 0
            step = .review
        } catch {
            problem = error.localizedDescription
        }
        busy = false
    }

    private func run() async {
        busy = true
        do {
            let res = try await store.importRows(parsed.ok, accountId: accountId, auto: auto)
            if remember, var mapping, !mapping.signature.isEmpty {
                mapping.accountId = accountId
                mapping.autoTransfers = auto
                await store.saveMapping(mapping)
            }
            let ids = res.ids
            if categorize && family.isEnabled(.assistant) && !store.categories.isEmpty && !ids.isEmpty {
                // Runs on after the sheet closed; its toast reports.
                Task { await store.categorize(ids: ids) }
            }
            dismiss()
        } catch {
            problem = String(localized: "Import failed: \(error.localizedDescription)")
            busy = false
        }
    }
}
