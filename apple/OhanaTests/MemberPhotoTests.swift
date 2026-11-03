import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Ohana

struct MemberPhotoTests {
    @Test func decodesThePhotosOfTheHousehold() throws {
        let json = """
        {"name":"Krug","role":"editor","selfId":"u1","members":[{"userId":"u1","email":"anna@test","name":"Anna","role":"editor","birthday":null,"joinedAt":"2026-11-01T12:00:00.000Z","color":"blue","photo":"members/f1/u1_1762170000000.webp"},{"userId":"u2","email":"ben@test","name":"Ben","role":"viewer","birthday":null,"joinedAt":"2026-11-01T12:00:00.000Z","color":"green","photo":null}],"people":[{"id":"p1","name":"Mia","birthday":null,"color":"green","photo":"members/f1/p1_1762170000000.webp"},{"id":"p2","name":"Leo","birthday":null}],"invites":[],"home":{"address":null,"lat":null,"lng":null},"channels":[],"events":[]}
        """
        let h = try JSONDecoder().decode(FamilyHousehold.self, from: Data(json.utf8))
        #expect(h.members.map(\.photo) == ["members/f1/u1_1762170000000.webp", nil])
        // An older server sends none.
        #expect(h.people.map(\.photo) == ["members/f1/p1_1762170000000.webp", nil])
    }

    @Test func decodesTheAnswerOfAPhotoUpload() throws {
        let member = try JSONDecoder().decode(FamilyMember.self, from: Data("""
        {"userId":"u1","email":"anna@test","name":"Anna","role":"editor","birthday":null,"joinedAt":"2026-11-01T12:00:00.000Z","color":"blue","photo":"members/f1/u1_1.webp"}
        """.utf8))
        #expect(member.photo == "members/f1/u1_1.webp")
        let person = try JSONDecoder().decode(FamilyPerson.self, from: Data("""
        {"id":"p1","name":"Mia","birthday":null,"color":"green","photo":null}
        """.utf8))
        #expect(person.photo == nil && person.color == "green")
    }

    @Test func decodesTheCalendarMembersPhotos() throws {
        let members = try JSONDecoder().decode([CalendarMember].self, from: Data("""
        [{"id":"u1","name":"Anna","account":true,"color":"blue","photo":"members/f1/u1_1.webp"},{"id":"p1","name":"Mia","account":false,"color":"green","photo":null},{"id":"p2","name":"Leo","color":"red"}]
        """.utf8))
        #expect(members.map(\.photo) == ["members/f1/u1_1.webp", nil, nil])
        #expect(members[2] == CalendarMember(id: "p2", name: "Leo", color: "red"))
    }

    @Test func pathsUnderTheImagesRoute() {
        #expect(MemberPhoto.path("members/f1/u1_1.webp") == "/api/images/members/f1/u1_1.webp")
        #expect(MemberPhoto.path(nil) == nil)
        #expect(MemberPhoto.path("") == nil)
    }

    @Test func downscalesABigImageToAJPEG() throws {
        let png = try #require(Self.png(width: 3000, height: 2000))
        let jpeg = try #require(MemberPhoto.jpeg(from: png))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(image.width, image.height) == MemberPhoto.maxPixels)
        #expect(image.width == 1024 && (682...683).contains(image.height))
        #expect(jpeg.count < 5 * 1024 * 1024)
    }

    @Test func keepsASmallImagesSize() throws {
        let png = try #require(Self.png(width: 300, height: 400))
        let jpeg = try #require(MemberPhoto.jpeg(from: png))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 300 && image.height == 400)
    }

    @Test func refusesWhatIsNoImage() {
        #expect(MemberPhoto.jpeg(from: Data("not a picture".utf8)) == nil)
    }

    /// A PNG of a gradient (with some transparency) of that size.
    private static func png(width: Int, height: Int) -> Data? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for x in stride(from: 0, to: width, by: 50) {
            ctx.setFillColor(CGColor(red: Double(x) / Double(width), green: 0.4, blue: 0.7, alpha: x % 100 == 0 ? 1 : 0.5))
            ctx.fill(CGRect(x: x, y: 0, width: 50, height: height))
        }
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
