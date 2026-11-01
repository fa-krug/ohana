import CoreGraphics
import SwiftUI

/// A scanned letter on its way: cropped (picked pages), its text read on the device, the
/// suggested file name and tags (the heuristic first, then Apple's on-device model; a field the
/// user edited stays theirs), and what the user chooses in `LetterReviewSheet`.
@Observable
final class LetterReview: Identifiable {
    let id = UUID()
    /// The pages' images, cropped once that's done.
    private(set) var images: [CGImage]
    let needsCrop: Bool
    /// The "Suggest dates and tasks" switch shows (the shell's flow, with the assistant).
    let offersAssistant: Bool
    let filing: ScanFiling
    let today: Day

    enum Reading: Equatable {
        case reading
        case read
        case failed(String)
    }

    private(set) var reading = Reading.reading
    /// The pages with their lines once read (without lines when reading failed).
    private(set) var pages: [ScanPage]
    private(set) var text = ""
    /// Apple's model is working on a better name and tags.
    private(set) var suggesting = false
    var askAssistant = true
    private var heuristic = LetterSuggestion()

    init(images: [CGImage], needsCrop: Bool = false, offersAssistant: Bool,
         settings: ScanFilingSettings = ScanFilingSettings(), today: Day = .today) {
        self.images = images
        self.needsCrop = needsCrop
        self.offersAssistant = offersAssistant
        filing = ScanFiling(kind: .letter, settings: settings)
        self.today = today
        pages = images.map { ScanPage(image: $0, lines: []) }
    }

    /// Crops and reads the pages, then suggests the name and tags (`names`: the family's).
    func start(names: @escaping @MainActor () async -> [String]) {
        Task { await run(names: names) }
    }

    func run(names: @MainActor () async -> [String]) async {
        if needsCrop {
            images = await ScanCrop.cropped(images)
            pages = images.map { ScanPage(image: $0, lines: []) }
        }
        do {
            pages = try await ScanReader.read(images, maxPages: LetterScan.maxPages, languageCorrection: true)
            text = AssistantLetter.text(pages)
            reading = text.isEmpty ? .failed(LetterScanError.noText.localizedDescription) : .read
        } catch {
            reading = .failed(error.localizedDescription)
        }
        let names = await names()
        heuristic = LetterHeuristic.suggest(text, names: names)
        apply(heuristic)
        guard !text.isEmpty, LetterModel.isAvailable else { return }
        suggesting = true
        defer { suggesting = false }
        if let suggestion = await LetterModel.suggest(text, names: names) { apply(suggestion) }
    }

    /// Fills what the user hasn't edited (what the model left out is the heuristic's).
    func apply(_ suggestion: LetterSuggestion) {
        var suggestion = suggestion
        if suggestion.date == nil { suggestion.date = heuristic.date }
        if suggestion.title == nil { suggestion.title = heuristic.title }
        if suggestion.tags.isEmpty { suggestion.tags = heuristic.tags }
        filing.suggest(name: suggestion.fileName(today: today), tags: suggestion.tags)
    }

    var isBusy: Bool { reading == .reading || filing.saving }

    var readFailed: Bool {
        if case .failed = reading { true } else { false }
    }

    var outcome: LetterScanOutcome {
        LetterScanOutcome(text: text.isEmpty ? nil : text, askAssistant: offersAssistant && askAssistant && !text.isEmpty)
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
/// from the shell whether the assistant should suggest what to add.
struct LetterReviewSheet: View {
    @Bindable var review: LetterReview
    let onDone: (LetterScanOutcome) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ScanPagesSection(images: review.images, status: status)
                ScanFilingSection(filing: review.filing, suggesting: review.suggesting)
                if review.offersAssistant, !review.readFailed {
                    Section {
                        Toggle("Suggest dates and tasks", isOn: $review.askAssistant)
                    } footer: {
                        Text("The assistant gets the letter’s text and suggests events, tasks and deadlines to add.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Scanned Letter")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton(hasChanges: true)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if review.filing.saving {
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

    private func done() {
        guard !review.isBusy else { return }
        review.filing.saveThen({ review.pages }) {
            onDone(review.outcome)
            dismiss()
        }
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
