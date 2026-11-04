import Foundation
import Network
import Observation

/// Whether the device has a connection (the web's `navigator.onLine`): queues send what they
/// hold when it comes back, screens showing their copy on the device (`LoadState.saved`) load
/// again. Started when the app starts.
@Observable
final class Connectivity {
    static let shared = Connectivity()

    private(set) var isOnline = true
    /// Low Data Mode (or a network that asks for it): nothing is loaded ahead (`Prefetcher`).
    private(set) var isConstrained = false
    /// A network that costs (cellular, a personal hotspot): the knowledge base loads no iCloud
    /// files over it on iOS (`KnowledgeDownloads`).
    private(set) var isExpensive = false
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var onReconnect: [() -> Void] = []

    private init() {}

    /// Starts watching (once).
    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            let constrained = path.isConstrained, expensive = path.isExpensive
            Task { @MainActor in Connectivity.shared.update(online, constrained: constrained, expensive: expensive) }
        }
        monitor.start(queue: DispatchQueue(label: "ohana.connectivity"))
        self.monitor = monitor
    }

    /// Called every time the connection comes back.
    func whenReconnected(_ action: @escaping () -> Void) {
        onReconnect.append(action)
    }

    private func update(_ online: Bool, constrained: Bool, expensive: Bool) {
        if constrained != isConstrained { isConstrained = constrained }
        if expensive != isExpensive { isExpensive = expensive }
        guard online != isOnline else { return }
        isOnline = online
        if online { onReconnect.forEach { $0() } }
    }
}
