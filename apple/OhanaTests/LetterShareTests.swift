import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Ohana

/// Photos and PDFs shared to Ohana: which files it takes, and how their pages wait for the
/// letter review (`LetterScanInbox`).
@MainActor
struct LetterShareTests {
    /// A PNG of a plain page, `width` pixels wide, in a folder of its own.
    static func png(width: Int) throws -> URL {
        let url = try LetterFilingTests.temporaryFolder().appendingPathComponent("page.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, LetterFilingTests.image(width: width, height: 300), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func takesPhotosAndPDFsOnly() {
        #expect(LetterScanInbox.accepts(URL(filePath: "/tmp/letter.pdf")))
        #expect(LetterScanInbox.accepts(URL(filePath: "/tmp/IMG_0001.HEIC")))
        #expect(LetterScanInbox.accepts(URL(filePath: "/tmp/photo.jpg")))
        #expect(!LetterScanInbox.accepts(URL(filePath: "/tmp/notes.txt")))
        #expect(!LetterScanInbox.accepts(URL(filePath: "/tmp/noextension")))
        #expect(!LetterScanInbox.accepts(URL(string: "https://example.com/letter.pdf")!))
    }

    @Test func filesSharedTogetherMakeOneLetterInOrder() async throws {
        let inbox = LetterScanInbox()
        inbox.receive(try Self.png(width: 200))
        inbox.receive(try Self.png(width: 300))
        await inbox.settled()
        let letter = try #require(inbox.takeLetter())
        #expect(letter.images.map(\.width) == [200, 300])
        #expect(inbox.takeLetter() == nil)
    }

    @Test func addingKeepsTheLetterAndItsPageLimit() {
        let inbox = LetterScanInbox()
        let page = LetterFilingTests.image(width: 10, height: 10)
        inbox.add(Array(repeating: page, count: 15))
        let id = inbox.letter?.id
        inbox.add(Array(repeating: page, count: 15))
        #expect(inbox.letter?.id == id)
        #expect(inbox.letter?.images.count == LetterScan.maxPages)
    }

    @Test func anUnreadableFileAddsNothing() async throws {
        let url = try LetterFilingTests.temporaryFolder().appendingPathComponent("broken.jpg")
        try Data("not an image".utf8).write(to: url)
        let inbox = LetterScanInbox()
        inbox.receive(url)
        await inbox.settled()
        #expect(inbox.takeLetter() == nil)
    }
}
