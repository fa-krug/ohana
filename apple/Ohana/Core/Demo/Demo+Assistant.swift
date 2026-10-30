import Foundation

extension DemoServer {
    /// The demo's assistant routes that depend on the query; the rest are files: the settings
    /// (`demo-ai-settings.json`, as a viewer gets them: set up, read-only), the chat list
    /// (`demo-ai-chats.json`) and each chat (`demo-ai-chats-<id>.json`), all idle. A chat's
    /// stream (`/ai/chats/{id}/events`, asked for when the app comes back with a chat open) has
    /// no file, so it answers 404 and the store stops following at once; sending a message is a
    /// POST and fails with the demo's note, which the chat shows as an error.
    static func assistant(_ request: Request) -> JSONValue? {
        nil
    }
}
