import SwiftUI

/// GET /api/v1/invites/{code} (web/lib/families/invite-routes.ts): what an invite joins.
struct InviteSummary: Codable, Hashable {
    let familyId: String
    let familyName: String
    let role: FamilyRole
    /// The member without an account the invite is for: the account takes their place.
    let personName: String?
    let expiresAt: String
    /// The account is in the family already (accepting would fail).
    let alreadyMember: Bool

    var expiryDate: Date? { Date.server(expiresAt) }
}

/// Invite codes from what people paste or open: an invite link of the server
/// (`https://ohana.example/invite/{code}`), `ohana://invite/{code}`, or the bare code.
enum InviteCode {
    private static let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    static func isCode(_ text: some StringProtocol) -> Bool {
        !text.isEmpty && text.count <= 128 && text.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// The code in `text`, or nil when it isn't an invite.
    static func parse(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCode(trimmed) { return trimmed }
        guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
        return code(in: url)
    }

    /// The code of an invite URL: `…/invite/{code}` on any host, or `ohana://invite/{code}`.
    static func code(in url: URL) -> String? {
        var parts = url.path(percentEncoded: false).split(separator: "/").map(String.init)
        if url.scheme == DevicePairing.callbackScheme, let host = url.host() { parts.insert(host, at: 0) }
        guard parts.count == 2, parts[0] == "invite", isCode(parts[1]) else { return nil }
        return parts[1]
    }
}

/// Invite links the app was opened with (`AppModel.open`), waiting for a screen to show them:
/// the family menu or the no-family screen takes the code and shows `InviteJoinSheet`.
@Observable
final class InviteInbox {
    static let shared = InviteInbox()
    private(set) var code: String?

    func receive(_ code: String) { self.code = code }

    /// The waiting code, once.
    func take() -> String? {
        defer { code = nil }
        return code
    }
}

/// The invite a sheet shows: a code from a link, or nil to paste one.
struct InviteRequest: Identifiable {
    let id = UUID()
    var code: String?
}

/// Joining a family with an invite (the web's /invite/{code} page): paste the link or code,
/// see which family and role it is, accept. The family is on screen afterwards.
struct InviteJoinSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var summary: LoadState<InviteSummary> = .idle
    @State private var joining = false
    @State private var error: String?

    init(code: String? = nil) {
        _text = State(initialValue: code ?? "")
    }

    private var code: String? { InviteCode.parse(text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Invite link or code", text: $text, prompt: Text("https://…/invite/…"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit { Task { await lookUp() } }
                } footer: {
                    if !text.isEmpty, code == nil {
                        Text("That isn’t an invite link.").foregroundStyle(.red)
                    } else {
                        Text("Paste the invite link someone in the family sent you.")
                    }
                }

                switch summary {
                case .idle:
                    EmptyView()
                case .loading:
                    Section { ProgressView().frame(maxWidth: .infinity) }
                case let .failed(message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                case let .loaded(invite):
                    inviteSection(invite)
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Join a family")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if joining {
                        ProgressView()
                    } else if let invite = summary.value, !invite.alreadyMember {
                        Button("Join", action: join)
                            .buttonStyle(.glassProminent)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Check") { Task { await lookUp() } }
                            .disabled(code == nil || summary.isLoading)
                    }
                }
            }
            .task(id: code) {
                // A pasted link is looked up right away; typing waits a moment.
                summary = .idle
                error = nil
                guard code != nil else { return }
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { await lookUp() }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(minWidth: 440, idealWidth: 480, minHeight: 340)
        #endif
    }

    private func inviteSection(_ invite: InviteSummary) -> some View {
        Section {
            HStack(spacing: 14) {
                TintedIcon(systemImage: "house.fill", tint: .ohana, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(invite.familyName).font(.headline)
                    Text(invite.role == .editor ? "as editor: can change everything and add people"
                                                : "as viewer: can see everything, change nothing")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if let person = invite.personName {
                Label("You join as \(person): your account takes their place.", systemImage: "person.crop.circle.badge.checkmark")
            }
            if let date = invite.expiryDate {
                LabeledContent("Valid until", value: date.formatted(date: .abbreviated, time: .shortened))
            }
        } header: {
            Text("Invite")
        } footer: {
            if invite.alreadyMember {
                Text("You are a member of this family already.")
            }
        }
    }

    private func lookUp() async {
        guard let code, let client = app.client, !summary.isLoading else { return }
        summary = .loading
        do {
            summary = .loaded(try await client.get("/api/v1/invites/\(code)"))
        } catch is CancellationError {
            summary = .idle
        } catch {
            summary = .failed(error.localizedDescription)
        }
    }

    private func join() {
        guard let code, let client = app.client, !joining else { return }
        joining = true
        error = nil
        Task {
            do {
                let family: FamilySummary = try await client.send(.post, "/api/v1/invites/\(code)/accept")
                await app.refresh()
                app.selectedFamilyID = family.id
                Module.overview.open()
                ErrorBanner.shared.success(String(localized: "Welcome to \(family.name)."))
                dismiss()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            joining = false
        }
    }
}

/// Shows `InviteJoinSheet` for the "Join a family…" entries and for invite links the app was
/// opened with. `claimsLinks`: this screen takes links from `InviteInbox` while it is visible.
struct InviteJoinPresenter: ViewModifier {
    @Binding var request: InviteRequest?
    var claimsLinks = true
    @State private var inbox = InviteInbox.shared
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                visible = true
                claim()
            }
            .onDisappear { visible = false }
            .onChange(of: inbox.code) { claim() }
            .sheet(item: $request) { request in
                InviteJoinSheet(code: request.code).errorBanner()
            }
    }

    private func claim() {
        guard claimsLinks, visible, inbox.code != nil, let code = inbox.take() else { return }
        request = InviteRequest(code: code)
    }
}

extension View {
    func inviteJoinSheet(_ request: Binding<InviteRequest?>, claimsLinks: Bool = true) -> some View {
        modifier(InviteJoinPresenter(request: request, claimsLinks: claimsLinks))
    }
}
