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
        #expect(image.width == 2048 && (1365...1366).contains(image.height))
        #expect(jpeg.count < MemberPhoto.maxBytes)
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
        #expect(MemberPhoto.prepare(from: Data("not a picture".utf8)) == nil)
        #expect(MemberPhoto.image(from: Data("not a picture".utf8)) == nil)
    }

    @Test func preparesTheJPEGAndThePictureTheCropIsOf() throws {
        let png = try #require(Self.png(width: 4000, height: 3000))
        let photo = try #require(MemberPhoto.prepare(from: png))
        let jpeg = try #require(photo.jpeg)
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == photo.image.width && decoded.height == photo.image.height)
        #expect(photo.image.width == 2048 && photo.image.height == 1536)
        // A stored original: only the picture, nothing to upload.
        let original = try #require(MemberPhoto.image(from: jpeg))
        #expect(original.jpeg == nil && original.image.width == 2048)
    }

    // MARK: Crops

    @Test func decodesTheOriginalAndTheCrop() throws {
        let member = try JSONDecoder().decode(FamilyMember.self, from: Data("""
        {"userId":"u1","email":"anna@test","name":"Anna","role":"editor","birthday":null,"joinedAt":"2026-11-01T12:00:00.000Z","color":"blue","photo":"members/f1/u1_2.webp","photoOriginal":"members/f1/u1_2_original.jpg","photoCrop":{"x":0.1,"y":0.2,"w":0.5,"h":0.75}}
        """.utf8))
        #expect(member.photoOriginal == "members/f1/u1_2_original.jpg")
        #expect(member.photoCrop == MemberPhotoCrop(x: 0.1, y: 0.2, w: 0.5, h: 0.75))
        let person = try JSONDecoder().decode(FamilyPerson.self, from: Data("""
        {"id":"p1","name":"Mia","birthday":null,"color":"green","photo":"members/f1/p1_1.webp","photoOriginal":null,"photoCrop":null}
        """.utf8))
        #expect(person.photoOriginal == nil && person.photoCrop == nil)
        // An older server sends neither.
        let old = try JSONDecoder().decode(FamilyPerson.self, from: Data("""
        {"id":"p2","name":"Leo","birthday":null,"photo":"members/f1/p2_1.webp"}
        """.utf8))
        #expect(old.photo == "members/f1/p2_1.webp" && old.photoOriginal == nil && old.photoCrop == nil)
    }

    @Test func encodesTheCropOfAPatch() throws {
        let body = try APIClient.encoder.encode(MemberPhotoCropInput(crop: MemberPhotoCrop(x: 0.25, y: 0, w: 0.5, h: 1)))
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: [String: Double]])
        #expect(object == ["crop": ["x": 0.25, "y": 0, "w": 0.5, "h": 1]])
    }

    @Test func formatsTheUploadsQuery() {
        let crop = MemberPhotoCrop(x: 1.0 / 3, y: 0.000_001_9, w: 2.0 / 3, h: 0.5)
        #expect(crop.query == ["x": "0.333333", "y": "0.000001", "w": "0.666666", "h": "0.500000"])
        // A full height leaves no room above: y comes down to 0 rather than past the edge.
        #expect(MemberPhotoCrop(x: 0, y: 0.000_001_9, w: 0.5, h: 1).query["y"] == "0.000000")
        // Never past the edge after rounding, and no exponent for tiny values.
        let edge = MemberPhotoCrop(x: 0.700_000_4, y: 0.000_000_01, w: 0.3, h: 0.5).rounded()
        #expect(edge.x + edge.w <= 1)
        #expect(MemberPhotoCrop(x: 0.000_000_01, y: 0, w: 1, h: 1).query["x"] == "0.000000")
    }

    @Test func coverAtTheSmallestZoomIsCentred() {
        let square = MemberPhotoCropGeometry(width: 1000, height: 1000)
        #expect(square.crop(zoom: 1, offset: .zero, viewport: 300) == MemberPhotoCrop(x: 0, y: 0, w: 1, h: 1))
        let landscape = MemberPhotoCropGeometry(width: 2000, height: 1000)
        let crop = landscape.crop(zoom: 1, offset: .zero, viewport: 300)
        #expect(crop.h == 1 && crop.y == 0)
        #expect(abs(crop.w - 0.5) < 1e-9 && abs(crop.x - 0.25) < 1e-9)
        // Square in pixels.
        #expect(abs(crop.w * 2000 - crop.h * 1000) < 1e-6)
        let portrait = MemberPhotoCropGeometry(width: 1000, height: 1500)
        let tall = portrait.crop(zoom: 1, offset: .zero, viewport: 1)
        #expect(tall.w == 1 && abs(tall.h - 2.0 / 3) < 1e-9 && abs(tall.y - 1.0 / 6) < 1e-9)
    }

    @Test func zoomTwoHalvesTheSide() {
        let g = MemberPhotoCropGeometry(width: 2000, height: 1000)
        let crop = g.crop(zoom: 2, offset: .zero, viewport: 300)
        #expect(abs(crop.w - 0.25) < 1e-9 && abs(crop.h - 0.5) < 1e-9)
        #expect(abs(crop.x - 0.375) < 1e-9 && abs(crop.y - 0.25) < 1e-9)
    }

    @Test func zoomStaysWithinItsLimits() {
        let g = MemberPhotoCropGeometry(width: 2000, height: 1600)
        #expect(g.maxZoom == 10)
        #expect(g.clampZoom(0.5) == 1 && g.clampZoom(20) == 10)
        let closest = g.crop(zoom: 50, offset: .zero, viewport: 1)
        #expect(abs(closest.h * 1600 - 160) < 1e-6)
        // A small image can't be zoomed in at all.
        #expect(MemberPhotoCropGeometry(width: 150, height: 300).maxZoom == 1)
    }

    @Test func offsetsClampToTheImagesEdges() {
        let g = MemberPhotoCropGeometry(width: 2000, height: 1000)
        // At cover the 300-point viewport shows a 600 × 300 image: 150 points each way, none up or down.
        #expect(g.offsetLimit(zoom: 1, viewport: 300) == CGSize(width: 150, height: 0))
        #expect(g.clamp(CGSize(width: 400, height: -80), zoom: 1, viewport: 300) == CGSize(width: 150, height: 0))
        // Moved all the way right: the image's left edge.
        let left = g.crop(zoom: 1, offset: CGSize(width: 999, height: 999), viewport: 300)
        #expect(left.x == 0 && left.y == 0)
        let right = g.crop(zoom: 1, offset: CGSize(width: -999, height: 0), viewport: 300)
        #expect(abs(right.x + right.w - 1) < 1e-9)
    }

    @Test func aCropRoundTrips() {
        let g = MemberPhotoCropGeometry(width: 3024, height: 4032)
        for viewport in [1.0, 320.0] {
            let crop = MemberPhotoCrop(x: 0.2, y: 0.3, w: 0.5, h: 0.5 * 3024 / 4032)
            let (zoom, offset) = g.placement(of: crop, viewport: viewport)
            let back = g.crop(zoom: zoom, offset: offset, viewport: viewport)
            #expect(abs(back.x - crop.x) < 1e-9 && abs(back.y - crop.y) < 1e-9)
            #expect(abs(back.w - crop.w) < 1e-9 && abs(back.h - crop.h) < 1e-9)
        }
        // None: the centred cover.
        #expect(g.placement(of: nil, viewport: 1) == (zoom: 1, offset: .zero))
        // One outside the image comes back clamped.
        let (zoom, offset) = g.placement(of: MemberPhotoCrop(x: 0.9, y: 0.9, w: 0.5, h: 0.375), viewport: 1)
        let clamped = g.crop(zoom: zoom, offset: offset, viewport: 1)
        #expect(abs(clamped.x + clamped.w - 1) < 1e-9 && abs(clamped.y + clamped.h - 1) < 1e-9)
    }

    @Test func zoomingKeepsThePointUnderTheAnchor() {
        let g = MemberPhotoCropGeometry(width: 2000, height: 1000)
        let anchor = CGPoint(x: 0.3, y: -0.2), offset = CGSize(width: 0.1, height: 0.05)
        let to = MemberPhotoCropGeometry.zoomed(offset, from: 1.5, to: 3.75, anchor: anchor)
        // The image pixel under the anchor, before and after (viewport 1, centre 0).
        func pixel(zoom: CGFloat, offset: CGSize) -> CGPoint {
            let s = g.scale(zoom: zoom, viewport: 1)
            return CGPoint(x: (anchor.x - offset.width) / s + g.width / 2, y: (anchor.y - offset.height) / s + g.height / 2)
        }
        let before = pixel(zoom: 1.5, offset: offset), after = pixel(zoom: 3.75, offset: to)
        #expect(abs(before.x - after.x) < 1e-9 && abs(before.y - after.y) < 1e-9)
        // Around the centre, the offset only scales.
        #expect(MemberPhotoCropGeometry.zoomed(CGSize(width: 0.1, height: 0), from: 1, to: 2, anchor: .zero)
            == CGSize(width: 0.2, height: 0))
    }

    @Test func rubberBandsPastTheLimits() {
        typealias G = MemberPhotoCropGeometry
        #expect(G.rubberBand(0.4, lower: 0, upper: 1, dimension: 1) == 0.4)
        let past = G.rubberBand(1.5, lower: 0, upper: 1, dimension: 1)
        #expect(past > 1 && past < 1.5)
        #expect(G.rubberBand(100, lower: 0, upper: 1, dimension: 1) < 2)
        let below = G.rubberBand(-0.5, lower: 0, upper: 1, dimension: 1)
        #expect(below < 0 && below > -0.5)
        // Further out moves further, but less and less.
        #expect(G.rubberBand(2, lower: 0, upper: 1, dimension: 1) > past)
        let g = G(width: 2000, height: 1000)
        let zoom = g.rubberBandZoom(0.5)
        #expect(zoom < 1 && zoom > 0.5)
        let banded = g.rubberBand(CGSize(width: 0.9, height: 0.1), zoom: 1, viewport: 1)
        #expect(banded.width > 0.5 && banded.width < 0.9 && banded.height > 0 && banded.height < 0.1)
        // Settling: back within the limits, the anchor's point kept while the zoom comes back.
        let rest = g.settled(zoom: zoom, offset: banded, anchor: .zero, viewport: 1)
        #expect(rest.zoom == 1 && rest.offset == CGSize(width: 0.5, height: 0))
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
