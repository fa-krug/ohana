import SwiftUI

/// The sidebar's header: the family on screen, a menu to switch, and the account.
struct FamilySwitcher: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        FamilyMenu {
            HStack(spacing: 12) {
                TintedIcon(systemImage: "house.fill", tint: .ohana, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.selectedFamily?.name ?? "")
                        .font(.headline)
                        .lineLimit(1)
                    Text(app.me?.displayName ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .contentShape(.rect)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 4)
    }
}

/// The family and account menu: switch family, create one, open the family's settings or the
/// account. The sidebar header uses it with its own label; the iPhone toolbar with an icon.
struct FamilyMenu<MenuLabel: View>: View {
    @Environment(AppModel.self) private var app
    @State private var creating = false
    @State private var showAccount = false
    let label: MenuLabel

    init(@ViewBuilder label: () -> MenuLabel) {
        self.label = label()
    }

    var body: some View {
        @Bindable var app = app
        Menu {
            Picker("Family", selection: $app.selectedFamilyID) {
                ForEach(app.families) { family in
                    Text(family.name).tag(Optional(family.id))
                }
            }
            .pickerStyle(.inline)
            Button("New family…", systemImage: "plus") { creating = true }
            Divider()
            Button("Family settings", systemImage: "gearshape") { Module.settings.open() }
            #if os(macOS)
            SettingsLink { Label("Account…", systemImage: "person.crop.circle") }
            #else
            Button("Account", systemImage: "person.crop.circle") { showAccount = true }
            #endif
        } label: {
            label
        }
        .sheet(isPresented: $creating) { CreateFamilySheet().errorBanner() }
        .sheet(isPresented: $showAccount) { NavigationStack { AccountView() }.errorBanner() }
    }
}

extension FamilyMenu where MenuLabel == Label<Text, Image> {
    init() {
        self.init { Label("Family", systemImage: "person.2.circle") }
    }
}
