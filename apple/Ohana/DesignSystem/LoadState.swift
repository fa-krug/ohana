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

    /// The copy on the device after the server couldn't be reached: worth loading again once
    /// the connection is back.
    var isStale: Bool {
        if case .saved(_, _, false) = self { true } else { false }
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
    /// (offline, the server down; silently, unless the server answered with an error), a value
    /// from the server stays with the error in the banner.
    func failing(_ error: any Error) -> LoadState {
        switch self {
        case let .saved(value, date, _):
            if APIError.isTemporary(error) {
                ErrorBanner.shared.showUnlessUnreachable(error)
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

/// Shows a `LoadState`: a spinner, the failure with a retry, or the content — the copy on the
/// device just like the server's, loaded again when the connection comes back.
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
        case let .saved(value, _, _):
            content(value)
                .reloadsWhenReconnected(stale: state.isStale, retry)
        }
    }
}

/// A screen showing its copy on the device after the server couldn't be reached (`stale`) loads
/// again when the connection comes back. Nothing shows: the copy looks like the server's.
private struct ReloadWhenReconnected: ViewModifier {
    let stale: Bool
    let reload: (() async -> Void)?
    @State private var connectivity = Connectivity.shared

    func body(content: Content) -> some View {
        content.onChange(of: connectivity.isOnline) { _, online in
            if online, stale, let reload { Task { await reload() } }
        }
    }
}

extension View {
    /// Loads again when the connection comes back while `stale` (see `ReloadWhenReconnected`).
    func reloadsWhenReconnected(stale: Bool, _ reload: (() async -> Void)?) -> some View {
        modifier(ReloadWhenReconnected(stale: stale, reload: reload))
    }
}

/// Errors of actions (saving, deleting) shown as a glass banner at the top of the window; the
/// app tells only of errors, never of success. Sheets show it too when their content has
/// `.errorBanner()`.
@Observable
final class ErrorBanner {
    static let shared = ErrorBanner()
    private(set) var message: String?
    private var hideTask: Task<Void, Never>?

    func show(_ error: any Error) {
        if error is CancellationError { return }
        show(error.localizedDescription)
    }

    func show(_ text: String) {
        message = text
        // VoiceOver reads it out at a high priority.
        var announcement = AttributedString(text)
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
        hideTask?.cancel()
        // It stays until dismissed while VoiceOver runs.
        if Self.voiceOverRunning { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(8))
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
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(message).font(.callout)
                    Button { banner.dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular.tint(Color.red.opacity(0.15)), in: .capsule)
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
