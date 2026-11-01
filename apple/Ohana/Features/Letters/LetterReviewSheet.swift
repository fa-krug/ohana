import CoreGraphics
import SwiftUI

/// A scanned letter on its way: cropped (picked pages), its text read on the device, the
/// suggested file name and tags (the heuristic first, then Apple's on-device model; a field the
/// user edited stays theirs), what the server found in it to add (with a `finder`: the shell's
/// flow) and what the user chooses in `LetterReviewSheet`.
@Observable
final class LetterReview: Identifiable {
    let id = UUID()
    /// The pages' images, cropped once that's done.
    private(set) var images: [CGImage]
    let needsCrop: Bool
    /// Asks the server what's in the letter; nil: no "Found in the letter" (the assistant's
    /// paperclip, which attaches the text instead).
    @ObservationIgnored let finder: (any LetterItemFinding)?
    let filing: ScanFiling
    let today: Day

    enum Reading: Equatable {
        case reading
        case read
        case failed(String)
    }

    /// How looking for events, tasks and deadlines goes.
    enum Finding: Equatable {
        /// Not looked for (no finder, no text, the assistant isn't set up, given up on Done).
        case off
        case looking
        case found
        case failed(String)
    }

    private(set) var reading = Reading.reading
    /// The pages with their lines once read (without lines when reading failed).
    private(set) var pages: [ScanPage]
    private(set) var text = ""
    /// Apple's model is working on a better name and tags.
    private(set) var suggesting = false
    private var heuristic = LetterSuggestion()
    /// The family's names (the editor's "Who it is for"), once loaded.
    private(set) var people: [String] = []

    private(set) var finding = Finding.off
    /// What was found, in the server's order (each ticked, the ones this app can't add left out).
    var found: [LetterFoundItem] = []
    /// Who the letter is from, when the server said.
    private(set) var foundSource: String?
    /// The lookup (tests await it).
    @ObservationIgnored private(set) var findTask: Task<Void, Never>?
    /// Done is adding the ticked items.
    private(set) var adding = false

    init(images: [CGImage], needsCrop: Bool = false, finder: (any LetterItemFinding)? = nil,
         settings: ScanFilingSettings = ScanFilingSettings(), today: Day = .today) {
        self.images = images
        self.needsCrop = needsCrop
        self.finder = finder
        filing = ScanFiling(kind: .letter, settings: settings)
        self.today = today
        pages = images.map { ScanPage(image: $0, lines: []) }
    }

    /// Looks for what to add in the letter (the shell's flow).
    var findsItems: Bool { finder != nil }

    /// Crops and reads the pages, then suggests the name and tags (`names`: the family's) while
    /// the server looks for what to add.
    func start(names: @escaping @MainActor () async -> [String]) {
        Task { await run(names: names) }
    }

    func run(names: @MainActor () async -> [String]) async {
        if needsCrop {
            images = await ScanCrop.cropped(images)
            pages = images.map { ScanPage(image: $0, lines: []) }
        }
        do {
            took(try await ScanReader.read(images, maxPages: LetterScan.maxPages, languageCorrection: true))
        } catch {
            reading = .failed(error.localizedDescription)
        }
        let names = await names()
        people = names
        heuristic = LetterHeuristic.suggest(text, names: names)
        apply(heuristic)
        if !text.isEmpty, LetterModel.isAvailable {
            suggesting = true
            if let suggestion = await LetterModel.suggest(text, names: names) { apply(suggestion) }
            suggesting = false
        }
        await findTask?.value
    }

    /// The pages as read: their text, then (with a finder) the server looks for what's in it.
    func took(_ read: [ScanPage]) {
        pages = read
        text = AssistantLetter.text(read)
        reading = text.isEmpty ? .failed(LetterScanError.noText.localizedDescription) : .read
        guard let finder, !text.isEmpty else { return }
        finding = .looking
        let text = text, today = today
        findTask = Task { [weak self] in
            let result: Result<LetterFindings, any Error>
            do {
                result = .success(try await finder.find(text, today: today))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self?.lookedUp(result)
        }
    }

    private func lookedUp(_ result: Result<LetterFindings, any Error>) {
        guard finding == .looking else { return }
        switch result {
        case let .success(findings):
            guard findings.ai else {
                finding = .off
                return
            }
            foundSource = findings.source
            found = findings.items.filter { $0.kind != .unknown }.map { LetterFoundItem(op: $0) }
            finding = .found
        case let .failure(error) where error is CancellationError:
            finding = .off
        case let .failure(error):
            finding = .failed(error.localizedDescription)
        }
    }

    /// Done while it's still looking: it gives up (nothing found is added).
    func stopFinding() {
        findTask?.cancel()
        if finding == .looking { finding = .off }
    }

    /// Fills what the user hasn't edited (what the model left out is the heuristic's).
    func apply(_ suggestion: LetterSuggestion) {
        var suggestion = suggestion
        if suggestion.date == nil { suggestion.date = heuristic.date }
        if suggestion.title == nil { suggestion.title = heuristic.title }
        if suggestion.tags.isEmpty { suggestion.tags = heuristic.tags }
        filing.suggest(name: suggestion.fileName(today: today), tags: suggestion.tags)
    }

    var isBusy: Bool { reading == .reading || filing.saving || adding }

    var readFailed: Bool {
        if case .failed = reading { true } else { false }
    }

    var outcome: LetterScanOutcome {
        LetterScanOutcome(text: text.isEmpty ? nil : text)
    }

    // MARK: Adding what was found

    /// Done adds something: a ticked item not added yet.
    var hasPending: Bool { finding == .found && found.contains(where: \.pending) }

    /// A ticked item not added yet goes into Reminders.
    var needsReminders: Bool {
        finding == .found && found.contains { $0.pending && $0.op.kind.isReminder }
    }

    func togglePick(_ id: LetterFoundItem.ID) {
        guard let index = found.firstIndex(where: { $0.id == id }), !found[index].added else { return }
        found[index].picked.toggle()
    }

    /// The editor saved `op`: it replaces the item (ticked, without its old error).
    func update(_ id: LetterFoundItem.ID, op: AssistantSuggestionOp) {
        guard let index = found.firstIndex(where: { $0.id == id }), !found[index].added else { return }
        found[index].op = op
        found[index].picked = true
        found[index].error = nil
    }

    /// Adds the ticked items not added yet (`AssistantSuggestionsApply`): the ones that went
    /// through are marked added, the others keep their error for another Done. True when none
    /// failed; `addedEvent` says whether an event went into the calendar.
    func addPicked(events: any AssistantEventCreating, reminders: (any RemindersWriting)?,
                   defaultListID: String?) async -> (ok: Bool, addedEvent: Bool) {
        guard hasPending else { return (true, false) }
        adding = true
        defer { adding = false }
        let items = found
        let picks = Set(items.indices.filter { items[$0].pending })
        let results = await AssistantSuggestionsApply.perform(items.map(\.op), picks: picks, events: events,
                                                              reminders: reminders, defaultListID: defaultListID)
        var ok = true
        var addedEvent = false
        for index in picks.sorted() where index < results.count {
            guard let at = found.firstIndex(where: { $0.id == items[index].id }) else { continue }
            if results[index].ok {
                found[at].added = true
                found[at].error = nil
                if items[index].op.kind == .event { addedEvent = true }
            } else {
                found[at].error = results[index].error ?? String(localized: "It couldn’t be added.")
                ok = false
            }
        }
        return (ok, addedEvent)
    }

    /// The names of the family's members, accounts and not (Settings' household: the server's
    /// answer, or the copy on the device); none when it can't be had.
    static func familyNames(_ api: FamilyAPI) -> @MainActor () async -> [String] {
        {
            let request = FamilySettingsModel.request(api)
            guard let household = (try? await request.fetchOrSaved()) ?? request.saved()?.value else { return [] }
            return household.members.map(\.name).filter { !$0.isEmpty } + household.people.map(\.name)
        }
    }
}

/// After a letter's scan: the pages, saving them as a searchable PDF (name, tags, folder), and
/// from the shell what the server found in it to add (`LetterFoundSection`): Done saves the PDF,
/// then adds the ticked items; if some fail the sheet stays open with their errors and Done tries
/// them again (the PDF isn't saved twice).
struct LetterReviewSheet: View {
    @Bindable var review: LetterReview
    /// Adds the events (the family API); only with a finder.
    var events: (any AssistantEventCreating)?
    /// An event went into the family's calendar.
    var eventsAdded: () -> Void = {}
    let onDone: (LetterScanOutcome) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var reminders = RemindersStore.shared
    /// Done found no access to Reminders.
    @State private var refused = false
    @State private var editing: LetterFoundItem?

    var body: some View {
        NavigationStack {
            Form {
                ScanPagesSection(images: review.images, status: status)
                ScanFilingSection(filing: review.filing, suggesting: review.suggesting)
                if review.findsItems {
                    LetterFoundSection(review: review, noReminders: noReminders, editing: $editing)
                }
            }
            .formStyle(.grouped)
            .scanFolderPicker(review.filing)
            .sheet(item: $editing) { item in
                LetterItemEditor(op: item.op, today: review.today, names: review.people) { op in
                    review.update(item.id, op: op)
                }
            }
            .navigationTitle("Scanned Letter")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton(hasChanges: true)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if review.filing.saving || review.adding {
                        ProgressView()
                    } else {
                        Button("Done", action: done)
                            .buttonStyle(.glassProminent)
                            .disabled(review.isBusy)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .discardGuard(hasChanges: true)
        .task(id: reminders.revision) { reminders.refreshAccess() }
        .onChange(of: review.found.map(\.pending)) { refused = false }
        .onDisappear { review.stopFinding() }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 520, idealHeight: 640)
        #endif
    }

    private var status: ScanPagesSection.Status {
        switch review.reading {
        case .reading: .working(String(localized: "Reading the letter…"))
        case .read: .pages
        case let .failed(message): .failed(message)
        }
    }

    /// Why ticked tasks or deadlines can't be added; nil when they can (or none is ticked).
    private var noReminders: RemindersAccess? {
        guard review.needsReminders else { return nil }
        if reminders.access == .denied || reminders.access == .restricted || reminders.access == .writeOnly {
            return reminders.access
        }
        return refused ? .denied : nil
    }

    private func done() {
        guard !review.isBusy else { return }
        review.stopFinding()
        review.filing.saveThen({ review.pages }) {
            Task { await addThenFinish() }
        }
    }

    /// Adds the ticked items (asking for the access to Reminders first when one goes there),
    /// then closes, unless some failed.
    private func addThenFinish() async {
        if review.hasPending, let events {
            let needsReminders = review.needsReminders
            if needsReminders {
                reminders.refreshAccess()
                if reminders.access == .notDetermined {
                    do {
                        try await reminders.requestAccess()
                    } catch {
                        ErrorBanner.shared.show(error)
                    }
                }
                guard reminders.access.isGranted else {
                    refused = true
                    return
                }
            }
            let (ok, addedEvent) = await review.addPicked(
                events: events, reminders: needsReminders ? reminders : nil,
                defaultListID: needsReminders ? reminders.defaultListID : nil)
            if addedEvent { eventsAdded() }
            guard ok else { return }
        }
        onDone(review.outcome)
        dismiss()
    }
}

/// What the server found in the letter, at the bottom of the review: while it looks a progress
/// line; then each event, task and deadline with a tick (ticked at first: Done adds it) and its
/// text, which opens the editor; "No dates or tasks found." when there's none. Hidden when the
/// family has no assistant; an error shows in the footer (the rest of the sheet still works).
struct LetterFoundSection: View {
    @Bindable var review: LetterReview
    /// Ticked tasks or deadlines can't go into Reminders (the access).
    let noReminders: RemindersAccess?
    /// The item the editor shows (the sheet is the review's).
    @Binding var editing: LetterFoundItem?

    var body: some View {
        switch review.finding {
        case .off:
            EmptyView()
        case .looking:
            Section {
                Label {
                    Text("Looking for dates and tasks…")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .foregroundStyle(.secondary)
            } header: {
                Text("Found in the Letter")
            }
        case let .failed(message):
            Section {
                Text("The letter couldn’t be checked for dates and tasks.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Found in the Letter")
            } footer: {
                Label(message, systemImage: "exclamationmark.triangle.fill")
            }
        case .found:
            Section {
                if review.found.isEmpty {
                    Text("No dates or tasks found.")
                        .foregroundStyle(.secondary)
                }
                ForEach(review.found) { item in
                    LetterFoundRow(item: item, enabled: !review.adding) {
                        review.togglePick(item.id)
                    } edit: {
                        editing = item
                    }
                }
            } header: {
                Text("Found in the Letter")
            } footer: {
                footer
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if !review.found.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if let source = review.foundSource {
                    Text("From \(source)")
                }
                Text("Done adds the ticked ones: events to the family’s calendar, tasks and deadlines to your Reminders.")
                if let access = noReminders {
                    Label(access == .restricted
                          ? "Reminders aren’t allowed on this device."
                          : "Ohana has no access to your reminders.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    if access != .restricted, let url = RemindersStore.settingsURL {
                        Link(destination: url) {
                            Label("Open Settings", systemImage: "gear")
                        }
                    }
                }
            }
        }
    }
}

/// One found item: the tick (an added one shows a green check instead), then what it is, when
/// and a fainter detail (`AssistantSuggestionLine`), its error in orange; tapping the text edits it.
struct LetterFoundRow: View {
    let item: LetterFoundItem
    let enabled: Bool
    let toggle: () -> Void
    let edit: () -> Void

    var body: some View {
        let line = AssistantSuggestionLine.make(item.op)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if item.added {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel(Text("Added"))
            } else {
                Button(action: toggle) {
                    Image(systemName: item.picked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.picked ? Color.accentColor : .secondary)
                        .imageScale(.large)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .accessibilityLabel(Text(verbatim: line.title))
                .accessibilityAddTraits(item.picked ? .isSelected : [])
                .accessibilityHint(Text("Ticks or unticks it"))
            }
            Button(action: edit) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: line.icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: line.title)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let when = line.when {
                            Text(verbatim: when)
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                        if let detail = line.detail, !detail.isEmpty {
                            Text(verbatim: detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        if let error = item.error, !item.added {
                            Text(verbatim: error)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !item.added {
                        Image(systemName: "info.circle")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!enabled || item.added)
            .accessibilityElement(children: .combine)
            .accessibilityHint(item.added ? Text("Added") : Text("Edits it"))
        }
        .opacity(item.picked || item.added ? 1 : 0.6)
        .padding(.vertical, 2)
    }
}

/// The scanned pages as small thumbnails, with how reading them goes below.
struct ScanPagesSection: View {
    let images: [CGImage]
    var status = Status.pages

    enum Status {
        /// The page count.
        case pages
        case working(String)
        case failed(String)
    }

    var body: some View {
        Section {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(images.indices, id: \.self) { index in
                        Image(decorative: images[index], scale: 1)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 120)
                            .clipShape(.rect(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                            .accessibilityLabel(Text("Page \(index + 1)"))
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        } footer: {
            switch status {
            case let .working(text):
                Label { Text(text) } icon: { ProgressView().controlSize(.small) }
            case .pages:
                Text("^[\(images.count) page](inflect: true)")
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
            }
        }
    }
}
