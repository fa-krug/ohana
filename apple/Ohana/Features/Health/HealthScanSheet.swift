import CoreGraphics
import SwiftUI

/// Reading a booklet's pages for a member: started as soon as the pages are scanned, kept by the
/// member's page while its sheet shows, cancelled only when the sheet is dismissed. Not the
/// sheet's `.task`: SwiftUI cancels that whenever the sheet's content goes away, if only for a
/// moment, and the read then failed with a CancellationError.
@MainActor @Observable
final class HealthScanReader: Identifiable {
    enum Phase {
        case reading
        case found([HealthScanSuggestion])
        case failed(String)
    }

    let id = UUID()
    let member: HealthMember
    private let images: [CGImage]
    private let needsCrop: Bool
    private(set) var phase: Phase = .reading
    var ticked: Set<String> = []
    @ObservationIgnored private var task: Task<Void, Never>?

    init(member: HealthMember, images: [CGImage], needsCrop: Bool) {
        self.member = member
        self.images = images
        self.needsCrop = needsCrop
    }

    /// Reads the pages (again); a read under way goes on.
    func start(_ family: FamilyContext, store: HealthStore) {
        guard task == nil else { return }
        phase = .reading
        task = Task { await read(family, store: store) }
    }

    /// The sheet was dismissed: the answer isn't wanted any more.
    func cancel() {
        task?.cancel()
        task = nil
    }

    private func read(_ family: FamilyContext, store: HealthStore) async {
        defer { if !Task.isCancelled { task = nil } }
        do {
            let pages = await HealthScanPages.encode(images, crop: needsCrop)
            try Task.checkCancellation()
            guard !pages.isEmpty else { throw LetterScanError.unreadable }
            let answer = try await store.scan(family, member: member.id, pages: pages)
            try Task.checkCancellation()
            guard answer.readable else {
                phase = .failed(String(localized: "Set up the assistant’s AI in the settings to read booklets."))
                return
            }
            ticked = Set(answer.items.filter { !$0.known }.map(\.id))
            phase = .found(answer.items)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error is CancellationError
                ? String(localized: "The connection was interrupted.")
                : error.localizedDescription)
        }
    }
}

/// Reads a booklet's pages with the family's AI (only the pictures go to the server, which asks
/// the family's AI; `HealthScanReader` does the reading), then lists what it found to tick: those
/// already recorded unticked. Save records the ticked ones.
struct HealthScanSheet: View {
    @Environment(FamilyContext.self) private var family
    @Environment(HealthStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let reader: HealthScanReader
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Group {
                switch reader.phase {
                case .reading:
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Reading the booklet…").foregroundStyle(.secondary)
                        Text("This can take a minute or two.")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .failed(message):
                    ContentUnavailableView {
                        Label("Couldn’t read the booklet", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { reader.start(family, store: store) }
                            .buttonStyle(.glassProminent)
                    }
                case let .found(items) where items.isEmpty:
                    ContentUnavailableView("Nothing found",
                                           systemImage: "doc.text.magnifyingglass",
                                           description: Text("No check-ups or vaccinations found on these pages."))
                case let .found(items):
                    list(items)
                }
            }
            .navigationTitle(Text(verbatim: reader.member.name))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton(hasChanges: !reader.ticked.isEmpty)
                }
                if case .found = reader.phase {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }
                            .disabled(reader.ticked.isEmpty || saving)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
    }

    private func list(_ items: [HealthScanSuggestion]) -> some View {
        Form {
            Section {
                ForEach(items) { item in
                    Toggle(isOn: tick(item)) {
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

    private func tick(_ item: HealthScanSuggestion) -> Binding<Bool> {
        Binding(get: { reader.ticked.contains(item.id) },
                set: { if $0 { reader.ticked.insert(item.id) } else { reader.ticked.remove(item.id) } })
    }

    private func save() {
        guard case let .found(items) = reader.phase else { return }
        saving = true
        let records = items.filter { reader.ticked.contains($0.id) }
            .map { HealthRecordInput(code: $0.code, day: $0.day, note: $0.note) }
        perform {
            defer { saving = false }
            try await store.record(family, member: reader.member.id, records)
            dismiss()
        }
    }
}
