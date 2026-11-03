import Foundation
import Testing
@testable import Ohana

/// The icons a type's name or a note's comment suggests (CalendarSymbolCatalog.swift).
struct CalendarSymbolSuggestionTests {
    @Test func suggestsByGermanAndEnglishWords() {
        #expect(CalendarSymbol.suggestions(for: "Allerheiligen").first == "flame")
        #expect(CalendarSymbol.suggestions(for: "Weihnachten").first == "tree")
        #expect(CalendarSymbol.suggestions(for: "Ostermontag").first == "hare")
        #expect(CalendarSymbol.suggestions(for: "Urlaub").first == "beach.umbrella")
        #expect(CalendarSymbol.suggestions(for: "Summer vacation").contains("beach.umbrella"))
        #expect(CalendarSymbol.suggestions(for: "Fußballturnier").contains("soccerball"))
        #expect(CalendarSymbol.suggestions(for: "Geburtstag Oma").first == "birthday.cake")
        #expect(CalendarSymbol.suggestions(for: "Kita geschlossen").contains("figure.and.child.holdinghands"))
    }

    @Test func findsCompoundsAndIgnoresCaseAndAccents() {
        // A long keyword anywhere in the word, umlauts and "ß" folded.
        #expect(CalendarSymbol.suggestions(for: "ZAHNARZTTERMIN").first == "mouth")
        #expect(CalendarSymbol.suggestions(for: "Müllabfuhr").first == "trash")
        #expect(CalendarSymbol.fold("Straße Übung") == "strasse ubung")
    }

    @Test func shortKeywordsOnlyStartAWord() {
        // "zug" (train) starts a word, but isn't found inside "Umzug" (moving).
        #expect(CalendarSymbol.suggestions(for: "Zugfahrt").contains("tram"))
        #expect(!CalendarSymbol.suggestions(for: "Umzug").contains("tram"))
        #expect(CalendarSymbol.suggestions(for: "Umzug").first == "shippingbox")
    }

    @Test func anEmojiComesFirst() {
        // A note's old emoji icon moved into its comment.
        #expect(CalendarSymbol.suggestions(for: "🕯 Allerheiligen").first == "flame")
        #expect(CalendarSymbol.suggestions(for: "❤️ Jahrestag").first == "heart")
        #expect(CalendarSymbol.suggestions(for: "🎄").first == "tree")
    }

    @Test func nothingWithoutAClue() {
        #expect(CalendarSymbol.suggestions(for: "").isEmpty)
        #expect(CalendarSymbol.suggestions(for: "Xyzzy").isEmpty)
        #expect(CalendarSymbol.suggestions(for: "Urlaub Fußball Kita Zahnarzt Müll Kino", limit: 3).count == 3)
    }

    @Test func everyCatalogSymbolExistsAndIsUnique() {
        let names = CalendarSymbol.catalog.map(\.name)
        #expect(Set(names).count == names.count)
        for name in names { #expect(CalendarSymbol.exists(name), "\(name)") }
        // Every keyword is written in the folded form, so it can match.
        for info in CalendarSymbol.catalog {
            for keyword in info.keywords { #expect(CalendarSymbol.fold(keyword) == keyword, "\(info.name): \(keyword)") }
        }
        // Both pickers offer only symbols with a name in words.
        for name in CalendarSymbol.typeIcons + CalendarSymbol.noteIcons {
            #expect(names.contains(name), "\(name)")
        }
    }
}
