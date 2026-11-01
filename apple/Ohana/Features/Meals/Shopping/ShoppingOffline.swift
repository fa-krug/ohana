import Foundation
import Observation
import SwiftUI

/// What the shopping lists keep on the device, per server and family, so they work in the shop
/// without a connection (the app's version of the web's IndexedDB queue and the service
/// worker's page cache, server/lib/offline and public/sw.js): the ticks and adds not sent yet, and the
/// lists as last loaded (shown at once on a cold start, and read-only while offline). Files under
/// Application Support:
/// `Ohana/Shopping/<server>_<family>/`.
struct ShoppingOfflineStore {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// The store of a family on a server.
    init(api: FamilyAPI) {
        directory = Self.base.appending(path: Self.safe(Self.prefix(api.client.baseURL) + api.familyID),
                                        directoryHint: .isDirectory)
    }

    private static var base: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Ohana/Shopping", directoryHint: .isDirectory)
    }

    private static func prefix(_ server: URL) -> String {
        "\(server.host() ?? "server")\(server.port.map { "-\($0)" } ?? "")_"
    }

    /// Signing out: every family's store on `server` is removed (the ticks, too).
    static func removeAll(server: URL) {
        let prefix = safe(prefix(server))
        let folders = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// A file name of letters, digits, dots and dashes.
    static func safe(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "-" })
    }

    private var ticksFile: URL { directory.appending(path: "ticks.json") }
    private var addsFile: URL { directory.appending(path: "adds.json") }
    private var overviewFile: URL { directory.appending(path: "overview.json") }
    private func listFile(_ id: String) -> URL { directory.appending(path: "list-\(Self.safe(id)).json") }

    // MARK: Ticks

    /// The ticks waiting to be sent: item id → checked.
    func loadTicks() -> [String: Bool] {
        read([String: Bool].self, from: ticksFile) ?? [:]
    }

    func saveTicks(_ ticks: [String: Bool]) {
        if ticks.isEmpty {
            try? FileManager.default.removeItem(at: ticksFile)
        } else {
            write(ticks, to: ticksFile)
        }
    }

    // MARK: Adds

    /// The adds waiting to be sent, oldest first.
    func loadAdds() -> [ShoppingPendingAdd] {
        read([ShoppingPendingAdd].self, from: addsFile) ?? []
    }

    func saveAdds(_ adds: [ShoppingPendingAdd]) {
        if adds.isEmpty {
            try? FileManager.default.removeItem(at: addsFile)
        } else {
            write(adds, to: addsFile)
        }
    }

    // MARK: Lists

    func saveOverview(_ overview: ShoppingOverview) {
        write(overview, to: overviewFile)
        if let latest = overview.latest { saveList(latest) }
    }

    func loadOverview() -> ShoppingOverview? {
        read(ShoppingOverview.self, from: overviewFile)
    }

    /// The overview as last loaded, and when.
    func savedOverview() -> Saved<ShoppingOverview>? {
        saved(ShoppingOverview.self, from: overviewFile)
    }

    func saveList(_ list: ShoppingList) {
        write(list, to: listFile(list.id))
    }

    func loadList(_ id: String) -> ShoppingList? {
        read(ShoppingList.self, from: listFile(id))
    }

    /// A list as last loaded, and when.
    func savedList(_ id: String) -> Saved<ShoppingList>? {
        saved(ShoppingList.self, from: listFile(id))
    }

    /// Lists no longer among the family's are removed.
    func prune(keeping ids: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let keep = Set(ids.map { "list-\(Self.safe($0)).json" })
        for file in files where file.lastPathComponent.hasPrefix("list-") && !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Files

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func saved<T: Decodable>(_ type: T.Type, from url: URL) -> Saved<T>? {
        guard let value = read(type, from: url) else { return nil }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return Saved(value: value, date: date ?? .distantPast)
    }

    private func write(_ value: some Encodable, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            // Only a convenience: the server keeps the real state.
        }
    }
}

/// What the bar above a shopping list says.
enum ShoppingSyncStatus: Equatable {
    /// The device has no connection.
    case offline
    /// The device is connected, but the server doesn't answer (down, a server error, a timeout).
    case serverUnreachable
    /// Sending what was ticked meanwhile.
    case syncing

    /// Nil: all is sent, nothing to say. `waiting`: ticks wait for a retry; `savedCopy`: the list
    /// shown is the copy kept on the device, as the server couldn't be reached.
    static func current(isOnline: Bool, waiting: Bool, savedCopy: Bool, sending: Bool) -> ShoppingSyncStatus? {
        if !isOnline { return .offline }
        if waiting || savedCopy { return .serverUnreachable }
        return sending ? .syncing : nil
    }
}

/// The bar above a shopping list while offline, while the server can't be reached, or while
/// sending what was ticked or added meanwhile (the web's offline-indicator.tsx).
struct ShoppingOfflineBanner: View {
    let queue: ShoppingTickQueue
    /// The list shown is the copy kept on the device.
    var showsSavedCopy = false
    @State private var connectivity = Connectivity.shared

    private var status: ShoppingSyncStatus? {
        .current(isOnline: connectivity.isOnline, waiting: queue.isWaiting, savedCopy: showsSavedCopy,
                 sending: queue.isSending)
    }

    var body: some View {
        Group {
            switch status {
            case .offline:
                bar(tint: .orange) {
                    problem(Text("You’re offline — changes will sync when you reconnect."), systemImage: "wifi.slash")
                }
            case .serverUnreachable:
                bar(tint: .orange) {
                    problem(Text("Can’t reach the server — changes will sync once it answers again."),
                            systemImage: "exclamationmark.icloud")
                }
            case .syncing:
                bar(tint: ModuleTint.meals) {
                    Label {
                        Text("Syncing your changes…")
                    } icon: {
                        ProgressView().controlSize(.small)
                    }
                }
            case nil:
                EmptyView()
            }
        }
        .animation(.snappy, value: status)
    }

    private func problem(_ text: Text, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                text
                if showsSavedCopy {
                    Text("Showing the list as it was last loaded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !queue.pendingAdds.isEmpty {
                    Text("New items show a clock until they’re sent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }

    private func bar(tint: Color, @ViewBuilder content: () -> some View) -> some View {
        content()
            .font(.footnote.weight(.medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular.tint(tint.opacity(0.3)), in: .rect(cornerRadius: 16))
            .accessibilityElement(children: .combine)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
