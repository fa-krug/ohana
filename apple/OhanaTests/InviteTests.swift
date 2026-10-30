import Foundation
import Testing
@testable import Ohana

@MainActor
struct InviteTests {
    @Test func decodesTheInvite() throws {
        let invite = try JSONDecoder().decode(InviteSummary.self, from: Data("""
        {"familyId":"f1","familyName":"Krug","role":"editor","personName":"Mia","expiresAt":"2026-11-08T12:00:00.000Z","alreadyMember":false}
        """.utf8))
        #expect(invite.role == .editor)
        #expect(invite.personName == "Mia")
        #expect(invite.expiryDate != nil)
        #expect(!invite.alreadyMember)
        let accepted = try JSONDecoder().decode(FamilySummary.self, from: Data("""
        {"id":"f1","name":"Krug","role":"editor","memberCount":3}
        """.utf8))
        #expect(accepted.canEdit)
    }

    @Test func findsTheCodeInWhatIsPasted() {
        #expect(InviteCode.parse("-D3Q5LCqfCN6SYk4HPpRxg") == "-D3Q5LCqfCN6SYk4HPpRxg")
        #expect(InviteCode.parse("  https://ohana.example/invite/-D3Q5LCqfCN6SYk4HPpRxg \n") == "-D3Q5LCqfCN6SYk4HPpRxg")
        #expect(InviteCode.parse("http://localhost:3000/invite/abc_DEF") == "abc_DEF")
        #expect(InviteCode.parse("ohana://invite/abc") == "abc")
        #expect(InviteCode.parse("https://ohana.example/f/abc") == nil)
        #expect(InviteCode.parse("https://ohana.example/invite/") == nil)
        #expect(InviteCode.parse("not a code!") == nil)
        #expect(InviteCode.parse("") == nil)
    }

    @Test func opensInviteLinksInTheApp() throws {
        let server = URL(string: "https://ohana.example")!
        let me = UserAccount(id: "u1", email: "a@test", name: "A", preferredLanguage: "en", onboardingStep: "COMPLETED",
                             isAdmin: false, hasPassword: true, hasPasskey: false)
        let app = AppModel(preview: server, me: me, families: [])
        _ = InviteInbox.shared.take()

        #expect(app.open(URL(string: "ohana://invite/abc")!))
        #expect(InviteInbox.shared.take() == "abc")
        #expect(InviteInbox.shared.take() == nil)

        #expect(app.open(URL(string: "https://ohana.example/invite/xyz")!))
        #expect(InviteInbox.shared.take() == "xyz")

        // Another server's invite isn't this account's.
        #expect(!app.open(URL(string: "https://evil.example/invite/xyz")!))
        #expect(InviteInbox.shared.code == nil)
    }

    @Test func signedOutAnInviteLinkSignsInToItsServer() {
        let app = AppModel(signedOutPreview: ())
        _ = InviteInbox.shared.take()

        #expect(app.open(URL(string: "https://ohana.example/invite/abc")!))
        #expect(InviteInbox.shared.take() == "abc")
        #expect(app.takePendingServer()?.absoluteString == "https://ohana.example")
        #expect(app.takePendingServer() == nil)

        // Any page of a server names it too.
        #expect(app.open(URL(string: "https://ohana.example/f/fam1/calendar")!))
        #expect(app.takePendingServer()?.absoluteString == "https://ohana.example")
        #expect(InviteInbox.shared.code == nil)

        // The app’s own invite link has no server: the code waits, the connect sheet asks.
        #expect(app.open(URL(string: "ohana://invite/xyz")!))
        #expect(InviteInbox.shared.take() == "xyz")
        #expect(app.takePendingServer() == nil)
        #expect(!app.open(URL(string: "ohana://f/fam1")!))
    }
}
