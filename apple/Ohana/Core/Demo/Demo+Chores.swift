import Foundation

extension DemoServer {
    /// The demo's chores: the list is `demo-chores.json`; one chore (`/chores/{id}`, a link
    /// into the chores) is taken from it.
    static func chores(_ request: Request) -> JSONValue? {
        guard let path = request.familyPath, path.hasPrefix("/chores/") else { return nil }
        let parts = path.split(separator: "/")
        guard parts.count == 2,
              let chore = request.json("chores")?["chores"]?.arrayValue?.first(where: { $0["id"]?.stringValue == String(parts[1]) })
        else { return nil }
        return .object(["chore": chore])
    }
}
