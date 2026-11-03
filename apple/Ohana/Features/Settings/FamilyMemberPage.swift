import PhotosUI
import SwiftUI

/// One member's page, opened from their row in Settings → Members: an account's photo, color,
/// birthday and role, or a member without an account's name, photo, color, birthday and invite
/// link; editors remove them here. It shows what `model` holds, so it follows the reloads, and closes once they're gone.
struct FamilyMemberPage: View {
    enum Subject: Hashable {
        case member(String)
        case person(String)
    }

    @Environment(FamilyContext.self) private var family
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: FamilySettingsModel
    let subject: Subject

    @State private var sheet: FamilyMemberSheet?
    @State private var confirmation: FamilyConfirmation?
    @State private var sharedLink: FamilySharedLink?
    @State private var photoItem: PhotosPickerItem?
    @State private var importingPhoto = false
    @State private var photoBusy = false

    private var member: FamilyMember? {
        guard case let .member(id) = subject else { return nil }
        return model.household?.members.first { $0.userId == id }
    }

    private var person: FamilyPerson? {
        guard case let .person(id) = subject else { return nil }
        return model.household?.person(id)
    }

    private var gone: Bool { model.household != nil && member == nil && person == nil }

    var body: some View {
        Form {
            if let household = model.household {
                if let member {
                    memberSections(member, household: household)
                } else if let person {
                    personSections(person, household: household)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .ohanaBackground(ModuleTint.settings)
        .navigationTitle(member?.label ?? person?.name ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await model.load(family.api) }
        .onChange(of: gone, initial: true) { if gone { dismiss() } }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case let .birthday(member):
                FamilyBirthdaySheet(title: member.label, birthday: member.birthday) { birthday in
                    try await model.update(family, success: String(localized: "Birthday saved.")) { api in
                        try await api.perform(.patch, "/household/members/\(member.userId)", body: FamilyBirthdayInput(birthday: birthday))
                    }
                }
            case let .editPerson(person):
                FamilyPersonSheet(person: person) { input in
                    try await model.update(family, success: String(localized: "Saved.")) { api in
                        try await api.perform(.patch, "/household/people/\(person.id)", body: input)
                    }
                }
            }
        }
        .sheet(item: $sharedLink) { link in
            FamilyInviteLinkSheet(link: link)
        }
        .familyConfirmation($confirmation)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            photoBusy = true
            perform {
                defer { photoBusy = false }
                guard let data = try await item.loadTransferable(type: Data.self) else { return }
                try await uploadPhoto(data)
            }
        }
        .fileImporter(isPresented: $importingPhoto, allowedContentTypes: [.image]) { result in
            guard case let .success(url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            photoBusy = true
            perform {
                defer { photoBusy = false }
                try await uploadPhoto(data)
            }
        }
    }

    // MARK: Account

    @ViewBuilder
    private func memberSections(_ member: FamilyMember, household: FamilyHousehold) -> some View {
        let canManage = household.canEdit && member.userId != household.selfId
        Section {
            if !member.name.isEmpty {
                LabeledContent("Name", value: member.name)
            }
            LabeledContent("Email", value: member.email)
        }

        // Photo and color: everyone their own, editors anyone's.
        photoSection(name: member.label, color: member.color, photo: member.photo,
                     canChange: !app.isDemo && !model.state.isSaved
                         && (household.canEdit || member.userId == household.selfId))

        colorSection(member.color, id: member.userId, household: household,
                     canChange: !model.state.isSaved && (household.canEdit || member.userId == household.selfId)) { color in
            FamilyColorChange(path: "/household/members/\(member.userId)", body: FamilyColorInput(color: color))
        }

        Section {
            Button {
                sheet = .birthday(member)
            } label: {
                birthdayRow(member.birthday)
            }
            .tint(.primary)
            if canManage {
                FamilyRolePicker(title: "Role", role: Binding(get: { member.role }, set: { setRole(member, $0) }))
            } else {
                LabeledContent("Role") { Text(member.role.title) }
            }
        }

        if canManage {
            Section {
                Button("Remove from the family", role: .destructive) {
                    confirmation = FamilyConfirmation(
                        title: String(localized: "Remove \(member.label) from the family?"),
                        button: String(localized: "Remove")
                    ) { remove("/household/members/\(member.userId)", refreshApp: true) }
                }
            }
        }
    }

    // MARK: Without an account

    @ViewBuilder
    private func personSections(_ person: FamilyPerson, household: FamilyHousehold) -> some View {
        Section {
            Button {
                sheet = .editPerson(person)
            } label: {
                LabeledContent("Name", value: person.name)
            }
            .tint(.primary)
            Button {
                sheet = .editPerson(person)
            } label: {
                birthdayRow(person.birthday)
            }
            .tint(.primary)
        }

        photoSection(name: person.name, color: person.color, photo: person.photo, canChange: !app.isDemo && model.canEdit)

        colorSection(person.color, id: person.id, household: household, canChange: model.canEdit) { color in
            FamilyColorChange(path: "/household/people/\(person.id)",
                              body: FamilyPersonInput(name: person.name, birthday: person.birthday, color: color))
        }

        Section {
            if let invite = household.invite(for: person) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(invite.url)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(household.details(of: invite))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let link = invite.link {
                    ShareLink(item: link) {
                        Label("Share invite link", systemImage: "square.and.arrow.up")
                    }
                }
                Button(role: .destructive) {
                    confirmation = FamilyConfirmation(
                        title: String(localized: "Revoke the invite link for \(person.name)?"),
                        button: String(localized: "Revoke"),
                        message: String(localized: "Whoever has it can’t join with it anymore.")
                    ) {
                        remove("/household/invites/\(invite.id)", refreshApp: false,
                               success: String(localized: "Invite link revoked."))
                    }
                } label: {
                    Label("Revoke", systemImage: "link.badge.minus")
                }
            } else {
                Menu {
                    ForEach([FamilyRole.editor, .viewer], id: \.self) { role in
                        Button {
                            createInvite(role: role, person: person)
                        } label: {
                            Text(role.title)
                        }
                    }
                } label: {
                    Label("Create invite link", systemImage: "link.badge.plus")
                }
            }
        } header: {
            Text("Invite link")
        } footer: {
            Text("With the link, \(person.name) signs in with a new account or their existing one and keeps their birthday. Valid for 7 days, once.")
        }

        Section {
            Button("Remove from the family", role: .destructive) {
                confirmation = FamilyConfirmation(
                    title: String(localized: "Remove \(person.name) from the family?"),
                    button: String(localized: "Remove")
                ) { remove("/household/people/\(person.id)", refreshApp: false) }
            }
        }
    }

    /// The member's color: their calendar types' colors come from it, so the calendar reloads.
    private func colorSection(_ color: String?, id: String, household: FamilyHousehold, canChange: Bool,
                              change: @escaping (String) -> FamilyColorChange) -> some View {
        Section {
            FamilyColorChoice(selection: color, used: household.colorsUsed(besides: id)) { picked in
                guard picked.rawValue != color else { return }
                let family = family, request = change(picked.rawValue)
                model.change(family) {
                    try await family.api.perform(.patch, request.path, body: request.body)
                    family.didChange(.calendar)
                }
            }
            .disabled(!canChange)
        } header: {
            Text("Color")
        } footer: {
            Text("The member’s calendar entry types take this color. A dot marks colors others have already.")
        }
    }

    /// The member's photo, large, and the way to choose or remove one (the server crops it to a
    /// square); shown in place of their initials everywhere. Nothing without a photo and the
    /// right to give them one.
    @ViewBuilder
    private func photoSection(name: String, color: String?, photo: String?, canChange: Bool) -> some View {
        if canChange || MemberPhoto.path(photo) != nil {
            Section {
                FamilyAvatar(name: name, tint: MemberColor.color(color), photo: photo, size: 96)
                    .overlay {
                        if photoBusy {
                            ProgressView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.ultraThinMaterial, in: .circle)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                if canChange {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(MemberPhoto.path(photo) == nil ? "Choose Photo" : "Change Photo",
                              systemImage: "photo.badge.plus")
                    }
                    Button {
                        importingPhoto = true
                    } label: {
                        Label("Choose File", systemImage: "folder")
                    }
                    if MemberPhoto.path(photo) != nil {
                        Button(role: .destructive) {
                            removePhoto()
                        } label: {
                            Label("Remove Photo", systemImage: "photo.badge.minus")
                        }
                    }
                }
            } header: {
                Text("Photo")
            }
            .disabled(photoBusy)
        }
    }

    private func birthdayRow(_ birthday: Day?) -> some View {
        LabeledContent("Birthday") {
            if let birthday {
                Text(FamilyBirthdays.text(birthday))
            } else {
                Text("Not set")
            }
        }
    }

    // MARK: Changes

    private func setRole(_ member: FamilyMember, _ role: FamilyRole) {
        guard role != member.role else { return }
        let api = family.api
        model.change(family, success: String(localized: "Role changed.")) {
            try await api.perform(.patch, "/household/members/\(member.userId)", body: FamilyRoleInput(role: role))
        }
    }

    private func remove(_ path: String, refreshApp: Bool, success: String = String(localized: "Removed.")) {
        let api = family.api
        model.change(family, success: success) {
            try await api.perform(.delete, path)
            if refreshApp { await app.refresh() }
        }
    }

    /// The member's photo route: PUT (raw image bytes) and DELETE answer the member's new state.
    private var photoRoute: String {
        switch subject {
        case let .member(id): "/household/members/\(id)/photo"
        case let .person(id): "/household/people/\(id)/photo"
        }
    }

    /// Downscales the picked image to a JPEG (off the main thread), uploads it and shows the answer.
    private func uploadPhoto(_ data: Data) async throws {
        guard let jpeg = await Task.detached(operation: { MemberPhoto.jpeg(from: data) }).value else {
            throw APIError.http(status: 400, message: String(localized: "That file isn’t a picture."))
        }
        let client = family.api.client
        var req = client.request(.put, family.api.path(photoRoute), body: jpeg, contentType: "image/jpeg")
        req.timeoutInterval = 120
        let (answer, _) = try await client.data(for: req)
        await photoChanged(answer, success: String(localized: "Photo saved."))
    }

    private func removePhoto() {
        photoBusy = true
        perform {
            defer { photoBusy = false }
            let client = family.api.client
            let (answer, _) = try await client.data(for: client.request(.delete, family.api.path(photoRoute)))
            await photoChanged(answer, success: String(localized: "Photo removed."))
        }
    }

    /// Shows the member's new state from the server's answer, then reloads, and has the other
    /// screens (the calendar's types, the overview) show the new photo.
    private func photoChanged(_ answer: Data, success: String) async {
        let client = family.api.client
        switch subject {
        case .member: if let member = try? client.decode(FamilyMember.self, from: answer) { model.replace(member) }
        case .person: if let person = try? client.decode(FamilyPerson.self, from: answer) { model.replace(person) }
        }
        ErrorBanner.shared.success(success)
        await model.load(family.api)
        family.didChange(.family, .calendar)
    }

    private func createInvite(role: FamilyRole, person: FamilyPerson) {
        perform {
            if let url = try await model.createInvite(family, role: role, personId: person.id) {
                sharedLink = FamilySharedLink(url: url, name: person.name)
            }
        }
    }
}

/// A color change's request: an account's or a person's PATCH.
struct FamilyColorChange {
    let path: String
    let body: any Encodable
}

/// The palette as swatches: a check on the current color, a dot under the ones other members have
/// already (they can still be picked).
struct FamilyColorChoice: View {
    let selection: String?
    /// Whose colors they are, by key.
    let used: [String: [String]]
    let choose: (MemberColor) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
            ForEach(MemberColor.allCases) { color in
                swatch(color)
            }
        }
        .padding(.vertical, 4)
    }

    private func swatch(_ color: MemberColor) -> some View {
        let selected = selection == color.rawValue
        let owners = used[color.rawValue] ?? []
        return Button {
            choose(color)
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(color.color.gradient)
                    .frame(width: 32, height: 32)
                    .overlay {
                        if selected {
                            Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                        }
                    }
                Circle()
                    .fill(.secondary)
                    .frame(width: 4, height: 4)
                    .opacity(owners.isEmpty ? 0 : 1)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(owners.isEmpty ? color.name : "\(color.name) · \(owners.formatted(.list(type: .and)))")
        .accessibilityLabel(color.name)
        .accessibilityValue(owners.isEmpty ? "" : String(localized: "Used by \(owners.formatted(.list(type: .and)))"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

enum FamilyMemberSheet: Identifiable {
    case birthday(FamilyMember)
    case editPerson(FamilyPerson)

    var id: String {
        switch self {
        case let .birthday(member): "birthday|\(member.userId)"
        case let .editPerson(person): "person|\(person.id)"
        }
    }
}
