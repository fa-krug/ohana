import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The frame of the settings' small editors: a grouped form in a sheet with Cancel (asking
/// before it throws `hasChanges` away; the sheet can't be swiped away with them either) and a
/// confirm button; the save runs here and a failure shows in the form.
struct FamilySheetForm<Content: View>: View {
    let title: LocalizedStringKey
    var confirmTitle: LocalizedStringKey = "Save"
    let canSave: Bool
    let hasChanges: Bool
    let save: () async throws -> Void
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                content
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton(hasChanges: hasChanges)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button(confirmTitle, action: run)
                            .buttonStyle(.glassProminent)
                            .disabled(!canSave)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .discardGuard(hasChanges: hasChanges)
        .errorBanner()
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(minWidth: 440, idealWidth: 480, minHeight: 320)
        #endif
    }

    private func run() {
        guard canSave, !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                try await save()
                dismiss()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// An optional day in the past: a switch and a date picker (birthdays).
struct FamilyBirthdayField: View {
    let title: LocalizedStringKey
    @Binding var birthday: Day?

    private var hasBirthday: Binding<Bool> {
        Binding(get: { birthday != nil }, set: { birthday = $0 ? (birthday ?? Day.today) : nil })
    }

    private var date: Binding<Date> {
        Binding(get: { (birthday ?? .today).date }, set: { birthday = Day($0) })
    }

    var body: some View {
        Toggle(title, isOn: hasBirthday.animation())
        if birthday != nil {
            DatePicker("Date", selection: date, in: ...Date(), displayedComponents: .date)
        }
    }
}

/// A member's birthday (members set their own, editors anyone's).
struct FamilyBirthdaySheet: View {
    let title: String
    let save: (Day?) async throws -> Void
    @State private var birthday: Day?
    private let original: Day?

    init(title: String, birthday: Day?, save: @escaping (Day?) async throws -> Void) {
        self.title = title
        self.save = save
        original = birthday
        _birthday = State(initialValue: birthday)
    }

    var body: some View {
        FamilySheetForm(title: "Birthday", canSave: birthday != original, hasChanges: birthday != original,
                        save: { try await save(birthday) }) {
            Section {
                FamilyBirthdayField(title: "Birthday", birthday: $birthday)
            } header: {
                Text(title)
            } footer: {
                if let birthday {
                    Text(FamilyBirthdays.text(birthday))
                }
            }
        }
    }
}

/// Adding someone without an account (optionally with an invite link), or editing them.
struct FamilyPersonSheet: View {
    let person: FamilyPerson?
    let save: (FamilyPersonInput) async throws -> Void

    @State private var name: String
    @State private var birthday: Day?
    @State private var withInvite = false
    @State private var inviteRole: FamilyRole = .viewer

    init(person: FamilyPerson?, save: @escaping (FamilyPersonInput) async throws -> Void) {
        self.person = person
        self.save = save
        _name = State(initialValue: person?.name ?? "")
        _birthday = State(initialValue: person?.birthday)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var unchanged: Bool { person != nil && trimmed == person?.name && birthday == person?.birthday }
    private var hasChanges: Bool {
        trimmed != (person?.name ?? "") || birthday != person?.birthday || withInvite
    }

    var body: some View {
        FamilySheetForm(title: person == nil ? "Add a person" : "Edit person",
                        confirmTitle: person == nil ? "Add" : "Save",
                        canSave: !trimmed.isEmpty && trimmed.count <= 80 && !unchanged,
                        hasChanges: hasChanges,
                        save: {
                            try await save(FamilyPersonInput(name: trimmed, birthday: birthday,
                                                             invite: person == nil && withInvite ? inviteRole : nil))
                        }) {
            Section {
                TextField("Name", text: $name)
                FamilyBirthdayField(title: "Birthday (optional)", birthday: $birthday)
            } footer: {
                if trimmed.count > 80 {
                    Text("The name is too long (max. 80).").foregroundStyle(.red)
                } else if person == nil {
                    Text("For someone without an account, like a child. You can create an invite link for them now or later.")
                }
            }
            if person == nil {
                Section {
                    Toggle("Create an invite link so they can sign in", isOn: $withInvite.animation())
                    if withInvite {
                        FamilyRolePicker(title: "Joins as", role: $inviteRole)
                    }
                }
            }
        }
    }
}

/// Adding an account that exists already, by its email.
struct FamilyAddByEmailSheet: View {
    let save: (FamilyAddMemberInput) async throws -> Void
    @State private var email = ""
    @State private var role: FamilyRole = .editor

    private var trimmed: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        FamilySheetForm(title: "Add by email", confirmTitle: "Add", canSave: !trimmed.isEmpty, hasChanges: !trimmed.isEmpty,
                        save: { try await save(FamilyAddMemberInput(email: trimmed, role: role)) }) {
            Section {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
                FamilyRolePicker(title: "Role", role: $role)
            } footer: {
                Text("Has an Ohana account already? Add them with the email of their account.")
            }
        }
    }
}

/// Editor or viewer, with what each may do.
struct FamilyRolePicker: View {
    let title: LocalizedStringKey
    @Binding var role: FamilyRole

    var body: some View {
        Picker(title, selection: $role) {
            ForEach([FamilyRole.editor, .viewer], id: \.self) { role in
                Text(role.title).tag(role)
            }
        }
        Text(role.hint)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// A new invite link: share it or copy it.
struct FamilyInviteLinkSheet: View {
    let link: FamilySharedLink
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                TintedIcon(systemImage: "link", tint: .ohana, size: 56)
                VStack(spacing: 6) {
                    Text("Invite link created").font(.title2.bold())
                    if let name = link.name {
                        Text("for \(name)").foregroundStyle(.secondary)
                    }
                }
                Text(link.url.absoluteString)
                    .font(.callout.monospaced())
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .contentCard(cornerRadius: 16, padding: 12)
                Text("The link lets someone join the family, with a new account or their existing one. Valid for 7 days, once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { linkButtons }
                    VStack(spacing: 12) { linkButtons }
                }
                .controlSize(.large)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .errorBanner()
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(minWidth: 440, minHeight: 360)
        #endif
    }

    @ViewBuilder private var linkButtons: some View {
        ShareLink(item: link.url) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.borderedProminent)
        Button {
            FamilyPasteboard.copy(link.url.absoluteString)
            copied = true
        } label: {
            Label(copied ? "Copied." : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.bordered)
    }
}

enum FamilyPasteboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// A notification channel: the service, its secret (write-only: blank keeps the stored one),
/// the target, SMTP for email.
struct FamilyChannelSheet: View {
    let channel: FamilyChannel?
    let save: (FamilyChannelInput) async throws -> Void
    @State private var input: FamilyChannelInput
    private let original: FamilyChannelInput

    init(channel: FamilyChannel?, save: @escaping (FamilyChannelInput) async throws -> Void) {
        self.channel = channel
        self.save = save
        original = channel.map(FamilyChannelInput.init) ?? FamilyChannelInput()
        _input = State(initialValue: original)
    }

    private var hasToken: Bool { channel?.hasToken == true }

    var body: some View {
        FamilySheetForm(title: channel == nil ? "New channel" : "Edit channel",
                        canSave: input.canSave(hasToken: hasToken),
                        hasChanges: input != original,
                        save: { try await save(input) }) {
            Section {
                TextField("Name", text: $input.name, prompt: Text("e.g. Sascha’s phone"))
                Picker("Service", selection: $input.provider) {
                    ForEach(FamilyChannelProvider.allCases) { provider in
                        Label(provider.title, systemImage: provider.systemImage).tag(provider)
                    }
                }
            } footer: {
                Text("Pushbullet, Pushover, Telegram or email over SMTP.")
            }
            if input.provider == .email {
                Section("Email over SMTP") {
                    TextField("SMTP server", text: $input.smtpHost, prompt: Text(verbatim: "smtp.example.com"))
                        .autocorrectionDisabled()
                    TextField("Port", value: $input.smtpPort, format: .number.grouping(.never))
                    TextField("SMTP user", text: $input.smtpUsername)
                        .autocorrectionDisabled()
                    TextField("Sender address", text: $input.smtpFrom, prompt: Text(verbatim: input.smtpUsername))
                        .autocorrectionDisabled()
                }
            }
            Section {
                SecureField(input.provider.tokenLabel, text: $input.token,
                            prompt: hasToken ? Text("Leave empty to keep it") : nil)
                if let label = input.provider.targetLabel {
                    TextField(label, text: $input.target)
                        .autocorrectionDisabled()
                }
            } footer: {
                if hasToken {
                    Text("A token is stored; leave the field empty to keep it.")
                } else {
                    Text("Tokens and passwords are stored encrypted.")
                }
            }
            Section {
                Toggle("Active", isOn: $input.enabled)
            }
        }
        .onChange(of: input.provider) { _, provider in
            if provider == .pushbullet { input.target = "" }
        }
    }
}
