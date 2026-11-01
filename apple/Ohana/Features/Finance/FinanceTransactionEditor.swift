import SwiftUI

/// What the editor sheet shows: a new transaction, one read from a receipt, or one of the list.
enum FinanceEditTarget: Identifiable {
    case new
    case scanned(ScannedReceipt)
    case existing(FinanceTransaction)

    var id: String {
        switch self {
        case .new: "new"
        case .scanned: "scan"
        case let .existing(t): t.id
        }
    }
}

/// A scanned receipt: what was read from it, its pages, and saving them as a PDF (off at first).
struct ScannedReceipt {
    let scan: ReceiptScan
    let pages: [ScanPage]
    let filing: ScanFiling

    init(scan: ReceiptScan, pages: [ScanPage], filing: ScanFiling = ScanFiling(kind: .receipt)) {
        self.scan = scan
        self.pages = pages
        self.filing = filing
    }

    /// The PDF's name: "YYYY-MM-DD Shop 12,34 EUR" from what the transaction says.
    static func fileName(day: Day, payee: String, amountCents: Int?, currency: String,
                         locale: Locale = .autoupdatingCurrent) -> String {
        var parts = [day.description]
        let shop = payee.trimmingCharacters(in: .whitespacesAndNewlines)
        if !shop.isEmpty { parts.append(shop) }
        if let amountCents, amountCents != 0 {
            parts.append("\(FinanceMoney.input(amountCents, locale: locale)) \(currency)")
        }
        return parts.joined(separator: " ")
    }

    /// The PDF's tags: "Receipt" and the category, if one is chosen.
    static func tags(category: String?) -> [String] {
        [String(localized: "Receipt", comment: "A tag of a scanned receipt's PDF")] + [category].compactMap { $0 }
    }
}

/// The editor's fields as typed: compared with how they started to tell unsaved changes.
struct FinanceTransactionDraft: Equatable {
    var income = false
    var amount = ""
    var date = Date()
    var payee = ""
    var description = ""
    var categoryId: String?
    var accountId: String?
    var note = ""

    init() {}

    init(_ t: FinanceTransaction) {
        income = t.amountCents > 0
        amount = FinanceMoney.input(t.amountCents)
        date = t.day?.date ?? Date()
        payee = t.payee
        description = t.description
        categoryId = t.categoryId
        accountId = t.accountId
        note = t.note
    }

    /// The amount in cents, signed by the kind; nil unless it is a number other than 0.
    var cents: Int? {
        guard let cents = FinanceMoney.parse(amount), cents != 0 else { return nil }
        return income ? abs(cents) : -abs(cents)
    }

    /// Typed, but not an amount (an empty field just keeps Save off).
    var amountInvalid: Bool {
        !amount.trimmingCharacters(in: .whitespaces).isEmpty && cents == nil
    }

    var fields: FinanceOp.Fields? {
        guard let cents else { return nil }
        return FinanceOp.Fields(
            date: Day(date).description,
            amountCents: cents,
            payee: payee.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            categoryId: categoryId,
            accountId: accountId,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// The same day counts as the same date (the picker keeps the time of day it was given).
    static func == (a: Self, b: Self) -> Bool {
        a.income == b.income && a.amount == b.amount && Day(a.date) == Day(b.date) && a.payee == b.payee
            && a.description == b.description && a.categoryId == b.categoryId && a.accountId == b.accountId
            && a.note == b.note
    }
}

/// Adds a transaction, or edits one (transaction-dialog.tsx); viewers see it read-only.
struct FinanceTransactionEditor: View {
    @Bindable var store: FinanceStore
    let target: FinanceEditTarget
    @Environment(\.dismiss) private var dismiss

    @State private var draft = FinanceTransactionDraft()
    @State private var original = FinanceTransactionDraft()
    @State private var filled = false
    @State private var busy = false
    @State private var confirmDelete = false
    @FocusState private var amountFocused: Bool

    private var existing: FinanceTransaction? {
        if case let .existing(t) = target { t } else { nil }
    }

    private var scanned: ScannedReceipt? {
        if case let .scanned(scanned) = target { scanned } else { nil }
    }

    private var scan: ReceiptScan? { scanned?.scan }

    private var hasChanges: Bool { store.canEdit && draft != original }

    var body: some View {
        NavigationStack {
            Form {
                if store.canEdit { editForm } else { readOnly }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? String(localized: "New transaction") : store.canEdit ? String(localized: "Edit transaction") : String(localized: "Transaction"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar }
            .confirmationDialog("Delete this transaction?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let existing else { return }
                    Task {
                        await store.delete([existing.id])
                        dismiss()
                    }
                }
            }
        }
        .errorBanner()
        .discardGuard(hasChanges: hasChanges)
        .presentationDetents([.large])
        .financeSheetFrame(minWidth: 420, minHeight: 520)
        .onAppear(perform: fill)
        .onChange(of: draft, initial: true) { suggestFiling() }
    }

    /// The receipt PDF's name and tags follow the fields until the user edits them.
    private func suggestFiling() {
        guard let scanned else { return }
        scanned.filing.suggest(
            name: ScannedReceipt.fileName(day: Day(draft.date), payee: draft.payee, amountCents: draft.cents,
                                          currency: store.currency),
            tags: ScannedReceipt.tags(category: store.category(draft.categoryId)?.name))
    }

    /// The receipt's PDF first when it's to be saved (a folder asked for if there's none; an
    /// error keeps the sheet open), then the transaction.
    private func saveTapped() {
        guard let scanned, scanned.filing.savesPDF else {
            Task { await save() }
            return
        }
        scanned.filing.saveThen({ scanned.pages }) { Task { await save() } }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if store.canEdit {
            ToolbarItem(placement: .cancellationAction) { CancelButton(hasChanges: hasChanges) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: saveTapped)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || draft.fields == nil || scanned?.filing.saving == true)
            }
        } else {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private var editForm: some View {
        if let scan { scanned(scan) }
        Section {
            Picker("Kind", selection: $draft.income) {
                Text("Expense").tag(false)
                Text("Income").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: draft.income) {
                // A category of the other kind doesn't fit any more.
                if let c = store.category(draft.categoryId), !FinanceCategoryTree.fits(c, income: draft.income) { draft.categoryId = nil }
            }
            LabeledContent {
                TextField("Amount", text: $draft.amount, prompt: Text(FinanceMoney.placeholder))
                    .multilineTextAlignment(.trailing)
                    .font(.title3.monospacedDigit())
                    .focused($amountFocused)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            } label: {
                Text("Amount (\(store.currency))")
            }
            DatePicker("Date", selection: $draft.date, displayedComponents: .date)
        } footer: {
            if draft.amountInvalid {
                Text("Enter an amount, e.g. \(FinanceMoney.input(1250))").foregroundStyle(.red)
            }
        }
        Section {
            TextField(draft.income ? String(localized: "From") : String(localized: "Payee"), text: $draft.payee)
            TextField("Description", text: $draft.description)
        }
        Section {
            NavigationLink {
                FinanceCategoryPickerList(tree: store.tree, selection: $draft.categoryId,
                                          fits: { FinanceCategoryTree.fits($0, income: draft.income) })
            } label: {
                LabeledContent("Category") { FinanceCategoryLabel(category: store.category(draft.categoryId)) }
            }
            if !store.accounts.isEmpty || draft.accountId != nil {
                Picker("Account", selection: $draft.accountId) {
                    Text("Without account").tag(String?.none)
                    ForEach(store.accounts) { Text($0.label).tag(Optional($0.id)) }
                }
            }
        } footer: {
            if scan != nil && draft.categoryId == nil && store.sortsOnSave {
                Text("Left without one, it is sorted into a category when you save.")
            }
        }
        Section("Note") {
            TextField("Note", text: $draft.note, axis: .vertical)
                .lineLimit(2...6)
                .labelsHidden()
        }
        if let scanned { ScanFilingSection(filing: scanned.filing) }
        if let existing { links(existing) }
        if existing != nil {
            Section {
                Button("Delete transaction", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .disabled(busy)
            }
        }
    }

    /// What the receipt gave: the fields are filled in, the user checks them.
    private func scanned(_ scan: ReceiptScan) -> some View {
        Section {
            Label(scan.amountCents == nil && scan.date == nil && scan.shop == nil
                  ? String(localized: "Nothing could be read from the receipt")
                  : String(localized: "Filled in from the receipt"),
                  systemImage: "doc.text.viewfinder")
        } footer: {
            if scan.amountCents == nil {
                Text("No total found: type in the amount.")
            } else {
                Text("Read on this device. Check the amount and the date before saving.")
            }
        }
    }

    @ViewBuilder
    private var readOnly: some View {
        if let t = existing {
            Section {
                LabeledContent("Amount") { FinanceAmountText(store: store, transaction: t) }
                LabeledContent("Date", value: t.day?.formatted(.dateTime.day().month(.wide).year()) ?? t.date)
                if !t.payee.isEmpty { LabeledContent(t.amountCents > 0 ? String(localized: "From") : String(localized: "Payee"), value: t.payee) }
                if !t.description.isEmpty { LabeledContent("Description", value: t.description) }
            }
            Section {
                LabeledContent("Category") { FinanceCategoryLabel(category: store.category(t.categoryId)) }
                LabeledContent("Account", value: store.account(t.accountId)?.label ?? String(localized: "Without account"))
            }
            if !t.note.isEmpty { Section("Note") { Text(t.note) } }
            links(t)
        }
    }

    @ViewBuilder
    private func links(_ t: FinanceTransaction) -> some View {
        if let (icon, text) = FinanceLinkInfo(store.list?.transactions ?? [t]).detail(t, store: store) {
            Section {
                Label(text, systemImage: icon).foregroundStyle(.secondary)
                if t.imported { Label("Imported from a bank statement", systemImage: "square.and.arrow.down").foregroundStyle(.secondary) }
            }
        } else if t.imported {
            Section { Label("Imported from a bank statement", systemImage: "square.and.arrow.down").foregroundStyle(.secondary) }
        }
    }

    private func fill() {
        guard !filled else { return }
        filled = true
        if let t = existing {
            draft = FinanceTransactionDraft(t)
        } else {
            // A new one goes to the account the list shows, else the first one.
            let shown = store.filter.account
            draft.accountId = !shown.isEmpty && shown != "none" ? shown : store.accounts.first?.id
            amountFocused = scan?.amountCents == nil
        }
        // The receipt's fields count as changes: cancelling asks first.
        original = draft
        if let scan {
            if let cents = scan.amountCents { draft.amount = FinanceMoney.input(cents) }
            if let day = scan.date { draft.date = day.date }
            if let shop = scan.shop { draft.payee = shop }
        }
    }

    private func save() async {
        guard let fields = draft.fields else { return }
        busy = true
        let op = existing.map { FinanceOp.update($0.id, fields) } ?? FinanceOp.add(fields)
        let added = await store.change([op], message: existing == nil ? String(localized: "Transaction added") : String(localized: "Saved"))
        busy = false
        guard let added else { return }
        // A receipt left without a category: sorted after the sheet closes (the AI can take a while).
        if scan != nil, fields.categoryId == nil, store.sortsOnSave, let id = added.first {
            Task { await store.categorizeReceipt(id) }
        }
        dismiss()
    }
}
