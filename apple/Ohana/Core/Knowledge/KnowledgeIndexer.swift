import Foundation
import Observation

/// Reads the family's knowledge folder on this device into the server's index: walks the folder
/// (`KnowledgeWalker`), hashes what changed since last time (`KnowledgeHashCache`), sends the
/// manifest, then reads (`KnowledgeText`) and uploads the files the server asks for, through a
/// queue kept on the device (`KnowledgeUploadQueue`). One per family (`FamilyContext.knowledge`);
/// one run at a time, a run asked for meanwhile follows it once. Runs at launch, when the app is
/// active again, every 15 minutes on the Mac, and when asked (Settings → Knowledge, a scan).
///
/// Nothing runs again by itself: a file that changed while it was read waits for the next run.
/// Choosing another folder or removing it (`link`, `unlink`) stops what runs (a new generation:
/// the old run writes nothing more). The hash cache and the queue are read and written off the
/// main actor, in order (`onDisk`); the queue at most every `queueSaveDelay` while it changes.
///
/// Its parts live in the `KnowledgeIndexer…` files beside this one (its run, its hashes, its
/// folder, its uploads and its files on the disk), so what they write is `internal(set)` and
/// what they call is internal rather than private.
@Observable
final class KnowledgeIndexer {
    enum Phase: Equatable {
        case idle
        /// Listing the folder.
        case scanning
        /// Hashing the files that changed (and loading those iCloud keeps off the device).
        case hashing(done: Int, of: Int)
        /// Reading and uploading what the server asked for.
        case uploading(done: Int, of: Int)
        case failed(String)
    }

    /// What the last finished run did.
    struct Run: Equatable {
        var finished: Date
        /// Files in the folder (in the manifest); 0: the folder looked empty and nothing was sent.
        var files: Int
        /// Uploaded by this run's flush (scans queued meanwhile among them; what a flush already
        /// under way when the run got there sent counts there, not here).
        var uploaded: Int = 0
        /// Left out for their size.
        var tooLarge: Int = 0
        /// Couldn't be hashed (iCloud couldn't load them): listed with their last hash, else none.
        var unhashable: Int = 0
        /// Not on the device and not loaded this run (iOS: Low Data Mode, a cellular network, the
        /// run's budget): listed with their last hash, else none; a later run loads them.
        var deferred: Int = 0
    }

    /// Why a file the server asked for wasn't sent from this device.
    enum Unreadable: Equatable {
        /// A format this device doesn't read (another device may).
        case format
        /// Its text couldn't be read (a locked PDF, OCR failing): not tried again until it changes.
        case failed

        var reason: String {
            switch self {
            case .format: String(localized: "This device can’t read this format.")
            case .failed: String(localized: "Its text couldn’t be read (a locked PDF, or text recognition failed).")
            }
        }
    }

    let api: FamilyAPI
    let folder: KnowledgeFolder
    /// Where the hash cache, the queue and queued texts are kept (`KnowledgeLocation.directory`).
    let directory: URL
    /// What the manifest calls this device.
    var deviceName: String
    /// When iCloud may load files for a run (the tests set their own).
    @ObservationIgnored var downloads: () -> KnowledgeDownloads = { KnowledgeDownloads.current() }
    /// Tests: what happens between a run's walk and its hashing (a scan saved meanwhile).
    @ObservationIgnored var walked: () async -> Void = {}

    internal(set) var phase: Phase = .idle
    internal(set) var lastRun: Run?
    /// Files the server asked for that this device didn't send, and why; by path.
    internal(set) var unreadable: [String: Unreadable] = [:]
    /// Uploads waiting (or being sent).
    internal(set) var waiting = 0
    /// *Read All* until it's done (`readAll`): its files still to read, its summaries still to ask
    /// for. Kept on the disk; resumed by the next run, a retry or the connection coming back.
    internal(set) var readingAll: KnowledgeReadAll?
    /// Settings → Knowledge's one progress bar, kept here so it keeps its total while the
    /// settings are closed (the settings update it with each status).
    var work = KnowledgeWorkProgress()

    @ObservationIgnored var queue = KnowledgeUploadQueue()
    @ObservationIgnored var queueLoaded = false
    /// `finishReadAll` is asking for the summaries.
    @ObservationIgnored var finishingReadAll = false
    @ObservationIgnored var cache = KnowledgeHashCache()
    @ObservationIgnored var cacheLoaded = false
    @ObservationIgnored var runTask: Task<Void, Never>?
    @ObservationIgnored var runID: UUID?
    @ObservationIgnored var runAgain = false
    /// The scans queued (`enqueue`) since the running run started its walk, by path: listed in its
    /// manifest even when the walk missed them. nil while no run walks.
    @ObservationIgnored var scansDuringRun: [String: Hashed]?
    @ObservationIgnored var lastStart: Date?
    /// The generation a flush is under way for.
    @ObservationIgnored var flushingGeneration: Int?
    @ObservationIgnored var retryDelay: Double = 2
    /// The server's word on page images (`scanStatus`), and when it was asked.
    @ObservationIgnored var scanStatusCache: (status: KnowledgeScanStatus, at: Date)?
    @ObservationIgnored var retryWait: Task<Void, Never>?
    @ObservationIgnored var queueSave: Task<Void, Never>?
    /// The disk work, one after the other.
    @ObservationIgnored var diskChain: Task<Void, Never>?
    /// Grows when the folder is chosen anew or removed: what an older run would still do is void.
    @ObservationIgnored let gate = KnowledgeDiskGate()
    /// `removeAll` ran since this indexer was made (signed out): it sends and keeps nothing more.
    @ObservationIgnored let signOuts: Int

    /// Automatic runs (launch, active, the Mac's timer) at most this often; *Read now* and scans
    /// run at once.
    static var minimumInterval: TimeInterval = 5 * 60
    /// Files hashed at a time (each may first be loaded from iCloud, off the main actor).
    static let hashingWidth = 3
    static let maxRetryDelay: Double = 120
    /// The queue is written at most this often while it changes (and when a flush ends).
    static var queueSaveDelay = Duration.seconds(2)
    /// Whether the server takes page images is asked again after this long.
    static var scanStatusAge: TimeInterval = 5 * 60

    init(api: FamilyAPI, folder: KnowledgeFolder, directory: URL, deviceName: String = AppModel.deviceName) {
        self.api = api
        self.folder = folder
        self.directory = directory
        self.deviceName = deviceName
        signOuts = KnowledgeDiskGate.signOuts.current
        Connectivity.shared.whenReconnected { [weak self] in self?.retryNow() }
        Task { [weak self] in await self?.ensureQueue() }
    }

    /// The indexer of `api`'s family, its files under Application Support.
    convenience init(api: FamilyAPI) {
        let location = KnowledgeLocation(server: api.client.baseURL, familyID: api.familyID)
        self.init(api: api, folder: KnowledgeFolder(location: location), directory: location.directory())
    }

    var isRunning: Bool { runTask != nil }

    var hashesFile: URL { directory.appending(path: "hashes.json") }
    var queueFile: URL { directory.appending(path: "queue.json") }
    var readAllFile: URL { directory.appending(path: "read-all.json") }
    var textsFolder: URL { directory.appending(path: "texts", directoryHint: .isDirectory) }
    var closed: Bool { signOuts != KnowledgeDiskGate.signOuts.current }

    /// Still the generation `generation` (not signed out, the folder not chosen anew or removed).
    func isCurrent(_ generation: Int) -> Bool {
        !closed && gate.current == generation
    }
}

/// A counter the indexer's disk work checks before it writes: it runs only while the counter is
/// what it was when the work was asked for (`run(at:)` holds the lock, so a `bump` waits for it).
nonisolated final class KnowledgeDiskGate: @unchecked Sendable {
    /// Grows with every sign-out (`KnowledgeIndexer.removeAll`).
    static let signOuts = KnowledgeDiskGate()

    private let lock = NSLock()
    private var value = 0

    var current: Int { lock.withLock { value } }

    func bump() {
        lock.withLock { value += 1 }
    }

    func run(at expected: Int, _ work: () -> Void) {
        lock.withLock { if value == expected { work() } }
    }
}

nonisolated enum KnowledgeIndexError: LocalizedError, Equatable {
    case tooManyFiles
    /// A folder in the knowledge folder (or itself) couldn't be listed: nothing was sent.
    case unlistable(String)

    var errorDescription: String? {
        switch self {
        case .tooManyFiles:
            String(localized: "The knowledge folder holds more than 20,000 files. Choose a folder with fewer.")
        case let .unlistable(folder):
            String(localized: "Ohana can’t open the folder “\(folder)”, so nothing was sent. It’s tried again next time.")
        }
    }
}
