import PDFKit
import QuickLook
import SwiftUI

/// *Open original* on a page: loads the document's file from the knowledge folder on this device
/// (`KnowledgeOriginal`; iCloud loads it first where it isn't on the device), then shows a PDF in
/// the app at a page with a quote marked (`KnowledgePDFViewer`), anything else in Quick Look. A
/// device without the folder says so and offers Settings → Knowledge. Pages show it with
/// `.knowledgeOriginal(opener)`.
@Observable
final class KnowledgeOriginalOpener {
    /// A PDF on screen.
    struct ShownPDF: Identifiable {
        let id = UUID()
        let file: KnowledgeOriginalFile
        let document: PDFDocument
        let name: String
        /// From 1.
        let page: Int?
        let quote: String?
    }

    /// Loading (a file iCloud may have to load first).
    private(set) var loading = false
    var pdf: ShownPDF?
    /// Another kind of file, in Quick Look.
    var preview: URL?
    var failure: KnowledgeOriginalError?
    @ObservationIgnored private var previewFile: KnowledgeOriginalFile?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var loader: KnowledgeOriginalLoader?

    /// Opens `document`'s original from `folder`, at `page` (from 1) with `quote` marked.
    func open(_ document: KnowledgeDocumentSummary, page: Int? = nil, quote: String? = nil, folder: KnowledgeFolder) {
        cancel()
        loading = true
        let loader = KnowledgeOriginalLoader()
        self.loader = loader
        let online = Connectivity.shared.isOnline
        task = Task {
            defer { if !Task.isCancelled { loading = false } }
            do {
                let file = try await loader.fetch(path: document.path, folder: folder, online: online)
                guard !Task.isCancelled else { return file.discard() }
                if file.isPDF, let pdfDocument = PDFDocument(url: file.url) {
                    pdf = ShownPDF(file: file, document: pdfDocument, name: document.name, page: page, quote: quote)
                } else {
                    previewClosed()
                    previewFile = file
                    preview = file.url
                }
            } catch let error as KnowledgeOriginalError {
                failure = error
            } catch is CancellationError {
                // Cancelled.
            } catch {
                ErrorBanner.shared.show(error)
            }
        }
    }

    /// Stops loading (the wait for iCloud too).
    func cancel() {
        loader?.cancel()
        loader = nil
        task?.cancel()
        task = nil
        loading = false
    }

    /// Quick Look closed: its copy goes.
    func previewClosed() {
        previewFile?.discard()
        previewFile = nil
    }
}

private struct KnowledgeOriginalPresentation: ViewModifier {
    @Bindable var opener: KnowledgeOriginalOpener
    @Environment(FamilyContext.self) private var family

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if opener.loading {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading the original…")
                            .font(.callout)
                        Button("Cancel") { opener.cancel() }
                            .font(.callout.weight(.semibold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.35), value: opener.loading)
            .sheet(item: $opener.pdf) { shown in
                KnowledgePDFViewer(shown: shown)
            }
            .quickLookPreview($opener.preview)
            .onChange(of: opener.preview) { _, url in
                if url == nil { opener.previewClosed() }
            }
            .alert(Text(verbatim: opener.failure?.localizedDescription ?? ""),
                   isPresented: Binding(get: { opener.failure != nil }, set: { if !$0 { opener.failure = nil } }),
                   presenting: opener.failure) { failure in
                if failure.offersSettings {
                    Button("Choose Folder…") { family.open(.settings(.knowledge)) }
                }
                Button("OK", role: .cancel) {}
            }
    }
}

extension View {
    /// Shows what `opener` opens: the loading note, the PDF, Quick Look, or why it can't.
    func knowledgeOriginal(_ opener: KnowledgeOriginalOpener) -> some View {
        modifier(KnowledgeOriginalPresentation(opener: opener))
    }
}

/// A PDF original in the app, at its page with the quote marked; its copy goes when it closes.
struct KnowledgePDFViewer: View {
    let shown: KnowledgeOriginalOpener.ShownPDF
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            KnowledgePDFView(document: shown.document, page: shown.page, quote: shown.quote)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(Text(verbatim: shown.name))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: shown.file.url)
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 640, idealWidth: 860, minHeight: 560, idealHeight: 900)
        #endif
        .onDisappear { shown.file.discard() }
    }
}

#if os(iOS)
private typealias PDFRepresentable = UIViewRepresentable
private typealias PlatformColor = UIColor
#else
private typealias PDFRepresentable = NSViewRepresentable
private typealias PlatformColor = NSColor
#endif

/// PDFKit's view: the document at `page` (from 1), `quote` marked and scrolled to.
private struct KnowledgePDFView: PDFRepresentable {
    let document: PDFDocument
    var page: Int?
    var quote: String?

    #if os(iOS)
    func makeUIView(context: Context) -> PDFView { make() }
    func updateUIView(_ view: PDFView, context: Context) {}
    #else
    func makeNSView(context: Context) -> PDFView { make() }
    func updateNSView(_ view: PDFView, context: Context) {}
    #endif

    private func make() -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = document
        let selection = quote.flatMap { KnowledgePDFHighlight.selection(in: document, page: page, quote: $0) }
        selection?.color = PlatformColor.systemYellow.withAlphaComponent(0.5)
        let target = page.flatMap { document.page(at: min(max($0, 1), max(document.pageCount, 1)) - 1) }
        // Once laid out: before, going to a place doesn't stick.
        DispatchQueue.main.async {
            if let selection {
                view.highlightedSelections = [selection]
                view.go(to: selection)
            } else if let target {
                view.go(to: target)
            }
        }
        return view
    }
}

/// Where a quote is in a PDF: on its page, else the pages next to it (or anywhere without a page),
/// matched like `KnowledgeQuoteMatch` (whitespace, case and accents ignored; its first words when
/// the whole isn't there).
enum KnowledgePDFHighlight {
    static func selection(in document: PDFDocument, page: Int?, quote: String) -> PDFSelection? {
        guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        for index in pageOrder(page: page, count: document.pageCount) {
            guard let pdfPage = document.page(at: index), let text = pdfPage.string,
                  let range = KnowledgeQuoteMatch.nsRange(of: quote, in: text) else { continue }
            return pdfPage.selection(for: range)
        }
        return nil
    }

    /// The pages looked at (0-based): `page` (from 1) and the ones beside it; all without one.
    nonisolated static func pageOrder(page: Int?, count: Int) -> [Int] {
        guard count > 0 else { return [] }
        guard let page else { return Array(0..<count) }
        let index = page - 1
        return [index, index - 1, index + 1].filter { (0..<count).contains($0) }
    }
}
