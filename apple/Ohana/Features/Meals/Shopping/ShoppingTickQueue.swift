import Foundation
import Observation

/// Ticks of shopping items, shown at once and sent in the background: the app's version of the
/// web's offline queue (server/lib/offline). A tick that can't reach the server (offline, a server
/// error) stays queued — on disk too (`ShoppingOfflineStore`), so it survives quitting the app —
/// and is retried with growing pauses and when the connection comes back; one the server refuses
/// (the item is gone, no right to edit) is dropped and reported. Every tick is an idempotent "set"
/// (POST /shopping/toggle `{kind: "set", itemId, checked}`), so replaying one is harmless, and
/// only the latest wish per item is kept.
///
/// Items added while the server can't be reached wait here too (`pendingAdds`, after the ticks),
/// shown in their list until sent. Each carries a `clientId`, so the server applies it once even
/// when an answer is lost and it's sent again. The server wins: an add it refuses (the list was
/// made new, an unknown unit) is dropped and reported, and the list loads again.
///
/// One queue per family and server (`for(_:)`), so ticks survive leaving the screen.
@Observable
final class ShoppingTickQueue {
    typealias Sender = (_ itemID: String, _ checked: Bool) async throws -> Void
    typealias AddSender = (_ add: ShoppingPendingAdd) async throws -> Void

    /// Ticks not confirmed by the server yet: item id → checked. Saved to the store.
    private(set) var pending: [String: Bool] = [:] {
        didSet { if pending != oldValue { store?.saveTicks(pending) } }
    }
    /// Adds not sent yet, oldest first. Saved to the store.
    private(set) var pendingAdds: [ShoppingPendingAdd] = [] {
        didSet { if pendingAdds != oldValue { store?.saveAdds(pendingAdds) } }
    }
    /// Ticks the server confirmed since the list was last loaded: item id → checked.
    private(set) var confirmed: [String: Bool] = [:]
    /// Failed attempts in a row; > 0 while waiting to retry.
    private(set) var failures = 0
    /// A tick or add is on its way.
    private(set) var isSending = false
    /// The queued add on its way (it can't be taken back then).
    private(set) var sendingAddID: String?
    /// Counts the queued adds the server applied or refused: the list shown is out of date.
    private(set) var addsSettled = 0

    /// Called when the server refused a tick (the item shows its old state again).
    @ObservationIgnored var onRejected: ((_ itemID: String, _ error: any Error) -> Void)?
    /// Called when the server refused a queued add (it's gone from the list).
    @ObservationIgnored var onAddRejected: ((_ add: ShoppingPendingAdd, _ error: any Error) -> Void)?
    /// The pause before the n-th retry (1, 2, …).
    @ObservationIgnored var retryDelay: (Int) -> Duration = { n in .seconds(min(30, 1 << min(n, 5))) }

    @ObservationIgnored private let send: Sender
    @ObservationIgnored private let sendAdd: AddSender
    @ObservationIgnored private let store: ShoppingOfflineStore?
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    /// With a `store`, the ticks and adds it kept from last time are queued again.
    init(store: ShoppingOfflineStore? = nil, send: @escaping Sender, add: @escaping AddSender) {
        self.send = send
        sendAdd = add
        self.store = store
        pending = store?.loadTicks() ?? [:]
        pendingAdds = store?.loadAdds() ?? []
    }

    /// Ticks or adds wait for a retry: no connection, or the server didn't answer
    /// (`ShoppingSyncStatus` tells which by the device's connection).
    var isWaiting: Bool { failures > 0 && (!pending.isEmpty || !pendingAdds.isEmpty) }

    /// What an item shows: the latest tick, else the server's state.
    func isChecked(_ item: ShoppingItem) -> Bool {
        pending[item.id] ?? confirmed[item.id] ?? item.isChecked
    }

    /// The items with the ticks applied.
    func apply(to items: [ShoppingItem]) -> [ShoppingItem] {
        items.map { item in
            var item = item
            item.isChecked = isChecked(item)
            return item
        }
    }

    /// The adds waiting for a list.
    func pendingAdds(for listID: String) -> [ShoppingPendingAdd] {
        pendingAdds.filter { $0.listID == listID }
    }

    /// Fresh data from the server: confirmed ticks are in it now.
    func reconcile() {
        confirmed = [:]
    }

    /// Ticks (or unticks) an item and sends it.
    func set(_ itemID: String, checked: Bool) {
        pending[itemID] = checked
        Task { await flush() }
    }

    /// Adds an item. With `sendNow` (and nothing waiting before it) it goes out at once, as
    /// online; if the server can't be reached it's queued instead. Throws only when the server
    /// refused it (nothing is queued then). True: the server has it.
    @discardableResult
    func add(_ add: ShoppingPendingAdd, sendNow: Bool = true) async throws -> Bool {
        guard sendNow, pendingAdds.isEmpty, !isWaiting else {
            pendingAdds.append(add)
            retryNow()
            return false
        }
        do {
            try await sendAdd(add)
            failures = 0
            return true
        } catch where Self.isRetryable(error) {
            // Maybe it got there: the clientId keeps a second send from adding it twice.
            pendingAdds.append(add)
            failures += 1
            scheduleRetry()
            return false
        }
    }

    /// Takes back a queued add not on its way yet. False: too late.
    @discardableResult
    func removeAdd(_ id: String) -> Bool {
        guard sendingAddID != id else { return false }
        pendingAdds.removeAll { $0.id == id }
        return true
    }

    /// Sends what is queued now (e.g. after pulling to refresh).
    func retryNow() {
        retryTask?.cancel()
        retryTask = nil
        Task { await flush() }
    }

    /// Sends the queued ticks one by one, then the adds, until none is left or the connection fails.
    func flush() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false; isSending = false; sendingAddID = nil }
        while let next = pending.first {
            let id = next.key, wanted = next.value
            isSending = true
            do {
                try await send(id, wanted)
                confirmed[id] = wanted
                if pending[id] == wanted { pending[id] = nil }
                failures = 0
            } catch where Self.isRetryable(error) {
                failures += 1
                scheduleRetry()
                return
            } catch {
                if pending[id] == wanted { pending[id] = nil }
                confirmed[id] = nil
                onRejected?(id, error)
            }
        }
        while let next = pendingAdds.first {
            isSending = true
            sendingAddID = next.id
            do {
                try await sendAdd(next)
                pendingAdds.removeAll { $0.id == next.id }
                failures = 0
                addsSettled += 1
            } catch where Self.isRetryable(error) {
                failures += 1
                scheduleRetry()
                return
            } catch {
                pendingAdds.removeAll { $0.id == next.id }
                addsSettled += 1
                onAddRejected?(next, error)
            }
            sendingAddID = nil
        }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        let delay = retryDelay(failures)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Worth trying again: no connection, a timeout, a server error, too many requests.
    static func isRetryable(_ error: any Error) -> Bool {
        APIError.isTemporary(error)
    }

    // MARK: One per family

    private static var queues: [String: ShoppingTickQueue] = [:]

    /// The family's queue, sending through `api`.
    static func `for`(_ api: FamilyAPI) -> ShoppingTickQueue {
        let key = "\(ObjectIdentifier(api.client).hashValue)|\(api.familyID)"
        if let queue = queues[key] { return queue }
        let queue = ShoppingTickQueue(store: ShoppingOfflineStore(api: api)) { itemID, checked in
            try await api.perform(.post, "/shopping/toggle", body: ShoppingSetInput(itemId: itemID, checked: checked))
        } add: { add in
            let _: ShoppingAddItemResult = try await api.send(.post, "/meals/shopping/lists/\(add.listID)/items",
                                                              body: add.input)
        }
        queue.onRejected = { _, error in ErrorBanner.shared.show(error) }
        queue.onAddRejected = { _, error in ErrorBanner.shared.show(error) }
        queues[key] = queue
        let connectivity = Connectivity.shared
        connectivity.start()
        connectivity.whenReconnected { [weak queue] in queue?.retryNow() }
        // Ticks and adds kept from last time go out now.
        if !queue.pending.isEmpty || !queue.pendingAdds.isEmpty { queue.retryNow() }
        return queue
    }
}
