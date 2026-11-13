import CoreGraphics
import Foundation
import PDFKit
import SwiftUI

// The assistant looks at a knowledge document's pages (server: lib/assistant/tools/knowledge-pages.ts,
// view_knowledge_pages). The server never holds the family's files: this device renders the pages
// from the knowledge folder linked here (`AssistantPagesRender`), uploads each one (PUT
// /ai/chats/{id}/pages) and answers (POST …/pages); the chat store does that
// (`AssistantChatStore.sendPages`), at once when the family's *Read with the assistant* is on
// (`auto`), else when the user taps Send on the card (`AssistantPagesCard`).

nonisolated enum AssistantPagesError: LocalizedError, Equatable, Sendable {
    /// No knowledge folder linked on this device.
    case notLinked
    /// The file isn't in the folder any more.
    case notFound
    /// The file couldn't be loaded or opened (iCloud, a locked PDF).
    case unreadable
    /// Not a PDF or an image.
    case unsupported
    /// None of the pages asked for is in the file.
    case noPages

    var errorDescription: String? {
        switch self {
        case .notLinked: String(localized: "The knowledge folder isn’t linked on this device.")
        case .notFound: String(localized: "The file isn’t in the folder any more.")
        case .unreadable: String(localized: "The file couldn’t be loaded.")
        case .unsupported: String(localized: "Only PDFs and images can be sent as pages.")
        case .noPages: String(localized: "The file doesn’t have these pages.")
        }
    }
}

/// Renders pages of a knowledge file as upright JPEGs for the assistant (smaller than the page
/// scans: the model looks at them, it doesn't transcribe them).
nonisolated enum AssistantPagesRender {
    /// The long side of a page, in pixels.
    static let maxSide: CGFloat = 1600
    /// The server takes up to 4 MB per page.
    static let maxBytes = 4_000_000

    /// The pages `pages` (from 1, in that order) of the file at `path` in the folder `root`
    /// (security-scoped meanwhile; iCloud loads a file that isn't on the device). Pages the file
    /// doesn't have are left out.
    @concurrent
    static func render(path: String, pages: [Int], in root: URL) async throws -> [KnowledgeText.PageScan] {
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        guard let file = KnowledgeOriginal.locate(path, in: root) else { throw AssistantPagesError.notFound }
        let ext = (KnowledgePath.parts(path).last.map { ($0 as NSString).pathExtension } ?? file.pathExtension).lowercased()
        guard ext == "pdf" || KnowledgeText.imageExtensions.contains(ext) else { throw AssistantPagesError.unsupported }
        guard let data = KnowledgeText.coordinatedData(file) else { throw AssistantPagesError.unreadable }
        var out: [KnowledgeText.PageScan] = []
        if ext == "pdf" {
            guard let document = PDFDocument(data: data), !document.isLocked else { throw AssistantPagesError.unreadable }
            for number in pages where number >= 1 && number <= document.pageCount {
                guard let page = document.page(at: number - 1), let image = KnowledgeText.render(page),
                      let jpeg = jpeg(image) else { continue }
                out.append(.init(page: number, jpeg: jpeg))
            }
        } else if pages.contains(1) {
            guard let image = KnowledgeOCR.uprightImage(data, maxSide: maxSide), let jpeg = jpeg(image) else {
                throw AssistantPagesError.unreadable
            }
            out.append(.init(page: 1, jpeg: jpeg))
        }
        if out.isEmpty { throw AssistantPagesError.noPages }
        return out
    }

    /// The image at most `maxSide`, as a JPEG within `maxBytes`.
    static func jpeg(_ image: CGImage) -> Data? {
        guard let small = KnowledgeOCR.turned(image, .up, maxSide: maxSide) else { return nil }
        for quality: CGFloat in [0.7, 0.5, 0.3] {
            guard let data = KnowledgeOCR.jpeg(small, quality: quality) else { return nil }
            if data.count <= maxBytes { return data }
        }
        return nil
    }
}

extension AssistantPagesRequest {
    /// "1–3, 7"
    static func pagesText(_ pages: [Int]) -> String {
        var runs: [String] = []
        var i = 0
        while i < pages.count {
            var j = i
            while j + 1 < pages.count, pages[j + 1] == pages[j] + 1 { j += 1 }
            runs.append(j > i ? "\(pages[i])–\(pages[j])" : "\(pages[i])")
            i = j + 1
        }
        return runs.joined(separator: ", ")
    }

    /// How it ended, in a few words; nil while it waits.
    var outcome: String? {
        switch answer {
        case let .sent(pages):
            let list = Self.pagesText(pages)
            return pages.count == 1 ? String(localized: "Sent page \(list)") : String(localized: "Sent pages \(list)")
        case .declined:
            return String(localized: "Not sent")
        case let .failed(error):
            return String(localized: "Not sent: \(error)")
        case nil:
            return skipped ? String(localized: "Not answered") : nil
        }
    }
}

/// The assistant asks to look at pages of a document: which ones, the document (a tap opens it),
/// and **Send Pages** / **Don’t Send** while it waits; with the family's *Read with the assistant*
/// on, this device sends them by itself. A device without the knowledge folder can only decline.
struct AssistantPagesCard: View {
    let request: AssistantPagesRequest
    let store: AssistantChatStore
    /// It waits for the user (the chat's last open question or edit), and whether a turn runs.
    var isOpen = false
    var busy = false
    var open: (AppRoute) -> Void = { _ in }

    var body: some View {
        let sending = store.isSendingPages(request.id)
        let canSend = store.canSendPages
        let active = isOpen && !busy && !sending
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(verbatim: request.summary).font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "doc.viewfinder").foregroundStyle(ModuleTint.assistant)
            }
            Button {
                open(.knowledgeDocument(id: request.documentId, page: request.pages.first))
            } label: {
                Label(KnowledgePath.breadcrumb(request.path), systemImage: "doc")
                    .lineLimit(2)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            if isOpen || sending {
                Group {
                    if !canSend {
                        Text("Only a device with the family’s knowledge folder can send the pages.")
                    } else if sending {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Sending the pages…")
                        }
                    } else if !request.auto {
                        Text("The pages go to the family’s AI service as pictures.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Don’t Send") {
                        store.declinePages(request.id)
                    }
                    .buttonStyle(.bordered)
                    if canSend {
                        Button("Send Pages") {
                            Task { await store.sendPages(request.id) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ModuleTint.assistant)
                        .accessibilityLabel(Text("Send: \(request.summary)"))
                    }
                }
                .disabled(!active)
            }
            if let outcome = request.outcome {
                Label {
                    Text(verbatim: outcome)
                } icon: {
                    if case .sent = request.answer {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if request.answer != nil {
                        Image(systemName: "xmark.circle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .contentCard(cornerRadius: 18, padding: 12)
        // The family said yes once and for all: sent as soon as it waits here.
        .task(id: "\(request.id) \(isOpen) \(busy)") {
            guard isOpen, !busy, request.auto, request.answer == nil, canSend else { return }
            await store.sendPages(request.id)
        }
    }
}
