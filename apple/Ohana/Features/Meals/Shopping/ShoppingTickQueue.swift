import Foundation
import Observation

/// Ticks of shopping items, shown at once and sent in the background: the app's version of the
/// web's offline queue (web/lib/offline). A tick that can't reach the server (offline, a server
/// error) stays queued in memory and is retried with growing pauses; one the server refuses (the
/// item is gone, no right to edit) is dropped and reported. Every tick is an idempotent "set"
/// (POST /shopping/toggle `{kind: "set", itemId, checked}`), so replaying one is harmless, and
/// only the latest wish per item is kept.
///
/// One queue per family and server (`for(_:)`), so ticks survive leaving the screen.
@Observable
final class ShoppingTickQueue {
    typealias Sender = (_ itemID: String, _ checked: Bool) async throws -> Void

    /// Ticks not confirmed by the server yet: item id → checked.
    private(set) var pending: [String: Bool] = [:]
    /// Ticks the server confirmed since the list was last loaded: item id → checked.
    private(set) var confirmed: [String: Bool] = [:]
    /// Failed attempts in a row; > 0 while waiting to retry.
    private(set) var failures = 0

    /// Called when the server refused a tick (the item shows its old state again).
    @ObservationIgnored var onRejected: ((_ itemID: String, _ error: any Error) -> Void)?
    /// The pause before the n-th retry (1, 2, …).
    @ObservationIgnored var retryDelay: (Int) -> Duration = { n in .seconds(min(30, 1 << min(n, 5))) }

    @ObservationIgnored private let send: Sender
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    init(send: @escaping Sender) {
        self.send = send
    }

    /// Ticks are waiting for the connection.
    var isWaiting: Bool { failures > 0 && !pending.isEmpty }

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

    /// Fresh data from the server: confirmed ticks are in it now.
    func reconcile() {
        confirmed = [:]
    }

    /// Ticks (or unticks) an item and sends it.
    func set(_ itemID: String, checked: Bool) {
        pending[itemID] = checked
        Task { await flush() }
    }

    /// Sends what is queued now (e.g. after pulling to refresh).
    func retryNow() {
        retryTask?.cancel()
        retryTask = nil
        Task { await flush() }
    }

    /// Sends the queued ticks one by one until none is left, or the connection fails.
    func flush() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        while let next = pending.first {
            let id = next.key, wanted = next.value
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
        switch error {
        case is URLError, is CancellationError: true
        case APIError.transport: true
        case let APIError.http(status, _): status >= 500 || status == 408 || status == 429
        default: false
        }
    }

    // MARK: One per family

    private static var queues: [String: ShoppingTickQueue] = [:]

    /// The family's queue, sending through `api`.
    static func `for`(_ api: FamilyAPI) -> ShoppingTickQueue {
        let key = "\(ObjectIdentifier(api.client).hashValue)|\(api.familyID)"
        if let queue = queues[key] { return queue }
        let queue = ShoppingTickQueue { itemID, checked in
            try await api.perform(.post, "/shopping/toggle", body: ShoppingSetInput(itemId: itemID, checked: checked))
        }
        queue.onRejected = { _, error in ErrorBanner.shared.show(error) }
        queues[key] = queue
        return queue
    }
}
