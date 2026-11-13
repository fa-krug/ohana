import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Ohana

/// The assistant looks at a knowledge document's pages (view_knowledge_pages): the item, how it
/// ended, rendering the pages from the folder, and how many chats the settings keep.
struct AssistantPagesTests {
    static let itemsJSON = """
    {
      "chat": { "id": "c1", "title": "Befund", "status": "idle", "updatedAt": "2026-11-01T08:00:00.000Z" },
      "rev": 3,
      "items": [
        { "kind": "pages", "id": "call_1", "summary": "Look at pages 1–2 of “Befund.pdf”", "documentId": "d1",
          "name": "Befund.pdf", "path": "Health/Befund.pdf", "hash": "abc", "pages": [1, 2], "total": 3, "auto": false },
        { "kind": "pages", "id": "call_2", "summary": "S", "documentId": "d1", "name": "B.pdf", "path": "B.pdf",
          "hash": "h", "pages": [1, 2, 3], "total": 3, "auto": true, "answer": { "sent": [1, 3] } },
        { "kind": "pages", "id": "call_3", "summary": "S", "documentId": "d1", "name": "B.pdf", "path": "B.pdf",
          "hash": "h", "pages": [2], "total": 3, "auto": false, "answer": { "declined": true } },
        { "kind": "pages", "id": "call_4", "summary": "S", "documentId": "d1", "name": "B.pdf", "path": "B.pdf",
          "hash": "h", "pages": [2], "total": 3, "auto": false, "answer": { "error": "Gone" } },
        { "kind": "pages", "id": "call_5", "summary": "S", "documentId": "d1", "name": "B.pdf", "path": "B.pdf",
          "hash": "h", "pages": [2], "total": 3, "auto": false, "skipped": true }
      ]
    }
    """

    @Test func decodesThePagesItem() throws {
        let state = try JSONDecoder().decode(AssistantChatState.self, from: Data(Self.itemsJSON.utf8))
        let requests = state.items.compactMap { item -> AssistantPagesRequest? in
            if case let .pages(request) = item { request } else { nil }
        }
        #expect(requests.count == 5)
        #expect(requests[0] == AssistantPagesRequest(
            id: "call_1", summary: "Look at pages 1–2 of “Befund.pdf”", documentId: "d1", name: "Befund.pdf",
            path: "Health/Befund.pdf", pages: [1, 2], total: 3, auto: false
        ))
        #expect(state.items[0].canWait)
        #expect(requests.map(\.answer) == [nil, .sent([1, 3]), .declined, .failed("Gone"), nil])
        #expect(requests.map(\.outcome) == [nil, "Sent pages 1, 3", "Not sent", "Not sent: Gone", "Not answered"])
        #expect(AssistantPagesRequest.pagesText([1, 2, 3, 5, 7, 8]) == "1–3, 5, 7–8")
    }

    @Test func offersTheChatLimits() {
        #expect(AssistantChatRetention.choices(including: 50) == [10, 20, 50, 100, 200, 500])
        #expect(AssistantChatRetention.choices(including: 30) == [10, 20, 30, 50, 100, 200, 500])
        #expect(AssistantChatRetention.label(50) == "Last 50 chats")
    }

    // MARK: Rendering

    /// A folder of its own under the temporary directory, as the linked knowledge folder.
    private final class Folder {
        let root = FileManager.default.temporaryDirectory.appending(path: "pages-\(UUID().uuidString)", directoryHint: .isDirectory)

        init() throws {
            try FileManager.default.createDirectory(at: root.appending(path: "Health"), withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// A PDF of `pages` pages, each 600 × 900 points.
        func pdf(_ path: String, pages: Int) {
            var box = CGRect(x: 0, y: 0, width: 600, height: 900)
            let context = CGContext(root.appending(path: path) as CFURL, mediaBox: &box, nil)!
            for _ in 0..<pages {
                context.beginPDFPage(nil)
                context.setFillColor(CGColor(gray: 0.5, alpha: 1))
                context.fill(CGRect(x: 100, y: 100, width: 200, height: 200))
                context.endPDFPage()
            }
            context.closePDF()
        }

        /// A PNG of 3000 × 1000 pixels.
        func png(_ path: String) {
            let context = CGContext(data: nil, width: 3000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1000))
            let destination = CGImageDestinationCreateWithURL(root.appending(path: path) as CFURL,
                                                              UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            CGImageDestinationFinalize(destination)
        }
    }

    private static func size(_ jpeg: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    @Test func rendersTheAskedPagesOfAPDF() async throws {
        let folder = try Folder()
        folder.pdf("Health/Befund.pdf", pages: 3)
        let pages = try await AssistantPagesRender.render(path: "Health/Befund.pdf", pages: [1, 3, 9], in: folder.root)
        #expect(pages.map(\.page) == [1, 3])
        for page in pages {
            #expect(page.jpeg.starts(with: [0xFF, 0xD8, 0xFF]))
            let size = try #require(Self.size(page.jpeg))
            #expect(max(size.width, size.height) <= AssistantPagesRender.maxSide)
            #expect(size.height > size.width)
        }
        await #expect(throws: AssistantPagesError.noPages) {
            try await AssistantPagesRender.render(path: "Health/Befund.pdf", pages: [7], in: folder.root)
        }
    }

    @Test func rendersAnImageAsOnePage() async throws {
        let folder = try Folder()
        folder.png("Photo.png")
        let pages = try await AssistantPagesRender.render(path: "Photo.png", pages: [1], in: folder.root)
        #expect(pages.map(\.page) == [1])
        #expect(Self.size(pages[0].jpeg)?.width == AssistantPagesRender.maxSide)
    }

    @Test func refusesWhatItCantSend() async throws {
        let folder = try Folder()
        try Data("# Note".utf8).write(to: folder.root.appending(path: "Note.md"))
        await #expect(throws: AssistantPagesError.notFound) {
            try await AssistantPagesRender.render(path: "Health/Gone.pdf", pages: [1], in: folder.root)
        }
        await #expect(throws: AssistantPagesError.unsupported) {
            try await AssistantPagesRender.render(path: "Note.md", pages: [1], in: folder.root)
        }
    }
}
