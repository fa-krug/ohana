import Foundation

/// A prompt for an AI agent outside the app (Claude Code, a terminal agent…): the chat's More menu
/// asks the server for one (`POST /agent/token` on the family API), which answers with a token
/// valid for an hour and the prompt that names it, the server and how to use the family's API.
/// Viewers get one too (read-only); not in the demo, which has no server.
nonisolated struct AssistantAgentAccess: OffMainDecodable, Equatable {
    let token: String
    /// ISO 8601.
    let expiresAt: String
    let prompt: String

    static let path = "/agent/token"

    @MainActor
    static func request(_ api: FamilyAPI) async throws -> AssistantAgentAccess {
        try await api.send(.post, path, body: Empty())
    }
}
