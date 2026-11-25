import Foundation

// Taking a change the assistant made back: where its card is in the chat and the steps of its
// undo, in order. Part of `AssistantChatStore` (AssistantChatStore.swift).

extension AssistantChatStore {
    // MARK: Undo

    /// The place of the change card with this id, if the chat has one.
    private static func changeIndex(_ chat: AssistantChat, _ changeID: String) -> Int? {
        chat.items.firstIndex { item in
            if case let .change(found) = item { return found.id == changeID }
            return false
        }
    }

    /// Undoes a change of the open chat: replays its undo requests on the family API, then tells
    /// the chat (the model hears it with the next message).
    func undo(_ changeID: String) async {
        guard let chat = current, !chat.id.isEmpty, savedCopy == nil,
              let index = Self.changeIndex(chat, changeID),
              case let .change(change) = chat.items[index], !change.undone else { return }
        do {
            for step in change.undo { try await replay(step) }
            if current?.id == chat.id, current?.items.indices.contains(index) == true {
                var done = change
                done.undone = true
                current?.items[index] = .change(done)
            }
            onChange(AssistantChangeAreas.areas(change: change.change, undo: change.undo))
        } catch {
            ErrorBanner.shared.show(String(localized: "Couldn’t undo: \(error.localizedDescription)"))
            return
        }
        struct Body: Encodable { let id: String }
        try? await api.perform(.post, "/ai/chats/\(Self.enc(chat.id))/undone", body: Body(id: changeID))
    }

    /// One undo request, relative to the family.
    private func replay(_ step: AssistantUndoStep) async throws {
        guard let method = HTTPMethod(rawValue: step.method.uppercased()) else { return }
        let body = try step.body.map { try APIClient.encoder.encode($0) }
        let req = api.client.request(method, api.path(step.path), body: body)
        _ = try await api.client.data(for: req)
    }

    /// A chat id in a path (uuids; `APIClient.url` encodes what needs it).
    static func enc(_ id: String) -> String { id }
}
