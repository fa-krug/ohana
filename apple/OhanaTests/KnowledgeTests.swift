import CoreGraphics
import Foundation
import Testing
@testable import Ohana

private func folder() throws -> URL {
    try LetterFilingTests.temporaryFolder()
}

private func write(_ text: String, _ path: String, in root: URL) throws -> URL {
    let url = root.appending(path: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    return url
}

/// Listing the folder: what's left out, NFC paths, tags, iCloud placeholders.
struct KnowledgeWalkerTests {
    @Test func listsFilesAndSkipsHiddenPackagesAndLinksOut() throws {
        let root = try folder(), outside = try folder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let policy = try write("Policy", "Policy.pdf", in: root)
        try FinderTags.write(["Versicherung", "Auto"], to: policy)
        _ = try write("Note", "Sub/Deeper/note.txt", in: root)
        _ = try write("{}", KnowledgeMarker.fileName, in: root)
        _ = try write("x", ".DS_Store", in: root)
        _ = try write("x", ".hidden/inside.txt", in: root)
        _ = try write("x", "Thing.app/Contents/Info.plist", in: root)
        _ = try write("x", "back\\slash.txt", in: root)
        let secret = try write("secret", "secret.txt", in: outside)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link-out.txt"), withDestinationURL: secret)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "folder-link"), withDestinationURL: outside)

        let listing = KnowledgeWalker.walk(root)
        #expect(listing.files.map(\.path) == ["Policy.pdf", "Sub/Deeper/note.txt"])
        #expect(!listing.truncated && listing.tooLarge == 0)
        let file = try #require(listing.files.first)
        #expect(file.size == 6 && file.mtime > 0 && file.downloaded)
        #expect(file.tags == ["Versicherung", "Auto"])
    }

    @Test func linksAreSkippedEvenInsideTheFolder() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try write("Text", "a.txt", in: root)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "b.txt"), withDestinationURL: target)
        // A loop: a folder linking back to the folder.
        _ = try write("x", "Sub/c.txt", in: root)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Sub/loop"), withDestinationURL: root)
        let listing = KnowledgeWalker.walk(root)
        #expect(listing.files.map(\.path) == ["Sub/c.txt", "a.txt"])
        #expect(listing.unlistable.isEmpty && !listing.truncated)
    }

    @Test func aFolderThatCantBeListedIsRecorded() throws {
        let root = try folder()
        let locked = root.appending(path: "Locked")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }
        _ = try write("x", "a.txt", in: root)
        _ = try write("x", "Locked/b.txt", in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let listing = KnowledgeWalker.walk(root)
        #expect(listing.unlistable == ["Locked"])
        #expect(listing.files.map(\.path) == ["a.txt"])
        #expect(KnowledgeWalker.walk(root.appending(path: "none")).unlistable == [""])
    }

    @Test func pathsAreNFC() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        // Decomposed on the disk, as macOS file names often are.
        let decomposed = "Bu\u{0308}cher/Re\u{0301}sume\u{0301}.txt"
        _ = try write("x", decomposed, in: root)
        let file = try #require(KnowledgeWalker.walk(root).files.first)
        #expect(file.path == "B\u{00FC}cher/R\u{00E9}sum\u{00E9}.txt")
        #expect(file.path.unicodeScalars.elementsEqual("Bücher/Résumé.txt".precomposedStringWithCanonicalMapping.unicodeScalars))
    }

    @Test func sizeAndCountLimits() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("short", "a.txt", in: root)
        _ = try write("a longer text", "b.txt", in: root)
        _ = try write("c", "c.txt", in: root)
        let small = KnowledgeWalker.walk(root, maxFileSize: 5)
        #expect(small.files.map(\.path) == ["a.txt", "c.txt"] && small.tooLarge == 1)
        let few = KnowledgeWalker.walk(root, maxFiles: 2)
        #expect(few.truncated)
        #expect(!KnowledgeWalker.walk(root, maxFiles: 3).truncated)
    }

    @Test func iCloudPlaceholdersShowUnderTheirRealName() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = ["NSURLNameKey": "Vertrag.pdf", "NSURLFileSizeKey": 123_456,
                                   "NSURLFileResourceTypeKey": "NSURLFileResourceTypeRegular"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        try FileManager.default.createDirectory(at: root.appending(path: "Sub"), withIntermediateDirectories: true)
        try data.write(to: root.appending(path: "Sub/.Vertrag.pdf.icloud"))
        // Without a readable property list: the name alone.
        try Data("x".utf8).write(to: root.appending(path: ".Brief.txt.icloud"))
        // A hidden file's placeholder stays hidden.
        try Data("x".utf8).write(to: root.appending(path: "..hidden.icloud"))
        let files = KnowledgeWalker.walk(root).files
        #expect(files.map(\.path) == ["Brief.txt", "Sub/Vertrag.pdf"])
        let contract = try #require(files.last)
        #expect(!contract.downloaded && contract.size == 123_456 && contract.tags.isEmpty)
        #expect(contract.url.lastPathComponent == "Vertrag.pdf")
    }

    @Test func pathsTheServerRefuses() {
        #expect(KnowledgeWalker.isValidPath("a/b.pdf"))
        #expect(!KnowledgeWalker.isValidPath(""))
        #expect(!KnowledgeWalker.isValidPath("a/.b"))
        #expect(!KnowledgeWalker.isValidPath("a//b"))
        #expect(!KnowledgeWalker.isValidPath("a\\b"))
        #expect(!KnowledgeWalker.isValidPath("a\u{7}b"))
        #expect(!KnowledgeWalker.isValidPath(String(repeating: "a", count: 1025)))
    }

    @Test func uploadBodySaysWhetherScansWereChecked() throws {
        let file = KnowledgeFileInfo(path: "a.pdf", size: 1, mtime: 1, hash: "h", tags: [])
        func json(_ body: KnowledgeUploadBody) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        }
        let checked = try json(KnowledgeUploadBody(folderId: "k1", file: file, pages: ["x"], reader: 2, scansChecked: true))
        #expect(checked["scansChecked"] as? Bool == true && checked["reread"] == nil)
        let unchecked = try json(KnowledgeUploadBody(folderId: "k1", file: file, pages: ["x"], reader: 2))
        #expect(unchecked["scansChecked"] == nil)
    }

    @Test func tagsAsTheServerTakesThem() {
        let many = (1...60).map { "t\($0)" }
        #expect(KnowledgeTags.cleaned([" Auto ", "", "Auto", "auto", String(repeating: "x", count: 101)]) == ["Auto", "auto"])
        #expect(KnowledgeTags.cleaned(many).count == 50)
        #expect(KnowledgeTags.cleaned(["Bu\u{0308}ro"]) == ["B\u{00FC}ro"])
    }
}

/// Hashes: only what changed is read again.
struct KnowledgeHashTests {
    private func file(_ path: String = "a.pdf", size: Int64 = 10, mtime: Int64 = 1000) -> KnowledgeLocalFile {
        KnowledgeLocalFile(path: path, url: URL(filePath: "/tmp/\(path)"), size: size, mtime: mtime, tags: ["T"])
    }

    @Test func cacheIsInvalidatedBySizeOrDate() throws {
        var cache = KnowledgeHashCache()
        #expect(cache.hash(for: file()) == nil)
        cache.set(file(), hash: "h1")
        #expect(cache.hash(for: file()) == "h1")
        #expect(cache.hash(for: file(size: 11)) == nil)
        #expect(cache.hash(for: file(mtime: 1001)) == nil)
        #expect(cache.tags(for: "a.pdf") == ["T"])
        // Not on the device: the placeholder's date isn't the file's, its size counts.
        var placeholder = file(mtime: 5)
        placeholder.downloaded = false
        #expect(cache.hash(for: placeholder) == "h1")
        placeholder.size = 11
        #expect(cache.hash(for: placeholder) == nil)
        #expect(cache.lastHash(path: "a.pdf", size: 10) == "h1" && cache.lastHash(path: "a.pdf", size: 11) == nil)
        cache.set(file("b.pdf"), hash: "h2")
        cache.keep(only: ["b.pdf"])
        #expect(cache.entries.keys.sorted() == ["b.pdf"])

        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = root.appending(path: "x/hashes.json")
        try cache.save(to: saved)
        #expect(KnowledgeHashCache.load(saved) == cache)
        #expect(KnowledgeHashCache.load(root.appending(path: "none.json")) == KnowledgeHashCache())
    }

    @Test func aFailedReadIsRememberedUntilTheFileChanges() {
        var cache = KnowledgeHashCache()
        cache.set(file(), hash: "h1")
        #expect(!cache.readFailed(path: "a.pdf", hash: "h1"))
        cache.setReadFailed(path: "a.pdf", hash: "h1")
        #expect(cache.readFailed(path: "a.pdf", hash: "h1") && !cache.readFailed(path: "a.pdf", hash: "h2"))
        // The same content again (a new date): still known.
        cache.set(file(mtime: 2000), hash: "h1")
        #expect(cache.readFailed(path: "a.pdf", hash: "h1"))
        // New content: read again.
        cache.set(file(mtime: 3000), hash: "h2")
        #expect(!cache.readFailed(path: "a.pdf", hash: "h2"))
    }

    @Test func aNewerReaderTriesAFailedFileAgain() throws {
        var cache = KnowledgeHashCache()
        cache.set(file(), hash: "h1")
        cache.setReadFailed(path: "a.pdf", hash: "h1", reader: 1)
        #expect(cache.readFailed(path: "a.pdf", hash: "h1", reader: 1))
        #expect(!cache.readFailed(path: "a.pdf", hash: "h1", reader: 2))
        #expect(!cache.readFailed(path: "a.pdf", hash: "h1"))
        // Failed with the current reader: not again; worked: forgotten.
        cache.setReadFailed(path: "a.pdf", hash: "h1")
        #expect(cache.readFailed(path: "a.pdf", hash: "h1") && cache.readFailed(path: "a.pdf", hash: "h1", reader: 1))
        cache.setReadFailed(path: "a.pdf", hash: "h1", false)
        #expect(!cache.readFailed(path: "a.pdf", hash: "h1", reader: 1))
        // A cache from before the reader versions: its failures were reader 1's.
        let old = try JSONDecoder().decode(KnowledgeHashCache.self, from: Data(#"""
        {"entries": {"a.pdf": {"size": 10, "mtime": 1000, "hash": "h1", "tags": [], "readFailed": true}}}
        """#.utf8))
        #expect(old.readFailed(path: "a.pdf", hash: "h1", reader: 1) && !old.readFailed(path: "a.pdf", hash: "h1"))
    }

    @Test func readerVersions() {
        #expect(KnowledgeText.readerVersion == 2)
        #expect(KnowledgeText.reader(forPath: "Schule/Stundenplan.PDF") == 2)
        #expect(KnowledgeText.reader(forPath: "Foto.heic") == 2)
        #expect(KnowledgeText.reader(forPath: "Notizen.md") == 1 && KnowledgeText.reader(forPath: "Brief.docx") == 1)
    }

    @Test func iCloudDownloadsWithinTheBudget() {
        func placeholder(_ path: String, size: Int64) -> KnowledgeLocalFile {
            var local = file(path, size: size, mtime: 1)
            local.downloaded = false
            return local
        }
        var cache = KnowledgeHashCache()
        cache.set(file("known.pdf", size: 50, mtime: 9), hash: "hk")
        let files = [file("here.pdf"), placeholder("known.pdf", size: 50), placeholder("a.pdf", size: 60),
                     placeholder("b.pdf", size: 60), placeholder("c.pdf", size: 30)]
        let entry = cache.entries["known.pdf"]!
        #expect(KnowledgeHashStep.plan(files, cache: cache, downloads: KnowledgeDownloads(allowed: true, budget: 100))
            == [.hash, .cached(entry), .download, .later, .download])
        #expect(KnowledgeHashStep.plan(files, cache: cache, downloads: .none) == [.hash, .cached(entry), .later, .later, .later])
        #expect(KnowledgeHashStep.plan(files, cache: cache, downloads: .unlimited)
            == [.hash, .cached(entry), .download, .download, .download])
    }

    @Test func sha256OfAFile() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try write("abc", "abc.txt", in: root)
        let result = try KnowledgeHasher.sha256(url)
        #expect(result.hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(result.size == 3 && result.mtime > 0)
        // Bigger than a chunk.
        let big = root.appending(path: "big.bin")
        try Data(repeating: 0x61, count: KnowledgeHasher.chunkSize + 5).write(to: big)
        #expect(try KnowledgeHasher.sha256(big).size == Int64(KnowledgeHasher.chunkSize + 5))
        #expect(throws: (any Error).self) { try KnowledgeHasher.sha256(root.appending(path: "none")) }
    }
}

/// Choosing a folder: its marker against the family's folder on the server.
struct KnowledgeMarkerTests {
    private let here = KnowledgeLocation(server: URL(string: "https://Ohana.Example/")!, familyID: "f1")

    private func folder(_ id: String, used: Bool = false, device: String? = nil) -> KnowledgeFolderInfo {
        KnowledgeFolderInfo(id: id, createdAt: "2026-11-01T00:00:00Z", lastManifestAt: used ? "2026-11-02T00:00:00Z" : nil,
                            lastManifestDevice: device)
    }

    private func marker(server: String = "https://ohana.example", family: String = "f1", folder: String = "k1") -> KnowledgeMarker {
        KnowledgeMarker(server: server, familyId: family, folderId: folder)
    }

    @Test func serverIDs() {
        #expect(KnowledgeMarker.serverID(URL(string: "https://Ohana.Example/")!) == "https://ohana.example")
        #expect(KnowledgeMarker.serverID(URL(string: "http://localhost:3000")!) == "http://localhost:3000")
        #expect(KnowledgeMarker.serverID(URL(string: "https://x.example/ohana/")!) == "https://x.example/ohana")
        #expect(here.server == "https://ohana.example")
    }

    @Test func decisions() {
        func decide(_ marker: KnowledgeMarker?, _ server: KnowledgeFolderInfo?,
                    accepted: KnowledgeFolderError? = nil) -> KnowledgeLinkDecision {
            KnowledgeLinkDecision.decide(marker: marker, location: here, serverFolder: server, accepted: accepted)
        }
        // No marker: the family's folder (made, or the one no device reads yet).
        #expect(decide(nil, nil) == .create)
        #expect(decide(nil, folder("k1")) == .create)
        // …but one another device reads: asked first.
        #expect(decide(nil, folder("k1", used: true, device: "Mac")) == .conflict(.serverHasFolder(device: "Mac")))
        // This family's marker.
        #expect(decide(marker(), folder("k1", used: true)) == .use(folderID: "k1"))
        #expect(decide(marker(), nil) == .create)
        #expect(decide(marker(), folder("k2")) == .conflict(.otherFolder))
        // Another family's, or another server's.
        #expect(decide(marker(family: "f2"), folder("k1")) == .conflict(.otherFamily))
        #expect(decide(marker(server: "https://other.example"), nil) == .conflict(.otherFamily))
        // Asked and confirmed: the server's folder another device reads is replaced.
        #expect(decide(nil, folder("k1", used: true), accepted: .serverHasFolder(device: "Mac")) == .replace)
        #expect(decide(marker(), folder("k2"), accepted: .otherFolder) == .replace)
        // Another family's marker, confirmed: as a folder without one (which may ask again).
        #expect(decide(marker(family: "f2"), folder("k1"), accepted: .otherFamily) == .create)
        #expect(decide(marker(family: "f2"), nil, accepted: .otherFamily) == .create)
        #expect(decide(marker(family: "f2"), folder("k1", used: true, device: "Mac"), accepted: .otherFamily)
            == .conflict(.serverHasFolder(device: "Mac")))
        // Confirming one question doesn't answer another.
        #expect(decide(marker(family: "f2"), folder("k1"), accepted: .otherFolder) == .conflict(.otherFamily))
    }

    @Test func markerFile() throws {
        let root = try LetterFilingTests.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(KnowledgeMarker.read(in: root) == nil)
        try marker().write(in: root)
        #expect(KnowledgeMarker.read(in: root) == marker())
        try marker(folder: "k2").write(in: root)
        #expect(KnowledgeMarker.read(in: root)?.folderId == "k2")
        let json = try String(contentsOf: root.appending(path: ".ohana-knowledge.json"), encoding: .utf8)
        #expect(json.contains(#""folderId" : "k2""#) && json.contains(#""server" : "https://ohana.example""#))
        try Data("not json".utf8).write(to: root.appending(path: KnowledgeMarker.fileName))
        #expect(KnowledgeMarker.read(in: root) == nil)
    }

    @Test func linkIsRememberedPerServerAndFamilyAndForgottenOnSignOut() throws {
        let defaults = UserDefaults(suiteName: "ohana-tests-\(UUID().uuidString)")!
        let root = try LetterFilingTests.temporaryFolder(), base = try LetterFilingTests.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: base) }
        let link = KnowledgeFolder(location: here, defaults: defaults)
        let other = KnowledgeFolder(location: KnowledgeLocation(server: URL(string: "https://other.example")!, familyID: "f1"),
                                    defaults: defaults)
        #expect(link.state() == .none && !link.isLinked)
        try link.remember(root, folderID: "k1")
        try other.remember(root, folderID: "k9")
        #expect(link.state().folderID == "k1")
        #expect(link.state().url?.standardizedFileURL.path == root.standardizedFileURL.path)
        try FileManager.default.createDirectory(at: here.directory(base: base), withIntermediateDirectories: true)
        KnowledgeFolder.removeAll(server: URL(string: "https://ohana.example")!, defaults: defaults, base: base)
        #expect(!link.isLinked && other.isLinked)
        #expect(!FileManager.default.fileExists(atPath: here.directory(base: base).path))
        other.unlink()
        #expect(!other.isLinked)
        // Replaced by another device's folder: kept as such until chosen again.
        link.markReplaced()
        #expect(link.state() == .none)
        try link.remember(root, folderID: "k1")
        link.markReplaced()
        #expect(link.state() == .replaced && link.isLinked)
        try link.remember(root, folderID: "k2")
        #expect(link.state().folderID == "k2")
    }

    @Test func deviceNamesAsTheServerKeepsThem() {
        #expect(KnowledgeDevice.normalized("  Anna’s iPhone \n") == "Anna’s iPhone")
        #expect(KnowledgeDevice.normalized("   ") == nil && KnowledgeDevice.normalized(nil) == nil)
        #expect(KnowledgeDevice.normalized("Bu\u{0308}ro") == "B\u{00FC}ro")
        // At most 100 UTF-16 units, never inside a character (an emoji is two).
        let long = String(repeating: "a", count: 99) + "😀b"
        #expect(KnowledgeDevice.normalized(long) == String(repeating: "a", count: 99))
        #expect(KnowledgeDevice.normalized(String(repeating: "x", count: 150))?.utf16.count == 100)
        #expect(KnowledgeDevice.isThisDevice("Ma\u{0301}c", own: " Mác "))
        #expect(KnowledgeDevice.isThisDevice(String(repeating: "x", count: 100), own: String(repeating: "x", count: 120)))
        #expect(!KnowledgeDevice.isThisDevice("Other", own: "Mac") && !KnowledgeDevice.isThisDevice(nil, own: "Mac"))
    }
}

/// Settings → Knowledge: the server's status, where the folder is, the page's route.
struct KnowledgeSettingsTests {
    @Test func statusDecodes() throws {
        let json = #"""
        {"folder": {"id": "k1", "createdAt": "2026-11-01T00:00:00.000Z", "lastManifestAt": "2026-11-02T08:30:00.000Z",
                    "lastManifestDevice": "Anna’s iPhone"},
         "counts": {"pending": 2, "ready": 40, "failed": 1, "missing": 0, "excluded": 3}, "chunks": 512}
        """#
        let status = try APIClient.decoder.decode(KnowledgeStatusInfo.self, from: Data(json.utf8))
        #expect(status.folder?.lastManifestDevice == "Anna’s iPhone")
        #expect(status.folder?.lastManifestAt.flatMap(Date.server) != nil)
        #expect(status.counts == KnowledgeStatusInfo.Counts(pending: 2, ready: 40, failed: 1, missing: 0, excluded: 3))
        #expect(status.chunks == 512)
        let none = try APIClient.decoder.decode(KnowledgeStatusInfo.self, from: Data(#"""
        {"folder": null, "counts": {"pending": 0, "ready": 0, "failed": 0, "missing": 0, "excluded": 0}, "chunks": 0}
        """#.utf8))
        #expect(none.folder == nil && none.counts == KnowledgeStatusInfo.Counts())
        // Before page scans: neither offered.
        #expect(!status.readsScans && !status.sendsScans && status.folder?.aiScans == nil)
        let scans = try APIClient.decoder.decode(KnowledgeStatusInfo.self, from: Data(#"""
        {"folder": {"id": "k1", "createdAt": "2026-11-01T00:00:00.000Z", "aiScans": true},
         "counts": {"pending": 0, "ready": 1, "failed": 0, "missing": 0, "excluded": 0}, "chunks": 3,
         "cards": true, "scans": true, "aiScans": true}
        """#.utf8))
        #expect(scans.readsScans && scans.sendsScans && scans.folder?.aiScans == true)
        let off = try APIClient.decoder.decode(KnowledgeStatusInfo.self, from: Data(#"""
        {"folder": null, "counts": {"pending": 0, "ready": 0, "failed": 0, "missing": 0, "excluded": 0}, "chunks": 0,
         "scans": true, "aiScans": false}
        """#.utf8))
        #expect(off.readsScans && !off.sendsScans)
    }

    @Test func documentsSayWhatTheAssistantRead() throws {
        let detail = try APIClient.decoder.decode(KnowledgeDocumentResponse.self, from: Data(#"""
        {"document": {"id": "d1", "path": "Schule/Stundenplan.pdf", "status": "pending", "pages": 3, "aiPages": [2],
                      "scans": [{"page": 1, "status": "failed", "error": "The model can’t read images."},
                                {"page": 3, "status": "waiting"}, {"page": 2, "status": "done"}],
                      "chunks": []}}
        """#.utf8)).document
        #expect(detail.document.aiPages == [2])
        #expect(detail.scans == [KnowledgePageScanState(page: 1, status: .failed, error: "The model can’t read images."),
                                 KnowledgePageScanState(page: 3, status: .waiting, error: nil)])
        // An older server: none.
        let old = try APIClient.decoder.decode(KnowledgeDocumentResponse.self, from: Data(#"""
        {"document": {"id": "d1", "path": "a.pdf", "chunks": []}}
        """#.utf8)).document
        #expect(old.document.aiPages.isEmpty && old.scans.isEmpty)
    }

    @Test func folderPlaces() {
        let drive = "/Users/anna/Library/Mobile Documents/com~apple~CloudDocs"
        #expect(KnowledgeFolderPlace.describe(URL(filePath: "\(drive)/Family/Papers")) == "iCloud Drive › Family")
        #expect(KnowledgeFolderPlace.describe(URL(filePath: "\(drive)/Papers")) == "iCloud Drive")
        #expect(KnowledgeFolderPlace.describe(URL(filePath: drive)) == nil)
        #expect(KnowledgeFolderPlace.describe(URL(filePath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/A/B/C"))
            == "iCloud Drive › A › B")
        #expect(KnowledgeFolderPlace.describe(URL(filePath: "/Volumes/Disk/Papers")) == "Disk")
        #expect(KnowledgeFolderPlace.describe(URL(filePath: "/Papers")) == nil)
    }

    @Test func pageRoute() {
        #expect(AppRoute.parse(webPath: "/f/fam1/settings", tab: "knowledge")?.route == .settings(.knowledge))
        #expect(FamilySettingsPageView.page(for: .settings(.knowledge)) == .knowledge)
        // The page needs the knowledge base (an editor, not the demo).
        #expect(AppRoute.settings(.knowledge).requiredModule == .knowledge)
    }
}

/// Reading the text of the formats the device knows.
struct KnowledgeTextTests {
    @Test func plainTextUTF8AndLatin1() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let utf8 = try write("\u{FEFF}Grüße aus Köln", "a.txt", in: root)
        #expect(await KnowledgeText.pages(of: utf8) == ["Grüße aus Köln"])
        let latin1 = root.appending(path: "b.csv")
        try "Straße;Größe".data(using: .isoLatin1)!.write(to: latin1)
        #expect(await KnowledgeText.pages(of: latin1) == ["Straße;Größe"])
        let markdown = try write("# Titel\n\nText", "c.md", in: root)
        #expect(await KnowledgeText.pages(of: markdown) == ["# Titel\n\nText"])
    }

    @Test func rtf() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = NSAttributedString(string: "Hausratversicherung\nPolice 4711")
        let data = try text.data(from: NSRange(location: 0, length: text.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let url = root.appending(path: "police.rtf")
        try data.write(to: url)
        let pages = try #require(await KnowledgeText.pages(of: url))
        #expect(pages.count == 1 && pages[0].contains("Hausratversicherung") && pages[0].contains("Police 4711"))
    }

    @Test func html() async throws {
        let html = """
        <html><head><title>T</title><style>p { color: red }</style></head>
        <body><script>alert("x")</script><h1>Gr&uuml;&szlig;e</h1><p>Erste&nbsp;Zeile<br>zweite &amp; dritte</p>
        <!-- ein Kommentar --><ul><li>A &#228; &#x20AC;</li><li>B</li></ul></body></html>
        """
        #expect(KnowledgeText.htmlText(html) == "Grüße\n\nErste Zeile\nzweite & dritte\n\nA ä €\n\nB")
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try write(html, "page.htm", in: root)
        #expect(await KnowledgeText.pages(of: url)?.first?.contains("zweite & dritte") == true)
    }

    @Test func pdfWithText() async throws {
        let pages = [
            ScanPage(image: LetterFilingTests.image(width: 1240, height: 1754), lines: [
                ScanLine(text: "Versicherungsschein Hausrat Nummer 4711", box: CGRect(x: 0.1, y: 0.8, width: 0.7, height: 0.03)),
            ]),
            ScanPage(image: LetterFilingTests.image(width: 1240, height: 1754), lines: [
                ScanLine(text: "Beitrag jährlich 120 Euro, fällig am 1. Januar", box: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.03)),
            ]),
        ]
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "police.pdf")
        try ScanPDF.make(pages: pages, title: "Police", tags: []).write(to: url)
        let text = try #require(await KnowledgeText.pages(of: url))
        #expect(text.count == 2)
        #expect(text[0].contains("Versicherungsschein Hausrat"))
        #expect(text[1].contains("120 Euro"))
    }

    @Test func formatsThisDeviceCantRead() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let pages = try write("x", "Brief.pages", in: root)
        #expect(await KnowledgeText.pages(of: pages) == nil)
        #expect(!KnowledgeText.canRead(pages))
        let broken = try write("not a pdf", "broken.pdf", in: root)
        #expect(await KnowledgeText.pages(of: broken) == nil)
        #expect(KnowledgeText.canRead(URL(filePath: "/x/Scan.HEIC")))
        #if os(macOS)
        #expect(KnowledgeText.canRead(URL(filePath: "/x/Vertrag.docx")))
        #endif
    }

    @Test func limitsCutTheText() {
        #expect(KnowledgeText.limited(["a", "b", "c"], maxPages: 2) == ["a", "b"])
        #expect(KnowledgeText.limited(["abc", "def", "ghi"], maxBytes: 5) == ["abc", "de"])
        // Not inside a character: "ä" is two bytes.
        #expect(KnowledgeText.limited(["aää"], maxBytes: 4) == ["aä"])
        // NFC, as the server counts.
        #expect(KnowledgeText.limited(["a\u{0308}"]) == ["\u{00E4}"])
    }
}

/// The upload queue's rules, and server paths matched to the files.
@MainActor
struct KnowledgeQueueTests {
    private func upload(_ path: String, text: String? = nil) -> KnowledgeUpload {
        KnowledgeUpload(folderId: "k1", file: KnowledgeFileInfo(path: path, size: 1, mtime: 1, hash: "h", tags: []),
                        diskPath: path, textFile: text)
    }

    @Test func aPathWaitsOnce() throws {
        var queue = KnowledgeUploadQueue()
        queue.add(upload("a"))
        queue.add(upload("b", text: "t1"))
        #expect(queue.add(upload("b", text: "t2")) == "t1")
        #expect(queue.items.map(\.file.path) == ["a", "b"] && queue.items[1].textFile == "t2")
        #expect(queue.count == 2 && queue.first?.file.path == "a")

        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "k/queue.json")
        try queue.save(to: file)
        #expect(KnowledgeUploadQueue.load(file) == queue)
        try KnowledgeUploadQueue().save(to: file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func uploadsAreRemovedByIdentity() {
        func upload(_ path: String, hash: String) -> KnowledgeUpload {
            KnowledgeUpload(folderId: "k1", file: KnowledgeFileInfo(path: path, size: 1, mtime: 1, hash: hash, tags: []),
                            diskPath: path)
        }
        var queue = KnowledgeUploadQueue()
        let sent = upload("a", hash: "h1")
        queue.add(sent)
        queue.add(upload("b", hash: "h1"))
        // Changed while it was being sent: queued again with its new hash, at the end.
        queue.add(upload("a", hash: "h2"))
        #expect(queue.remove(sent) == nil)
        #expect(queue.items.map(\.file.hash) == ["h1", "h2"] && queue.first?.file.path == "b")
        #expect(queue.remove(upload("b", hash: "h1")) != nil)
        #expect(queue.first == upload("a", hash: "h2"))
        #expect(queue.remove(upload("a", hash: "h2")) != nil && queue.isEmpty && queue.first == nil)

        // Many changes stay in order (the order list is compacted on the way).
        for round in 0..<5 {
            for index in 0..<100 { queue.add(upload("p\(index)", hash: "r\(round)")) }
        }
        #expect(queue.count == 100 && queue.items.map(\.file.path) == (0..<100).map { "p\($0)" })
        #expect(queue.items.allSatisfy { $0.file.hash == "r4" })
        #expect(KnowledgeUploadQueue(queue.items) == queue)
        let dropped = queue.removeAll { $0.file.path.hasSuffix("1") }
        #expect(dropped.isEmpty && queue.count == 90)
    }

    @Test func refusalsDropAndOutagesWait() {
        func outcome(_ error: any Error) -> KnowledgeUploadQueue.Disposition { KnowledgeUploadQueue.disposition(of: error) }
        #expect(outcome(APIError.http(status: 400, message: nil)) == .drop)
        #expect(outcome(APIError.http(status: 404, message: nil)) == .drop)
        #expect(outcome(APIError.http(status: 413, message: nil)) == .drop)
        #expect(outcome(APIError.decoding("x")) == .drop)
        #expect(outcome(CocoaError(.fileReadNoSuchFile)) == .drop)
        #expect(outcome(APIError.http(status: 408, message: nil)) == .retry)
        #expect(outcome(APIError.http(status: 429, message: nil)) == .retry)
        #expect(outcome(APIError.http(status: 503, message: nil)) == .retry)
        #expect(outcome(APIError.transport("offline")) == .retry)
        #expect(outcome(URLError(.notConnectedToInternet)) == .retry)
        #expect(outcome(APIError.unauthorized(nil)) == .retry)
    }

    @Test func serverPathsMatchDecomposedNames() {
        let decomposed = "Bu\u{0308}cher/Re\u{0301}sume\u{0301}.pdf"
        let file = KnowledgeLocalFile(path: decomposed.precomposedStringWithCanonicalMapping,
                                      url: URL(filePath: "/Folder/\(decomposed)"), size: 1, mtime: 1, tags: [])
        let other = KnowledgeLocalFile(path: "a.pdf", url: URL(filePath: "/Folder/a.pdf"), size: 1, mtime: 1, tags: [])
        let matches = KnowledgeIndexer.match(["B\u{00FC}cher/R\u{00E9}sum\u{00E9}.pdf", "gone.pdf", "a.pdf", "a.pdf"],
                                             in: [file, other])
        #expect(matches.map(\.path) == [file.path, "a.pdf"])
        #expect(matches.first?.diskPath.unicodeScalars.elementsEqual(decomposed.unicodeScalars) == true)
        // Also a server path that came decomposed.
        #expect(KnowledgeIndexer.match([decomposed], in: [file]).count == 1)
        #expect(KnowledgeIndexer.relativePath(of: URL(filePath: "/Folder/Sub/x.pdf"), in: URL(filePath: "/Folder/")) == "Sub/x.pdf")
        #expect(KnowledgeIndexer.relativePath(of: URL(filePath: "/Other/x.pdf"), in: URL(filePath: "/Folder")) == nil)
    }
}

/// Answers the knowledge routes as set and records them; nothing leaves the test.
nonisolated final class KnowledgeStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [(String, Data?)] = []
    /// The page scans sent: the request line, its query and content type, and the body.
    struct Scan {
        var line: String
        var query: String
        var contentType: String?
        var body: Data
    }
    nonisolated(unsafe) private static var scanLog: [Scan] = []
    static var scans: [Scan] { lock.withLock { scanLog } }
    struct State {
        var upload: [String] = []
        var put = 202
        var offline = false
        var manifest = 200
        /// The family's folder as GET/POST /knowledge/folder answer it (JSON), "null" for none.
        var folder = "null"
        /// What POST /knowledge/folder answers instead, when set.
        var created: String?
        /// What GET /knowledge/tags answers (JSON).
        var tags = #"{"tags": []}"#
        /// PUT /knowledge/documents answers after this long.
        var putDelay: Double = 0
        /// What GET /knowledge/status answers (JSON).
        var status = "{}"
        /// PUT …/pages/{page}/scan answers this.
        var scan = 202
    }
    nonisolated(unsafe) private static var state = State()

    static func set(_ change: (inout State) -> Void) { lock.withLock { change(&state) } }

    static var requests: [String] { lock.withLock { log.map(\.0) } }
    static func bodies(_ prefix: String) -> [[String: Any]] {
        lock.withLock { log.filter { $0.0.hasPrefix(prefix) }.compactMap { $0.1 } }
            .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    static var upload: [String] {
        get { lock.withLock { state.upload } }
        set { lock.withLock { state.upload = newValue } }
    }
    static var putStatus: Int {
        get { lock.withLock { state.put } }
        set { lock.withLock { state.put = newValue } }
    }
    static var offline: Bool {
        get { lock.withLock { state.offline } }
        set { lock.withLock { state.offline = newValue } }
    }
    static func reset() { lock.withLock { log = []; scanLog = []; state = State() } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = data
        }
        Self.lock.withLock { Self.log.append(("\(method) \(path)", body)) }
        let state = Self.lock.withLock { Self.state }
        if state.offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        var status = 200
        var answer = Data("{}".utf8)
        if path.hasSuffix("/knowledge/manifest") {
            status = state.manifest
            answer = status >= 400 ? Data(#"{"error":"Not found"}"#.utf8)
                : try! JSONSerialization.data(withJSONObject: ["upload": state.upload])
        } else if path.hasSuffix("/knowledge/folder") {
            status = method == "POST" ? 201 : 200
            let folder = method == "POST" ? state.created ?? state.folder : state.folder
            answer = Data(#"{"folder": \#(folder)}"#.utf8)
        } else if path.hasSuffix("/knowledge/cards") {
            status = 202
            answer = Data(#"{"queued":2,"cardCounts":{"ready":0,"outdated":0,"pending":2,"rewriting":2,"failed":0}}"#.utf8)
        } else if path.hasSuffix("/knowledge/tags") {
            answer = Data(state.tags.utf8)
        } else if path.hasSuffix("/knowledge/status") {
            answer = Data(state.status.utf8)
        } else if path.contains("/pages/"), path.hasSuffix("/scan") {
            status = state.scan
            Self.lock.withLock {
                Self.scanLog.append(Scan(line: "\(method) \(path)", query: request.url?.query ?? "",
                                         contentType: request.value(forHTTPHeaderField: "Content-Type"), body: body ?? Data()))
            }
            answer = Data(status >= 400 ? #"{"error":"No"}"#.utf8 : #"{"page":1,"status":"waiting"}"#.utf8)
        } else if path.hasSuffix("/knowledge/documents") {
            status = state.put
            answer = Data(status >= 400 ? #"{"error":"No"}"#.utf8 : #"{"id":"d1","status":"pending"}"#.utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        let finish = { [answer] in
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: answer)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if path.hasSuffix("/knowledge/documents"), state.putDelay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + state.putDelay, execute: finish)
        } else {
            finish()
        }
    }
    override func stopLoading() {}
}

/// A run against a stub server: the manifest, then the uploads it asks for, through the queue.
@Suite(.serialized)
@MainActor
struct KnowledgeIndexerTests {
    private struct Setup {
        let root: URL
        let data: URL
        let indexer: KnowledgeIndexer
    }

    private func setup() throws -> Setup {
        KnowledgeStubProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KnowledgeStubProtocol.self]
        let api = FamilyAPI(client: APIClient(baseURL: URL(string: "https://kb.example")!, token: nil,
                                              session: URLSession(configuration: config)), familyID: "f1")
        let root = try folder(), data = try folder()
        let link = KnowledgeFolder(location: KnowledgeLocation(server: api.client.baseURL, familyID: "f1"),
                                   defaults: UserDefaults(suiteName: "ohana-tests-\(UUID().uuidString)")!)
        try link.remember(root, folderID: "k1")
        return Setup(root: root, data: data,
                     indexer: KnowledgeIndexer(api: api, folder: link, directory: data, deviceName: "Test Mac"))
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func anEmptyFolderSendsNothing() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        _ = try write("{}", KnowledgeMarker.fileName, in: s.root)
        await s.indexer.run()
        #expect(KnowledgeStubProtocol.requests.isEmpty)
        #expect(s.indexer.lastRun?.files == 0 && s.indexer.phase == .idle)
    }

    @Test func sendsTheManifestThenWhatTheServerAsksFor() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        _ = try write("Kündigung zum 31. März", "Verträge/Ku\u{0308}ndigung.txt", in: s.root)
        _ = try write("Rechnung", "rechnung.txt", in: s.root)
        _ = try write("x", "Brief.pages", in: s.root)
        KnowledgeStubProtocol.set { $0.upload = ["Verträge/Kündigung.txt", "Brief.pages"] }
        await s.indexer.run()

        #expect(KnowledgeStubProtocol.requests == ["POST /api/v1/families/f1/knowledge/manifest",
                                                   "PUT /api/v1/families/f1/knowledge/documents"])
        let manifest = try #require(KnowledgeStubProtocol.bodies("POST").first)
        #expect(manifest["folderId"] as? String == "k1" && manifest["device"] as? String == "Test Mac")
        let files = try #require(manifest["files"] as? [[String: Any]])
        #expect(files.compactMap { $0["path"] as? String } == ["Brief.pages", "Verträge/Kündigung.txt", "rechnung.txt"])
        #expect(files.allSatisfy { ($0["hash"] as? String)?.count == 64 })
        #expect(files.allSatisfy { $0["reader"] as? Int == 1 })
        let put = try #require(KnowledgeStubProtocol.bodies("PUT").first)
        #expect(put["path"] as? String == "Verträge/Kündigung.txt")
        #expect(put["reader"] as? Int == 1 && put["reread"] == nil && put["scansChecked"] == nil)
        #expect(put["pages"] as? [String] == ["Kündigung zum 31. März"])
        #expect(s.indexer.unreadable == ["Brief.pages": .format])
        #expect(s.indexer.lastRun?.files == 3 && s.indexer.lastRun?.uploaded == 1 && s.indexer.phase == .idle)
        #expect(s.indexer.waiting == 0)

        // Nothing changed: hashed from the cache, the server asks for nothing.
        KnowledgeStubProtocol.reset()
        await s.indexer.run()
        #expect(KnowledgeStubProtocol.requests == ["POST /api/v1/families/f1/knowledge/manifest"])
        #expect(s.indexer.phase == .idle)
    }

    private static let manifestPath = "POST /api/v1/families/f1/knowledge/manifest"

    private func manifestFiles() throws -> [String: [String: Any]] {
        let manifest = try #require(KnowledgeStubProtocol.bodies("POST").last)
        let files = try #require(manifest["files"] as? [[String: Any]])
        return Dictionary(uniqueKeysWithValues: files.map { ($0["path"] as! String, $0) })
    }

    /// An iCloud file that isn't on the device, as iOS shows it.
    private func placeholder(_ name: String, size: Int, in root: URL) throws {
        let info: [String: Any] = ["NSURLNameKey": name, "NSURLFileSizeKey": size,
                                   "NSURLFileResourceTypeKey": "NSURLFileResourceTypeRegular"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: root.appending(path: ".\(name).icloud"))
    }

    @Test func filesThatCantBeHashedAreListedWithoutAHash() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        _ = try write("Text", "a.txt", in: s.root)
        // Known from an earlier run (same size), not on the device now; and one never seen.
        try placeholder("Known.pdf", size: 40, in: s.root)
        try placeholder("New.pdf", size: 70, in: s.root)
        var cache = KnowledgeHashCache()
        cache.set(KnowledgeLocalFile(path: "Known.pdf", url: s.root.appending(path: "Known.pdf"), size: 40,
                                     mtime: 1_700_000_000_000, tags: ["Auto"]), hash: String(repeating: "c", count: 64))
        try cache.save(to: s.data.appending(path: "hashes.json"))

        // Not allowed to load anything (Low Data Mode, cellular).
        s.indexer.downloads = { .none }
        await s.indexer.run()
        var files = try manifestFiles()
        #expect(files.keys.sorted() == ["Known.pdf", "New.pdf", "a.txt"])
        #expect(files["Known.pdf"]?["hash"] as? String == String(repeating: "c", count: 64))
        #expect(files["Known.pdf"]?["mtime"] as? Int64 == 1_700_000_000_000 && files["Known.pdf"]?["tags"] as? [String] == ["Auto"])
        #expect(files["New.pdf"]?["hash"] is NSNull && files["New.pdf"]?["size"] as? Int == 70)
        #expect(files["New.pdf"]?["mtime"] as? Int == 0)
        #expect(s.indexer.lastRun?.files == 3 && s.indexer.lastRun?.deferred == 1 && s.indexer.lastRun?.unhashable == 0)

        // Allowed: iCloud doesn't load it (there's no iCloud here): still listed, without a hash.
        s.indexer.downloads = { .unlimited }
        KnowledgeStubProtocol.reset()
        await s.indexer.run()
        files = try manifestFiles()
        #expect(files["New.pdf"]?["hash"] is NSNull && files["Known.pdf"]?["hash"] as? String != nil)
        #expect(s.indexer.lastRun?.files == 3 && s.indexer.lastRun?.unhashable == 1 && s.indexer.lastRun?.deferred == 0)
    }

    @Test func aFolderThatCantBeListedSendsNothing() async throws {
        let s = try setup()
        let locked = s.root.appending(path: "Verträge")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data)
        }
        _ = try write("Text", "a.txt", in: s.root)
        _ = try write("Text", "Verträge/b.txt", in: s.root)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        await s.indexer.run()
        #expect(KnowledgeStubProtocol.requests.isEmpty)
        guard case let .failed(message) = s.indexer.phase else {
            Issue.record("phase \(s.indexer.phase)")
            return
        }
        #expect(message.contains("Verträge"))
    }

    @Test func aFileThatChangedWaitsForTheNextRun() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        _ = try write("Text", "a.txt", in: s.root)
        // Queued by an earlier run, hashed before it changed (another size now).
        let stale = KnowledgeUpload(folderId: "k1", file: KnowledgeFileInfo(path: "a.txt", size: 99, mtime: 1,
                                                                             hash: String(repeating: "0", count: 64), tags: []),
                                    diskPath: "a.txt")
        try KnowledgeUploadQueue([stale]).save(to: s.data.appending(path: "queue.json"))
        let indexer = KnowledgeIndexer(api: s.indexer.api, folder: s.indexer.folder, directory: s.data, deviceName: "Test Mac")
        await indexer.run()
        // One manifest, no upload and no run at once after it.
        #expect(KnowledgeStubProtocol.requests == [Self.manifestPath])
        #expect(indexer.waiting == 0 && indexer.phase == .idle && !indexer.isRunning)
    }

    @Test func aTextThatCantBeReadIsntReadAgain() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        _ = try write("not a pdf", "broken.pdf", in: s.root)
        KnowledgeStubProtocol.set { $0.upload = ["broken.pdf"] }
        await s.indexer.run()
        #expect(s.indexer.unreadable == ["broken.pdf": .failed])
        let cache = KnowledgeHashCache.load(s.data.appending(path: "hashes.json"))
        #expect(cache.entries["broken.pdf"]?.readFailed == true)
        #expect(!KnowledgeStubProtocol.requests.contains { $0.hasPrefix("PUT") })
        // Asked again: still not sent, still named.
        await s.indexer.run()
        #expect(s.indexer.unreadable == ["broken.pdf": .failed] && s.indexer.waiting == 0)
    }

    @Test func aFolderReplacedByAnotherDeviceStopsTheIndexing() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        _ = try write("Text", "a.txt", in: s.root)
        KnowledgeStubProtocol.set {
            $0.manifest = 404
            $0.folder = #"{"id": "k2", "createdAt": "2026-11-04T00:00:00Z"}"#
        }
        await s.indexer.run()
        #expect(KnowledgeStubProtocol.requests == [Self.manifestPath, "GET /api/v1/families/f1/knowledge/folder"])
        #expect(s.indexer.folder.state() == .replaced && s.indexer.phase == .idle)
        // Not read any more until a folder is chosen again.
        KnowledgeStubProtocol.reset()
        await s.indexer.run()
        #expect(KnowledgeStubProtocol.requests.isEmpty)
    }

    @Test func a404ForTheSameFolderIsJustAFailure() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        _ = try write("Text", "a.txt", in: s.root)
        KnowledgeStubProtocol.set {
            $0.manifest = 404
            $0.folder = #"{"id": "k1", "createdAt": "2026-11-04T00:00:00Z"}"#
        }
        await s.indexer.run()
        #expect(s.indexer.folder.state().folderID == "k1")
        if case .failed = s.indexer.phase {} else { Issue.record("phase \(s.indexer.phase)") }
    }

    @Test func usingAFolderAnywayReplacesTheServersFolder() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        let chosen = try folder()
        defer { try? FileManager.default.removeItem(at: chosen) }
        KnowledgeStubProtocol.set {
            $0.folder = #"{"id": "k1", "createdAt": "2026-11-01T00:00:00Z", "lastManifestAt": "2026-11-02T00:00:00Z", "lastManifestDevice": "Mac"}"#
        }
        await #expect(throws: KnowledgeFolderError.serverHasFolder(device: "Mac")) {
            try await s.indexer.link(chosen)
        }
        KnowledgeStubProtocol.set { $0.created = #"{"id": "k9", "createdAt": "2026-11-04T00:00:00Z"}"# }
        try await s.indexer.link(chosen, accepted: .serverHasFolder(device: "Mac"))
        let post = try #require(KnowledgeStubProtocol.bodies("POST").last)
        #expect(post["replace"] as? Bool == true)
        #expect(KnowledgeMarker.read(in: chosen)?.folderId == "k9")
        #expect(s.indexer.folder.state().folderID == "k9")
    }

    @Test func refusedUploadsAreDroppedAndOutagesWait() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        _ = try write("Text", "a.txt", in: s.root)
        KnowledgeStubProtocol.upload = ["a.txt"]
        KnowledgeStubProtocol.putStatus = 413
        await s.indexer.run()
        #expect(s.indexer.waiting == 0)
        #expect(!FileManager.default.fileExists(atPath: s.data.appending(path: "queue.json").path))

        // The server is down: the upload waits on the device and goes once it's back.
        KnowledgeStubProtocol.putStatus = 503
        await s.indexer.run()
        #expect(s.indexer.waiting == 1)
        #expect(FileManager.default.fileExists(atPath: s.data.appending(path: "queue.json").path))
        if case .failed = s.indexer.phase {} else { Issue.record("phase \(s.indexer.phase)") }
        KnowledgeStubProtocol.putStatus = 202
        s.indexer.retryNow()
        #expect(await until { s.indexer.waiting == 0 })
        #expect(KnowledgeStubProtocol.requests.last == "PUT /api/v1/families/f1/knowledge/documents")
    }

    private static let statusPath = "GET /api/v1/families/f1/knowledge/status"

    /// A PDF without a text layer: a letter, turned a quarter clockwise as phones photograph it,
    /// and with `twoPages` a page of ink nothing reads (a black bar: handwriting Vision misses).
    private func scannedPDF(twoPages: Bool) -> Data {
        var pages = [ScanPage(image: KnowledgeOCR.turned(KnowledgeOCRReadingTests.page(KnowledgeOCRReadingTests.letter), .right)!,
                              lines: [])]
        if twoPages {
            pages.append(ScanPage(image: LetterFilingTests.image(width: 1240, height: 1754,
                                                                 rect: CGRect(x: 100, y: 800, width: 1000, height: 80), fill: 0),
                                  lines: []))
        }
        return ScanPDF.make(pages: pages, title: "Brief", tags: [])
    }

    @Test func readAgainSendsTheFileNow() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        _ = try write("Kündigung zum 31. März", "Verträge/Ku\u{0308}ndigung.txt", in: s.root)
        #expect(try await s.indexer.reread(path: "Verträge/Kündigung.txt", assistant: false) == .sent)
        // A text file: no OCR, so no page scans and no question about them.
        #expect(KnowledgeStubProtocol.requests == [Self.putPath])
        let put = try #require(KnowledgeStubProtocol.bodies("PUT").first)
        #expect(put["path"] as? String == "Verträge/Kündigung.txt" && put["pages"] as? [String] == ["Kündigung zum 31. März"])
        #expect(put["reread"] as? Bool == true && put["reader"] as? Int == 1 && put["scansChecked"] == nil)
        #expect(s.indexer.waiting == 0)

        // Not in the folder, no folder on this device: the original's errors (they offer Settings).
        await #expect(throws: KnowledgeOriginalError.notFound) {
            try await s.indexer.reread(path: "Weg.txt", assistant: false)
        }
        await s.indexer.unlink()
        await #expect(throws: KnowledgeOriginalError.noFolder) {
            try await s.indexer.reread(path: "Verträge/Kündigung.txt", assistant: false)
        }
    }

    @Test func readAllSendsEveryFileAgain() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        _ = try write("Kündigung zum 31. März", "Verträge/Ku\u{0308}ndigung.txt", in: s.root)
        _ = try write("Rechnung", "rechnung.txt", in: s.root)
        _ = try write("x", "Brief.pages", in: s.root)
        await s.indexer.run()
        #expect(KnowledgeStubProtocol.requests == [Self.manifestPath])

        // The server asks for nothing, yet every file is read and sent again, with `reread`.
        KnowledgeStubProtocol.reset()
        await s.indexer.readAll(summaries: false)
        let puts = KnowledgeStubProtocol.bodies("PUT")
        #expect(Set(puts.compactMap { $0["path"] as? String }) == ["Verträge/Kündigung.txt", "rechnung.txt"])
        #expect(puts.allSatisfy { $0["reread"] as? Bool == true })
        #expect(!KnowledgeStubProtocol.requests.contains(Self.cardsPath))
        #expect(s.indexer.unreadable == ["Brief.pages": .format])
        #expect(s.indexer.lastRun?.uploaded == 2 && s.indexer.phase == .idle)
        #expect(s.indexer.readingAll == nil)
        #expect(!FileManager.default.fileExists(atPath: s.data.appending(path: "read-all.json").path))

        // Once: the next run is an ordinary one again.
        KnowledgeStubProtocol.reset()
        await s.indexer.run()
        #expect(KnowledgeStubProtocol.requests == [Self.manifestPath])
    }

    private static let cardsPath = "POST /api/v1/families/f1/knowledge/cards"

    @Test func readAllGoesOnAfterALostConnectionAndARestart() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        _ = try write("Rechnung", "rechnung.txt", in: s.root)
        let jobFile = s.data.appending(path: "read-all.json")

        // Offline: the manifest fails, the job is kept on the disk.
        KnowledgeStubProtocol.offline = true
        await s.indexer.readAll(summaries: true)
        #expect(s.indexer.readingAll?.files == true && s.indexer.readingAll?.summaries == true)
        if case .failed = s.indexer.phase {} else { Issue.record("phase \(s.indexer.phase)") }
        #expect(await until { FileManager.default.fileExists(atPath: jobFile.path) })

        // The connection is back: every file read again, then every summary asked for.
        KnowledgeStubProtocol.reset()
        s.indexer.retryNow()
        #expect(await until { s.indexer.readingAll == nil })
        let put = try #require(KnowledgeStubProtocol.bodies("PUT").first)
        #expect(put["path"] as? String == "rechnung.txt" && put["reread"] as? Bool == true)
        #expect(KnowledgeStubProtocol.requests.last == Self.cardsPath)
        #expect(KnowledgeStubProtocol.bodies(Self.cardsPath).first?["all"] as? Bool == true)
        #expect(s.indexer.phase == .idle)
        #expect(await until { !FileManager.default.fileExists(atPath: jobFile.path) })

        // The app quit before the job was done: the next one picks it up at its first run.
        try KnowledgeReadAll.save(KnowledgeReadAll(summaries: false), to: jobFile)
        KnowledgeStubProtocol.reset()
        let next = KnowledgeIndexer(api: s.indexer.api, folder: s.indexer.folder, directory: s.data, deviceName: "Test Mac")
        await next.runIfDue()
        #expect(KnowledgeStubProtocol.bodies("PUT").first?["reread"] as? Bool == true)
        #expect(!KnowledgeStubProtocol.requests.contains(Self.cardsPath))
        #expect(next.readingAll == nil)
    }

    @Test func readAllAsksForTheSummariesOnceTheUploadsAreThrough() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        _ = try write("Rechnung", "rechnung.txt", in: s.root)
        // The upload fails for want of the server: no summaries yet, the bar's total kept.
        KnowledgeStubProtocol.putStatus = 503
        await s.indexer.readAll(summaries: true)
        #expect(s.indexer.readingAll == KnowledgeReadAll(files: false, summaries: true, total: 1))
        #expect(s.indexer.waiting == 1)
        #expect(!KnowledgeStubProtocol.requests.contains(Self.cardsPath))

        KnowledgeStubProtocol.putStatus = 202
        s.indexer.retryNow()
        #expect(await until { s.indexer.readingAll == nil })
        #expect(s.indexer.waiting == 0 && KnowledgeStubProtocol.requests.last == Self.cardsPath)
        #expect(s.indexer.phase == .idle)
    }

    @Test func readAgainTriesAFileThatFailedAndSaysWhy() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        _ = try write("not a pdf", "broken.pdf", in: s.root)
        _ = try write("x", "Brief.pages", in: s.root)
        KnowledgeStubProtocol.set { $0.upload = ["broken.pdf"] }
        await s.indexer.run()
        #expect(s.indexer.unreadable == ["broken.pdf": .failed])
        // Asked for: read again (not skipped as failed), and why it still can't be.
        #expect(try await s.indexer.reread(path: "broken.pdf", assistant: false) == .unreadable(.failed))
        #expect(try await s.indexer.reread(path: "Brief.pages", assistant: false) == .unreadable(.format))
        #expect(!KnowledgeStubProtocol.requests.contains(Self.putPath))
    }

    @Test func readAgainWithTheAssistantSendsEveryPage() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        try scannedPDF(twoPages: false).write(to: s.root.appending(path: "Brief.pdf"))
        // The family's setting off: an editor's explicit request sends the pages anyway.
        KnowledgeStubProtocol.set { $0.status = #"{"scans": true, "aiScans": false}"# }
        #expect(try await s.indexer.reread(path: "Brief.pdf", assistant: true) == .sent)
        #expect(KnowledgeStubProtocol.requests == [Self.statusPath, Self.putPath,
                                                   "PUT /api/v1/families/f1/knowledge/documents/d1/pages/1/scan"])
        let put = try #require(KnowledgeStubProtocol.bodies("PUT").first)
        #expect(put["reread"] as? Bool == true && put["reader"] as? Int == 2)
        #expect(put["scansChecked"] as? Bool == true)
        #expect((put["pages"] as? [String])?.first?.contains("Abschlag") == true)
        let scan = try #require(KnowledgeStubProtocol.scans.first)
        #expect(scan.contentType == "image/jpeg" && scan.body.starts(with: [0xFF, 0xD8]))
        #expect(scan.query.contains("force=1") && scan.query.contains("hash=\(put["hash"] as? String ?? "-")"))

        // The family's AI can't transcribe (not set up): the text only.
        KnowledgeStubProtocol.reset()
        KnowledgeStubProtocol.set { $0.status = #"{"scans": false, "aiScans": true}"# }
        #expect(try await s.indexer.reread(path: "Brief.pdf", assistant: true) == .sent)
        #expect(KnowledgeStubProtocol.requests == [Self.statusPath, Self.putPath])
        #expect(try #require(KnowledgeStubProtocol.bodies("PUT").first)["scansChecked"] == nil)
    }

    @Test func everyPageGoesToTheAssistantWhileTheSettingIsOn() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        try scannedPDF(twoPages: true).write(to: s.root.appending(path: "Brief.pdf"))
        KnowledgeStubProtocol.set {
            $0.upload = ["Brief.pdf"]
            $0.status = #"{"scans": true, "aiScans": true}"#
        }
        await s.indexer.run()
        #expect(try manifestFiles()["Brief.pdf"]?["reader"] as? Int == 2)
        // Every page, the one the device reads well too, without force.
        #expect(KnowledgeStubProtocol.requests == [Self.manifestPath, Self.statusPath, Self.putPath,
                                                   "PUT /api/v1/families/f1/knowledge/documents/d1/pages/1/scan",
                                                   "PUT /api/v1/families/f1/knowledge/documents/d1/pages/2/scan"])
        #expect(KnowledgeStubProtocol.scans.allSatisfy { !$0.query.contains("force") })
        #expect(try #require(KnowledgeStubProtocol.bodies("PUT").first)["scansChecked"] as? Bool == true)
        #expect(s.indexer.waiting == 0)
    }

    @Test func noPageScansWhileTheSettingIsOffOrRefused() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        try scannedPDF(twoPages: true).write(to: s.root.appending(path: "Brief.pdf"))
        KnowledgeStubProtocol.set {
            $0.upload = ["Brief.pdf"]
            $0.status = #"{"scans": true, "aiScans": false}"#
        }
        await s.indexer.run()
        #expect(KnowledgeStubProtocol.requests == [Self.manifestPath, Self.statusPath, Self.putPath])
        #expect(try #require(KnowledgeStubProtocol.bodies("PUT").first)["scansChecked"] == nil)

        // On, but the server refuses the page (an older server): dropped quietly.
        KnowledgeStubProtocol.reset()
        KnowledgeStubProtocol.set {
            $0.status = #"{"scans": true, "aiScans": true}"#
            $0.scan = 404
        }
        s.indexer.scanSettingChanged()
        #expect(try await s.indexer.reread(path: "Brief.pdf", assistant: false) == .sent)
        #expect(KnowledgeStubProtocol.scans.count == 1 && s.indexer.waiting == 0)
    }

    @Test func aPageScanOutageWaitsWithTheUpload() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        try scannedPDF(twoPages: false).write(to: s.root.appending(path: "Brief.pdf"))
        KnowledgeStubProtocol.set {
            $0.status = #"{"scans": true}"#
            $0.scan = 503
        }
        #expect(try await s.indexer.reread(path: "Brief.pdf", assistant: true) == .waiting)
        #expect(s.indexer.waiting == 1)
        KnowledgeStubProtocol.set { $0.scan = 202 }
        s.indexer.retryNow()
        #expect(await until { s.indexer.waiting == 0 })
        // Sent again with the text (the server keeps the same text as it is), then the page.
        #expect(KnowledgeStubProtocol.bodies("PUT").count == 2)
        #expect(KnowledgeStubProtocol.scans.count == 2)
    }

    @Test func removingTheFolderForgetsWhatTheDeviceKept() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        _ = try write("Text", "a.txt", in: s.root)
        KnowledgeStubProtocol.upload = ["a.txt"]
        KnowledgeStubProtocol.putStatus = 503
        await s.indexer.run()
        #expect(s.indexer.waiting == 1)
        #expect(FileManager.default.fileExists(atPath: s.data.appending(path: "hashes.json").path))
        await s.indexer.unlink()
        #expect(!s.indexer.folder.isLinked && s.indexer.waiting == 0 && s.indexer.lastRun == nil)
        #expect(s.indexer.phase == .idle)
        #expect(!FileManager.default.fileExists(atPath: s.data.appending(path: "queue.json").path))
        #expect(!FileManager.default.fileExists(atPath: s.data.appending(path: "hashes.json").path))
    }

    @Test func aScanIsQueuedWithItsText() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        let file = try write("%PDF scan", "2026-11-04_Brief.pdf", in: s.root)
        try await s.indexer.enqueue(file: file, pages: ["Seite eins", "Seite zwei"])
        #expect(await until { KnowledgeStubProtocol.requests.contains("PUT /api/v1/families/f1/knowledge/documents") })
        #expect(await until { s.indexer.waiting == 0 })
        let put = try #require(KnowledgeStubProtocol.bodies("PUT").first)
        #expect(put["path"] as? String == "2026-11-04_Brief.pdf" && put["pages"] as? [String] == ["Seite eins", "Seite zwei"])
        // The next run finds its hash in the cache.
        let cache = KnowledgeHashCache.load(s.data.appending(path: "hashes.json"))
        #expect(cache.entries["2026-11-04_Brief.pdf"]?.hash == put["hash"] as? String)
        // A file elsewhere isn't the folder's.
        let elsewhere = try folder()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        await #expect(throws: KnowledgeFolderError.notInFolder) {
            try await s.indexer.enqueue(file: try write("x", "x.pdf", in: elsewhere), pages: [])
        }
    }

    /// The scans' side as `FamilyContext.scanKnowledge` makes it, over this indexer.
    private func scanKnowledge(_ s: Setup) -> ScanKnowledge {
        let indexer = s.indexer
        return ScanKnowledge(state: { indexer.folder.state() },
                             enqueue: { try await indexer.enqueue(file: $0, pages: $1) },
                             tags: { await ScanKnowledge.serverTags(indexer.api.knowledgeTags()) })
    }

    @Test func aScanIsSavedIntoTheKnowledgeFolderAndUploadedWithItsText() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        let filing = ScanFiling(kind: .letter, settings: LetterFilingTests.settings(), knowledge: scanKnowledge(s))
        // The bookmark's URL: the same folder, perhaps spelled through /private.
        #expect(filing.inKnowledge && filing.folder.url?.resolvingSymlinksInPath().path == s.root.resolvingSymlinksInPath().path)
        #expect(!filing.needsFolder)
        filing.savesPDF = true
        filing.suggest(name: "2026-11-04 Brief", tags: ["Schule"])
        let pages = [
            ScanPage(image: LetterFilingTests.image(), lines: [
                ScanLine(text: "Liebe Eltern,", box: CGRect(x: 0.1, y: 0.7, width: 0.4, height: 0.03)),
                ScanLine(text: "Elternbrief", box: CGRect(x: 0.1, y: 0.85, width: 0.4, height: 0.03)),
            ]),
            ScanPage(image: LetterFilingTests.image(), lines: [
                ScanLine(text: "Rückseite", box: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.03)),
            ]),
        ]
        #expect(try await filing.save(pages) == "2026-11-04_Brief.pdf")
        // In the folder's root, tagged; queued with the scan's text (no second reading).
        let file = s.root.appending(path: "2026-11-04_Brief.pdf")
        #expect(FinderTags.read(file) == ["Schule"])
        #expect(await until { KnowledgeStubProtocol.requests.contains("PUT /api/v1/families/f1/knowledge/documents") })
        let put = try #require(KnowledgeStubProtocol.bodies("PUT").first)
        #expect(put["path"] as? String == "2026-11-04_Brief.pdf" && put["tags"] as? [String] == ["Schule"])
        #expect(put["pages"] as? [String] == ["Elternbrief\nLiebe Eltern,", "Rückseite"])
        #expect(await until { s.indexer.waiting == 0 })
    }

    @Test func aScanSavedOfflineWaitsInTheQueue() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        KnowledgeStubProtocol.offline = true
        let filing = ScanFiling(kind: .letter, settings: LetterFilingTests.settings(), knowledge: scanKnowledge(s))
        filing.savesPDF = true
        filing.suggest(name: "Brief")
        let page = ScanPage(image: LetterFilingTests.image(), lines: [
            ScanLine(text: "Hallo", box: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.05)),
        ])
        // Saving doesn't wait for the server.
        #expect(try await filing.save([page]) == "Brief.pdf")
        #expect(FileManager.default.fileExists(atPath: s.root.appending(path: "Brief.pdf").path))
        #expect(s.indexer.waiting == 1)
    }

    @Test func theServersTagsOrTheCopyOnTheDevice() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        let cache = ResponseCache(directory: s.data.appending(path: "responses", directoryHint: .isDirectory))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KnowledgeStubProtocol.self]
        let api = FamilyAPI(client: APIClient(baseURL: URL(string: "https://kb.example")!, token: nil,
                                              session: URLSession(configuration: config), cache: cache), familyID: "f1")
        KnowledgeStubProtocol.set { $0.tags = #"{"tags": [{"tag": "Versicherung", "count": 3}, {"tag": "Arzt", "count": 1}]}"# }
        #expect(await ScanKnowledge.serverTags(api.knowledgeTags()) == ["Versicherung", "Arzt"])
        #expect(KnowledgeStubProtocol.requests == ["GET /api/v1/families/f1/knowledge/tags"])
        ResponseCache.waitForWrites()
        KnowledgeStubProtocol.offline = true
        #expect(await ScanKnowledge.serverTags(api.knowledgeTags()) == ["Versicherung", "Arzt"])
        cache.clear()
        #expect(await ScanKnowledge.serverTags(api.knowledgeTags()).isEmpty)
    }

    private static let putPath = "PUT /api/v1/families/f1/knowledge/documents"

    @Test func aRunKeepsAScansTextWhenTheServerAsksForIt() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        // Saved offline: it waits with its text.
        KnowledgeStubProtocol.offline = true
        let file = try write("%PDF not really", "Scan.pdf", in: s.root)
        try await s.indexer.enqueue(file: file, pages: ["Gescannter Text"])
        #expect(await until { s.indexer.waiting == 1 && !KnowledgeStubProtocol.requests.isEmpty })
        KnowledgeStubProtocol.reset()
        KnowledgeStubProtocol.set { $0.upload = ["Scan.pdf"] }
        await s.indexer.run()
        // Sent with the scan's text, not read from the file again.
        let put = try #require(KnowledgeStubProtocol.bodies("PUT").first)
        #expect(put["path"] as? String == "Scan.pdf" && put["pages"] as? [String] == ["Gescannter Text"])
        #expect(s.indexer.unreadable.isEmpty && s.indexer.waiting == 0)
    }

    @Test func scansQueuedWhileAFlushRunsAreSentByIt() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        KnowledgeStubProtocol.set { $0.putDelay = 0.2 }
        try await s.indexer.enqueue(file: try write("a", "A.pdf", in: s.root), pages: ["A"])
        #expect(await until { KnowledgeStubProtocol.requests.contains(Self.putPath) })
        // While A's upload is under way: its flush takes B and C too.
        try await s.indexer.enqueue(file: try write("b", "B.pdf", in: s.root), pages: ["B"])
        try await Task.sleep(for: .milliseconds(250))
        try await s.indexer.enqueue(file: try write("c", "C.pdf", in: s.root), pages: ["C"])
        #expect(await until { s.indexer.waiting == 0 && KnowledgeStubProtocol.bodies("PUT").count == 3 })
        #expect(KnowledgeStubProtocol.bodies("PUT").compactMap { $0["path"] as? String } == ["A.pdf", "B.pdf", "C.pdf"])
    }

    @Test func aScanSavedDuringTheWalkIsInTheManifest() async throws {
        let s = try setup()
        defer { try? FileManager.default.removeItem(at: s.root); try? FileManager.default.removeItem(at: s.data) }
        _ = try write("Vertrag", "Vertrag.txt", in: s.root)
        let indexer = s.indexer, root = s.root
        indexer.walked = {
            indexer.walked = {}
            let scan = try! write("%PDF scan", "Scan.pdf", in: root)
            try? await indexer.enqueue(file: scan, pages: ["Brief"])
        }
        await indexer.run()
        let files = try manifestFiles()
        #expect(Set(files.keys) == ["Scan.pdf", "Vertrag.txt"])
        let hash = try #require(files["Scan.pdf"]?["hash"] as? String)
        // Its upload follows the manifest (the run's flush sends it).
        #expect(KnowledgeStubProtocol.requests == [Self.manifestPath, Self.putPath])
        #expect(KnowledgeStubProtocol.bodies("PUT").first?["pages"] as? [String] == ["Brief"])
        #expect(await until { FileManager.default.fileExists(atPath: s.data.appending(path: "hashes.json").path) })
        let cache = KnowledgeHashCache.load(s.data.appending(path: "hashes.json"))
        #expect(cache.entries["Scan.pdf"]?.hash == hash)
    }

    @Test func aScansTextIsntWrittenAfterSigningOut() throws {
        let data = try folder()
        defer { try? FileManager.default.removeItem(at: data) }
        let texts = data.appending(path: "family/texts", directoryHint: .isDirectory)
        let signOuts = KnowledgeDiskGate(), gate = KnowledgeDiskGate()
        #expect(try KnowledgeIndexer.writeText(["a"], name: "1.json", in: texts, signOutGate: signOuts,
                                               signOuts: 0, gate: gate, generation: 0))
        #expect(FileManager.default.fileExists(atPath: texts.appending(path: "1.json").path))
        try FileManager.default.removeItem(at: data.appending(path: "family"))
        // Signed out (or the folder chosen anew) meanwhile: the folder isn't made again.
        signOuts.bump()
        #expect(try !KnowledgeIndexer.writeText(["a"], name: "2.json", in: texts, signOutGate: signOuts,
                                                signOuts: 0, gate: gate, generation: 0))
        gate.bump()
        #expect(try !KnowledgeIndexer.writeText(["a"], name: "3.json", in: texts, signOutGate: signOuts,
                                                signOuts: 1, gate: gate, generation: 0))
        #expect(!FileManager.default.fileExists(atPath: data.appending(path: "family").path))
    }
}

/// Where a scan is filed: the knowledge folder while it's linked on this device, else the scan
/// folder; the tags it's suggested.
@MainActor
struct KnowledgeScanFilingTests {
    private func knowledge(_ state: KnowledgeFolder.State, tags: [String] = [],
                           enqueued: (([String]) -> Void)? = nil, asked: (() -> Void)? = nil) -> ScanKnowledge {
        ScanKnowledge(state: { state },
                      enqueue: { _, pages in enqueued?(pages) },
                      tags: { asked?(); return tags })
    }

    @Test func theKnowledgeFolderOnlyWhileItsLinked() throws {
        let root = try folder(), scans = try folder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: scans) }
        let settings = LetterFilingTests.settings()
        for state in [KnowledgeFolder.State.none, .missing, .replaced] {
            let filing = ScanFiling(kind: .letter, settings: settings, knowledge: knowledge(state))
            #expect(filing.folder == .none && !filing.inKnowledge)
            #expect(filing.needsFolder)
        }
        #expect(ScanFiling(kind: .letter, settings: settings).folder == .none)

        let linked = ScanFiling(kind: .receipt, settings: settings, knowledge: knowledge(.linked(url: root, folderID: "k1")))
        #expect(linked.folder == .knowledge(root) && linked.inKnowledge)
        #expect(linked.folder.url == root && linked.folderName == root.lastPathComponent)
        linked.savesPDF = true
        // No folder to choose.
        #expect(!linked.needsFolder)

        // A scan folder chosen before: used while the knowledge folder isn't linked.
        try settings.rememberFolder(scans)
        let fallback = ScanFiling(kind: .letter, settings: settings, knowledge: knowledge(.missing))
        #expect(fallback.folder.url != nil && !fallback.inKnowledge)
        #expect(ScanFiling(kind: .letter, settings: settings,
                           knowledge: knowledge(.linked(url: root, folderID: "k1"))).folder == .knowledge(root))
    }

    @Test func savesIntoTheRootWithoutOverwritingAndQueuesTheText() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = try write("old", "Brief.pdf", in: root)
        // An iCloud file that isn't on the device takes its name too.
        _ = try write("", ".Brief_2.pdf.icloud", in: root)
        var queued: [[String]] = []
        let filing = ScanFiling(kind: .letter, settings: LetterFilingTests.settings(),
                                knowledge: knowledge(.linked(url: root, folderID: "k1"), enqueued: { pages in
                                    // Saved before it's queued.
                                    #expect(FileManager.default.fileExists(atPath: root.appending(path: "Brief_3.pdf").path))
                                    queued.append(pages)
                                }))
        filing.savesPDF = true
        filing.suggest(name: "Brief")
        let page = ScanPage(image: LetterFilingTests.image(), lines: [
            ScanLine(text: "Hallo", box: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.05)),
        ])
        #expect(try await filing.save([page]) == "Brief_3.pdf")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "old")
        #expect(queued == [["Hallo"]])

        // A scan without any text isn't queued: the indexer reads the file when the server asks.
        let blank = ScanFiling(kind: .letter, settings: LetterFilingTests.settings(),
                               knowledge: knowledge(.linked(url: root, folderID: "k1"), enqueued: { queued.append($0) }))
        blank.savesPDF = true
        #expect(try await blank.save([ScanPage(image: LetterFilingTests.image(), lines: [])]) != nil)
        #expect(queued.count == 1)
    }

    @Test func tagsOfTheKnowledgeBaseAreSuggestedToo() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FinderTags.write(["Arzt"], to: try write("x", "Sub/a.pdf", in: root))
        let settings = LetterFilingTests.settings()
        settings.remember(tags: ["Schule"])
        let filing = ScanFiling(kind: .letter, settings: settings,
                                knowledge: knowledge(.linked(url: root, folderID: "k1"), tags: ["Versicherung", "arzt", "Schule"]))
        #expect(await filing.existingTags() == ["Schule", "Arzt", "Versicherung"])

        // In the scan folder the server isn't asked.
        var asked = false
        try settings.rememberFolder(root)
        let elsewhere = ScanFiling(kind: .letter, settings: settings,
                                   knowledge: knowledge(.none, tags: ["Versicherung"], asked: { asked = true }))
        #expect(await elsewhere.existingTags() == ["Schule", "Arzt"])
        #expect(!asked)
    }

    @Test func theFamilyFilesIntoTheKnowledgeFolderWhenItsLinkedHere() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let api = FamilyAPI(client: APIClient(baseURL: URL(string: "https://scan-\(UUID().uuidString).example")!, token: nil),
                            familyID: "f1")
        func context(_ role: FamilyRole, modules: [String] = ["calendar", "knowledge"]) -> FamilyContext {
            let context = FamilyContext(family: FamilySummary(id: "f1", name: "F", role: role, memberCount: 2), api: api)
            context.serverInfo = ServerInfo(name: "Ohana", version: "1", apiVersion: 1, modules: modules)
            return context
        }
        let link = KnowledgeFolder(location: KnowledgeLocation(server: api.client.baseURL, familyID: "f1"))
        defer { link.unlink() }
        #expect(context(.editor).scanKnowledge == nil)
        try link.remember(root, folderID: "k1")
        let linked = try #require(context(.editor).scanKnowledge?.folder)
        #expect(linked.url?.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path && linked == .knowledge(linked.url!))
        #expect(context(.viewer).scanKnowledge == nil)
        #expect(context(.editor, modules: ["calendar"]).scanKnowledge == nil)
    }

    @Test func aFolderChangedWhileTheSheetWasOpenIsTold() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = ScanPage(image: LetterFilingTests.image(), lines: [
            ScanLine(text: "Hallo", box: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.05)),
        ])
        for (error, told) in [(KnowledgeFolderError.missing, true), (.notInFolder, true), (.unreadable, false)] {
            var reported: [any Error] = []
            var knowledge = ScanKnowledge(state: { .linked(url: root, folderID: "k1") },
                                          enqueue: { _, _ in throw error })
            knowledge.report = { reported.append($0) }
            await knowledge.queue(root.appending(path: "x.pdf"), pages: [page])
            #expect(reported.compactMap { $0 as? ScanKnowledgeError } == (told ? [.folderChanged] : []))
            #expect(reported.count == (told ? 1 : 0))
        }
    }

    @Test func pageTextsInReadingOrder() {
        let page = ScanPage(image: LetterFilingTests.image(), lines: [
            ScanLine(text: "unten", box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.03)),
            ScanLine(text: "oben", box: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.03)),
        ])
        #expect(ScanKnowledge.texts([page, ScanPage(image: LetterFilingTests.image(), lines: [])]) == ["oben\nunten", ""])
    }
}
