import SwiftUI

/// What a screen loads: nothing yet, in flight, there, the copy kept on the device, or failed
/// with a message.
enum LoadState<Value> {
    case idle
    case loading
    case loaded(Value)
    /// The copy kept on the device (`CachedGet.saved()`) from `date`, shown until the server
    /// answers: `updating` while it's asked, false once it couldn't be reached.
    case saved(Value, date: Date, updating: Bool)
    case failed(String)

    var value: Value? {
        switch self {
        case let .loaded(v), let .saved(v, _, _): v
        default: nil
        }
    }

    var isLoading: Bool {
        if case .loading = self { true } else { false }
    }

    /// What's shown is the copy on the device, not the server's latest: changes wait.
    var isSaved: Bool {
        if case .saved = self { true } else { false }
    }
}

extension LoadState {
    /// Runs `load`, keeping the old value on screen while reloading. With nothing on screen yet
    /// the copy on the device (`saved`) shows meanwhile, and stays when the server can't be
    /// reached.
    static func run(_ state: Binding<LoadState<Value>>, saved: () -> Saved<Value>? = { nil },
                    _ load: () async throws -> Value) async {
        switch state.wrappedValue {
        case .loaded:
            break
        case let .saved(value, date, _):
            state.wrappedValue = .saved(value, date: date, updating: true)
        case .idle, .loading, .failed:
            if let copy = saved() {
                state.wrappedValue = .saved(copy.value, date: copy.date, updating: true)
            } else {
                state.wrappedValue = .loading
            }
        }
        do {
            state.wrappedValue = .loaded(try await load())
        } catch is CancellationError {
            // The next load (a new task of the view) takes over.
        } catch {
            state.wrappedValue = state.wrappedValue.failing(error)
        }
    }

    /// Loads a GET kept on the device, made into what the screen shows.
    static func run<Answer>(_ state: Binding<LoadState<Value>>, _ get: CachedGet<Answer>,
                            _ transform: (Answer) -> Value) async {
        await run(state, saved: { get.saved().map { Saved(value: transform($0.value), date: $0.date) } }) {
            transform(try await get.fetch())
        }
    }

    /// The state after a load failed: the copy on the device stays while the failure may pass
    /// (offline, the server down), a value from the server stays with the error in the banner.
    func failing(_ error: any Error) -> LoadState {
        switch self {
        case let .saved(value, date, _):
            if APIError.isTemporary(error) {
                return .saved(value, date: date, updating: false)
            }
            return .failed(error.localizedDescription)
        case .loaded:
            ErrorBanner.shared.show(error)
            return self
        case .idle, .loading, .failed:
            return .failed(error.localizedDescription)
        }
    }
}

extension LoadState where Value: Decodable {
    /// Loads a GET kept on the device.
    static func run(_ state: Binding<LoadState<Value>>, _ get: CachedGet<Value>) async {
        await run(state, saved: get.saved, get.fetch)
    }
}

/// Shows a `LoadState`: a spinner, the failure with a retry, or the content — with
/// `SavedCopyBadge` over it while it's the copy on the device.
struct LoadStateView<Value, Content: View>: View {
    let state: LoadState<Value>
    var retry: (() async -> Void)?
    @ViewBuilder var content: (Value) -> Content

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn’t load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                if let retry {
                    Button("Try again") { Task { await retry() } }
                        .buttonStyle(.glassProminent)
                }
            }
        case let .loaded(value):
            content(value)
        case let .saved(value, date, updating):
            content(value)
                .overlay(alignment: .topTrailing) {
                    SavedCopyBadge(date: date, updating: updating, retry: retry)
                }
        }
    }
}

/// The quiet sign over a screen showing its copy on the device: "Updating…" while the server is
/// asked (only after a moment, so a quick answer shows nothing), then that it's offline or the
/// server can't be reached, and from when the copy is. A tap tries again; so does the connection
/// coming back.
struct SavedCopyBadge: View {
    let date: Date
    let updating: Bool
    var retry: (() async -> Void)?
    @State private var connectivity = Connectivity.shared
    @State private var showsUpdating = false

    var body: some View {
        Group {
            if updating {
                if showsUpdating {
                    Label {
                        Text("Updating…")
                    } icon: {
                        ProgressView().controlSize(.mini)
                    }
                    .badgeStyle()
                }
            } else {
                Button {
                    if let retry { Task { await retry() } }
                } label: {
                    Label(problem, systemImage: connectivity.isOnline ? "exclamationmark.icloud" : "wifi.slash")
                        .badgeStyle()
                }
                .buttonStyle(.plain)
                .disabled(retry == nil)
                .accessibilityHint(retry == nil ? "" : String(localized: "Tries again"))
            }
        }
        .padding(8)
        .animation(.snappy, value: updating)
        .animation(.snappy, value: showsUpdating)
        .task(id: updating) {
            showsUpdating = false
            guard updating else { return }
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { showsUpdating = true }
        }
        .onChange(of: connectivity.isOnline) { _, online in
            if online, !updating, let retry { Task { await retry() } }
        }
    }

    private var problem: String {
        let time = date.formatted(Calendar.current.isDateInToday(date)
                                  ? .dateTime.hour().minute() : .dateTime.day().month().hour().minute())
        return connectivity.isOnline
            ? String(localized: "Server unreachable · as of \(time)")
            : String(localized: "Offline · as of \(time)")
    }
}

private extension View {
    func badgeStyle() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
            .transition(.opacity)
    }
}

/// Errors of actions (saving, deleting) shown as a glass banner at the top of the window, and
/// short confirmations ("Saved.") with `success(_:)`. Sheets show it too when their content
/// has `.errorBanner()`.
@Observable
final class ErrorBanner {
    static let shared = ErrorBanner()
    private(set) var message: String?
    private(set) var isSuccess = false
    private var hideTask: Task<Void, Never>?

    func show(_ error: any Error) {
        if error is CancellationError { return }
        show(error.localizedDescription)
    }

    func show(_ text: String) {
        present(text, success: false)
    }

    /// A confirmation, e.g. `ErrorBanner.shared.success(String(localized: "Test message sent."))`.
    func success(_ text: String) {
        present(text, success: true)
    }

    private func present(_ text: String, success: Bool) {
        message = text
        isSuccess = success
        // VoiceOver reads it out; errors get a higher priority than confirmations.
        var announcement = AttributedString(text)
        announcement.accessibilitySpeechAnnouncementPriority = success ? .default : .high
        AccessibilityNotification.Announcement(announcement).post()
        hideTask?.cancel()
        // Errors stay until dismissed while VoiceOver runs, and longer than confirmations.
        if !success, Self.voiceOverRunning { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(success ? 4 : 8))
            if !Task.isCancelled { message = nil }
        }
    }

    private static var voiceOverRunning: Bool {
        #if os(iOS)
        UIAccessibility.isVoiceOverRunning
        #else
        NSWorkspace.shared.isVoiceOverEnabled
        #endif
    }

    func dismiss() { message = nil }
}

/// Runs an action, showing its error in the banner. For buttons: `Button { perform { … } }`.
func perform(_ action: @escaping () async throws -> Void) {
    Task {
        do { try await action() } catch { ErrorBanner.shared.show(error) }
    }
}

struct ErrorBannerOverlay: ViewModifier {
    @State private var banner = ErrorBanner.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message = banner.message {
                HStack(spacing: 10) {
                    Image(systemName: banner.isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(banner.isSuccess ? .green : .red)
                    Text(message).font(.callout)
                    Button { banner.dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular.tint((banner.isSuccess ? Color.green : .red).opacity(0.15)), in: .capsule)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: banner.message)
    }
}

/// The banner for content that is a sheet only on compact width (an inspector): elsewhere the
/// window's own banner shows above it already.
struct CompactErrorBanner: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        if sizeClass == .compact {
            content.modifier(ErrorBannerOverlay())
        } else {
            content
        }
    }
}

extension View {
    func errorBanner() -> some View { modifier(ErrorBannerOverlay()) }
    func errorBannerWhenCompact() -> some View { modifier(CompactErrorBanner()) }
}
