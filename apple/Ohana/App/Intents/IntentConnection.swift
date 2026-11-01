import AppIntents
import Foundation

/// The server and family for the intents that work without opening the app (Siri, Shortcuts):
/// they may run with no window and no `AppModel`, so this reads what the app stored itself (the
/// server in `UserDefaults`, the token in the Keychain, the remembered family) and asks the
/// server for the account's families and modules.
struct IntentConnection {
    let api: FamilyAPI
    let family: FamilySummary

    /// The connection, checking that the server has `modules` (meals, the assistant) on. Throws
    /// `OhanaIntentError`.
    static func load(requiring modules: [Module] = []) async throws -> IntentConnection {
        guard let text = UserDefaults.standard.string(forKey: "serverURL") ?? Keychain.load(SharedConnection.Account.server),
              let server = URL(string: text),
              let token = Keychain.load(SharedConnection.Account.token), !token.isEmpty
        else { throw OhanaIntentError.notConnected }
        let client = APIClient(baseURL: server, token: token)
        async let checked = serverInfo(client)
        let me: MeResponse = try await OhanaIntentError.wrapping { try await client.get("/api/v1/me") }
        if let info = await checked {
            for module in modules where !info.isEnabled(module) {
                throw module == .assistant ? OhanaIntentError.assistantOff : OhanaIntentError.mealsOff
            }
        }
        let selected = UserDefaults.standard.string(forKey: "selectedFamilyID")
        guard let family = me.families.first(where: { $0.id == selected }) ?? me.families.first else {
            throw OhanaIntentError.noFamily
        }
        return IntentConnection(api: FamilyAPI(client: client, familyID: family.id), family: family)
    }

    /// The server's modules; nil when it can't be had (then the family API's 404 says it).
    private static func serverInfo(_ client: APIClient) async -> ServerInfo? {
        try? await ServerInfo.fetch(from: client)
    }
}

/// Why an intent couldn't do it, as Siri and Shortcuts say it.
nonisolated enum OhanaIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    /// No server connected: the app shows the demo.
    case notConnected
    case noFamily
    case mealsOff
    /// Needed for reading recipes from web pages.
    case assistantOff
    case sessionEnded
    /// No Reminders list is chosen for the family's shopping on this device.
    case noRemindersList
    /// Ohana may not use Reminders.
    case noRemindersAccess
    case badQuantity
    case emptyText
    /// The server's own words (`{error}` / `{message}`), or what went wrong on the way.
    case server(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notConnected: "Connect your Ohana server in the app first."
        case .noFamily: "Your account isn’t in a family yet. Open Ohana to create or join one."
        case .mealsOff: "Meals are turned off on your Ohana server."
        case .assistantOff: "This needs the assistant, which is turned off on your Ohana server."
        case .sessionEnded: "Your session has ended. Open Ohana and sign in again."
        case .noRemindersList: "Choose a Reminders list for the shopping list in Ohana first: Meals → Plan → Shopping List."
        case .noRemindersAccess: "Ohana has no access to your reminders. You can allow it in the Settings."
        case .badQuantity: "The quantity must be a number above 0."
        case .emptyText: "That’s empty."
        case let .server(message): LocalizedStringResource(stringLiteral: message)
        }
    }

    /// Runs `work`, turning the API's errors into this one (cancelling stays cancelling).
    @MainActor
    static func wrapping<T>(_ work: @MainActor () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as OhanaIntentError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch APIError.unauthorized {
            throw OhanaIntentError.sessionEnded
        } catch {
            throw OhanaIntentError.server(error.localizedDescription)
        }
    }
}
