import SwiftUI

/// What the finance page offers for bringing transactions in: without linked accounts the CSV
/// import; while the list shows a linked account, its sync; else both, as a menu.
enum FinanceIntake: Equatable {
    case importCSV
    case sync(FinanceAccount)
    case choice(linked: [FinanceAccount])

    static func of(_ accounts: [FinanceAccount], shownAccount: String) -> FinanceIntake {
        let linked = accounts.filter { $0.bank != nil }
        if linked.isEmpty { return .importCSV }
        if let shown = linked.first(where: { $0.id == shownAccount }) { return .sync(shown) }
        return .choice(linked: linked)
    }
}

extension FinanceStore {
    var intake: FinanceIntake { .of(accounts, shownAccount: filter.account) }
}

extension FinanceBankSync {
    /// What a sync under way does, for the sheet's progress line.
    func progressText(bank: String) -> String {
        let connecting = String(localized: "Connecting to \(bank)…")
        guard status != .waiting, step != nil else { return connecting }
        switch stage {
        case .login: return connecting
        case .tan: return String(localized: "Checking the confirmation…")
        case .fetch: return String(localized: "Loading transactions…")
        case .importing: return String(localized: "Importing…")
        case nil: return String(localized: "Syncing…")
        }
    }
}

/// Syncs a linked account with its bank: starts the sync on the server, polls it about once a
/// second, and shows what the bank asks for (approve the login in its app, or type a photoTAN /
/// SMS TAN). When done it reports the new transactions and, as after a CSV import, can sort
/// them into categories. Cancel stops the sync on the server too. `full` imports the bank's whole
/// history: the account's transactions it already has are taken over, not added again; it first
/// says so and starts only with Import All.
struct FinanceBankSyncSheet: View {
    @Bindable var store: FinanceStore
    let account: FinanceAccount
    var full = false
    @Environment(\.dismiss) private var dismiss
    @Environment(FamilyContext.self) private var family

    /// How often a running sync is asked again.
    static let pollInterval: Duration = .seconds(1)

    @State private var sync: FinanceBankSync?
    /// Starting or asking failed (the server refused, or couldn't be reached).
    @State private var problem: String?
    /// Grows with Try Again: the sync starts over.
    @State private var attempt = 0
    @State private var tan = ""
    @State private var sending = false
    @State private var categorize = true
    /// A full import waits for Import All.
    @State private var confirmed = false

    private var started: Bool { !full || confirmed }

    private var bank: String { account.bank?.providerName ?? "" }
    private var running: Bool { started && problem == nil && (sync?.isRunning ?? true) }
    private var canSort: Bool { family.isEnabled(.assistant) && !store.categories.isEmpty }

    var body: some View {
        NavigationStack {
            Form { content }
                .formStyle(.grouped)
                .readableWidth()
                .navigationTitle(full ? String(localized: "Import All Transactions") : account.label)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbar }
                .task(id: attempt) {
                    guard started else { return }
                    await run()
                }
        }
        .errorBanner()
        // Swiping it away would leave the sync waiting on the server: Cancel stops it.
        .interactiveDismissDisabled(running)
        .presentationDetents([.medium, .large])
        .financeSheetFrame(minWidth: 420, minHeight: 440)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !started {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Import All") {
                    confirmed = true
                    attempt += 1
                }
                .keyboardShortcut(.defaultAction)
            }
        } else if running {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    Task {
                        await store.cancelSync(account.id)
                        dismiss()
                    }
                }
            }
        } else {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { finish() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        if !started {
            intro
        } else if let problem {
            failed(problem)
        } else if let sync, sync.status == .failed {
            failed(sync.error ?? String(localized: "The sync failed."))
        } else if let sync, sync.status == .done {
            done(sync.result)
        } else if let sync, sync.status == .tan, let challenge = sync.tan {
            confirm(challenge)
        } else {
            Section {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text(sync?.progressText(bank: bank) ?? String(localized: "Connecting to \(bank)…"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
        }
    }

    /// What a full import does, before it starts.
    @ViewBuilder
    private var intro: some View {
        Section {
            VStack(spacing: 14) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 48))
                    .foregroundStyle(ModuleTint.finance)
                    .accessibilityHidden(true)
                Text("Load every transaction \(bank) still has")
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
        Section {
            Label("Transactions already here with the same day and amount are kept and linked to the bank.",
                  systemImage: "link")
            Label("Only the ones missing are added.", systemImage: "plus.circle")
        }
    }

    @ViewBuilder
    private func confirm(_ challenge: FinanceBankSync.Challenge) -> some View {
        switch challenge.type {
        case .push:
            Section {
                VStack(spacing: 14) {
                    Image(systemName: "iphone")
                        .font(.system(size: 48))
                        .foregroundStyle(ModuleTint.finance)
                        .accessibilityHidden(true)
                    Text("Confirm the login in the \(bank) app")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    if let hint = challenge.hint, !hint.isEmpty {
                        Text(verbatim: hint).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    ProgressView()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        case .photo:
            Section {
                if let data = challenge.imageData, let image = PlatformImage(data: data) {
                    photoTan(image)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                Text("Scan the graphic with the \(bank) app and enter the TAN it shows.")
                    .foregroundStyle(.secondary)
            }
            tanSection
        case .sms:
            Section {
                if let hint = challenge.hint, !hint.isEmpty {
                    Label("Enter the TAN sent to \(hint).", systemImage: "message")
                } else {
                    Label("Enter the TAN from the text message.", systemImage: "message")
                }
            }
            tanSection
        case .other:
            if let hint = challenge.hint, !hint.isEmpty {
                Section { Text(verbatim: hint) }
            }
            tanSection
        }
    }

    /// The graphic, large enough for the bank's app to scan from the screen.
    private func photoTan(_ image: PlatformImage) -> some View {
        #if canImport(UIKit)
        let picture = Image(uiImage: image)
        #else
        let picture = Image(nsImage: image)
        #endif
        return picture
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .frame(maxWidth: 280, maxHeight: 280)
            .accessibilityLabel(Text("photoTAN graphic"))
    }

    private var tanSection: some View {
        Section {
            HStack {
                TextField("TAN", text: $tan)
                    .monospacedDigit()
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    #endif
                    .onSubmit { send() }
                Button("Send") { send() }
                    .buttonStyle(.borderedProminent)
                    .tint(ModuleTint.finance)
                    .disabled(sending || tan.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    @ViewBuilder
    private func done(_ result: FinanceBankSync.Result?) -> some View {
        let result = result ?? FinanceBankSync.Result(added: 0, duplicates: 0, transfers: 0, splits: 0, ids: [])
        Section {
            Label(FinanceText.inflected("^[\(result.added) new transaction](inflect: true)"), systemImage: "checkmark.circle.fill")
                .font(.headline)
            if let adopted = result.adopted, adopted > 0 {
                Label(FinanceText.inflected("^[\(adopted) transaction](inflect: true) already there – kept and linked to the bank"),
                      systemImage: "link.circle")
                    .foregroundStyle(.secondary)
            }
            if let opening = result.openingCents {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Opening balance set to \(store.money(opening.to))")
                        Text("Was \(store.money(opening.from))").font(.caption)
                    }
                } icon: {
                    Image(systemName: "banknote")
                }
                .foregroundStyle(.secondary)
            }
            if result.duplicates > 0 {
                Label("\(result.duplicates) already imported – skipped", systemImage: "arrow.uturn.left.circle")
                    .foregroundStyle(.secondary)
            }
            if result.transfers > 0 || result.splits > 0 {
                Label(FinanceStore.combinedText(transfers: result.transfers, splits: result.splits), systemImage: "link")
                    .foregroundStyle(.secondary)
            }
        }
        if let unmatched = result.unmatched, unmatched > 0 {
            Section {
                Label(FinanceText.inflected("^[\(unmatched) transaction](inflect: true) the bank doesn’t list"),
                      systemImage: "questionmark.circle")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("They were left as they are. They may be duplicates from a CSV import: filter the account’s list by “Not from the bank” to see them.")
                    if result.openingCents != nil {
                        Text("Once they’re deleted, the balance matches the bank’s.")
                    }
                }
            }
        }
        // As after a CSV import; sorting goes through the assistant's routes: not without it.
        if canSort && !result.ids.isEmpty {
            Section {
                Toggle(store.aiConfigured
                       ? String(localized: "Sort the new transactions into categories (like similar ones, the rest with AI)")
                       : String(localized: "Sort the new transactions into categories like similar earlier ones"),
                       isOn: $categorize)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Button("Try again", systemImage: "arrow.clockwise") { attempt += 1 }
        }
    }

    // MARK: Work

    /// Starts the sync (the server answers the one under way, if any), then asks again while it
    /// runs. Ends when the sheet goes away (the task is cancelled).
    private func run() async {
        problem = nil
        sync = nil
        tan = ""
        do {
            sync = try await store.startSync(account.id, full: full)
            while sync?.isRunning == true {
                try await Task.sleep(for: Self.pollInterval)
                do {
                    sync = try await store.syncStatus(account.id)
                } catch where APIError.isTemporary(error) && !Task.isCancelled {
                    continue // a moment without the server: ask again
                }
            }
            if let sync, sync.status == .done, let result = sync.result { await store.synced(result) }
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            problem = error.localizedDescription
        }
    }

    private func send() {
        let tan = tan.trimmingCharacters(in: .whitespaces)
        guard !tan.isEmpty, !sending else { return }
        sending = true
        Task {
            defer { sending = false }
            do {
                let answer = try await store.sendTan(account.id, tan)
                // A late poll may have seen the end already.
                if sync?.isRunning != false { sync = answer }
                self.tan = ""
            } catch {
                ErrorBanner.shared.show(error)
            }
        }
    }

    /// Closes; the new transactions are sorted afterwards, like after a CSV import.
    private func finish() {
        if categorize, canSort, sync?.status == .done, let ids = sync?.result?.ids, !ids.isEmpty {
            // Runs on after the sheet closed; its toast reports.
            Task { await store.categorize(ids: ids) }
        }
        dismiss()
    }
}
