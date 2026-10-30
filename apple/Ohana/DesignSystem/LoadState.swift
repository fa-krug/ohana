import SwiftUI

/// What a screen loads: nothing yet, in flight, there, or failed with a message.
enum LoadState<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case let .loaded(v) = self { v } else { nil }
    }

    var isLoading: Bool {
        if case .loading = self { true } else { false }
    }
}

extension LoadState {
    /// Runs `load`, keeping the old value on screen while reloading.
    static func run(_ state: Binding<LoadState<Value>>, _ load: () async throws -> Value) async {
        if state.wrappedValue.value == nil { state.wrappedValue = .loading }
        do {
            state.wrappedValue = .loaded(try await load())
        } catch is CancellationError {
        } catch {
            if state.wrappedValue.value == nil { state.wrappedValue = .failed(error.localizedDescription) }
            else { ErrorBanner.shared.show(error) }
        }
    }
}

/// Shows a `LoadState`: a spinner, the failure with a retry, or the content.
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
        }
    }
}

/// Errors of actions (saving, deleting) shown as a glass banner at the top of the window.
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
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { message = nil }
        }
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
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(message).font(.callout)
                    Button { banner.dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular.tint(.red.opacity(0.15)), in: .capsule)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: banner.message)
    }
}

extension View {
    func errorBanner() -> some View { modifier(ErrorBannerOverlay()) }
}
