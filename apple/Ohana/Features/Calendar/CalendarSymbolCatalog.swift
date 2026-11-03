import Foundation

/// A symbol to pick for a type or a note: its name, its name in words, and the words that suggest
/// it (English and German, lowercased, without accents, "ß" as "ss").
struct CalendarSymbolInfo {
    let name: String
    let title: String
    let keywords: [String]

    init(_ name: String, _ title: String, _ keywords: String = "") {
        self.name = name
        self.title = title
        self.keywords = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

extension CalendarSymbol {
    /// Every symbol the pickers offer, with its words. A keyword of five letters or more is found
    /// anywhere in the text (German compounds: "Zahnarzttermin"), a shorter one at a word's start.
    static let catalog: [CalendarSymbolInfo] = [
        // The roles' defaults.
        .init("tag", String(localized: "Tag"), "sonstig, other, misc"),
        .init("exclamationmark.triangle", String(localized: "Warning"),
              "betreuung, needs cover, no cover, streik, strike, notfall, emergency, achtung, warnung, warning, geschlossen, closed, schliesstag"),
        .init("checkmark.shield", String(localized: "Shield"), "vertretung, covers, cover, abdeck, betreut, notbetreuung, aufsicht"),
        .init("sun.max", String(localized: "Sun"),
              "frei, day off, brueckentag, bruckentag, sommer, summer, sonne, sunny, ueberstund, uberstund, gleitzeit"),
        // Celebrations and holidays.
        .init("star", String(localized: "Star"), "feiertag, holiday, highlight, nikolaus, stern, besonder, special"),
        .init("heart", String(localized: "Heart"), "valentin, hochzeit, wedding, jahrestag, anniversary, muttertag, mother, vatertag, father, date night, liebe, love, herz"),
        .init("gift", String(localized: "Gift"), "geschenk, gift, present, bescherung, nikolaus, wichteln"),
        .init("birthday.cake", String(localized: "Birthday cake"), "geburtstag, birthday, bday, kuchen, cake, torte"),
        .init("party.popper", String(localized: "Party"), "party, feier, fest, celebrat, silvester, new year, neujahr, fasching, karneval, carnival, jubilaum"),
        .init("balloon.2", String(localized: "Balloons"), "kindergeburtstag, kids party, luftballon, balloon, einschulung"),
        .init("sparkles", String(localized: "Special"), "besonder, special, ueberraschung, uberraschung, surprise, magic, putzen, cleaning"),
        .init("fireworks", String(localized: "Fireworks"), "silvester, new year, neujahr, feuerwerk, firework, nationalfeiertag"),
        .init("tree", String(localized: "Tree"), "weihnacht, christmas, xmas, heiligabend, christmas eve, tannenbaum, baum, tree, wald, forest"),
        .init("hare", String(localized: "Hare"), "ostern, easter, osterhase, karfreitag, good friday, ostermontag, hase, bunny, rabbit"),
        .init("flame", String(localized: "Flame"),
              "allerheiligen, all saints, allerseelen, all souls, advent, kerze, candle, gedenk, memorial, trauer, beerdigung, funeral, lagerfeuer, campfire, grill, bbq, barbecue, laterne, martinstag, sankt martin, st. martin"),
        .init("moon.stars", String(localized: "Night"), "halloween, nacht, night, abend, evening, ubernacht, sleepover, laternen, ramadan"),
        .init("cross", String(localized: "Cross"),
              "kirche, church, gottesdienst, service, taufe, baptism, kommunion, communion, konfirmation, confirmation, fronleichnam, corpus christi, pfingst, pentecost, himmelfahrt, ascension, reformation, buss- und bettag, mariae"),
        .init("flag", String(localized: "Flag"), "nationalfeiertag, national, einheit, unity, tag der, flag, flagge, feiertag, holiday, ziel, goal"),
        // Reminders.
        .init("bell", String(localized: "Bell"), "erinner, reminder, remind, glocke, bell"),
        .init("alarm", String(localized: "Alarm"), "wecker, alarm, aufstehen, wake, frueh, fruh, early"),
        .init("clock", String(localized: "Clock"), "termin, appointment, uhr, clock, zeit, time, schicht, shift"),
        .init("calendar", String(localized: "Calendar"), "kalender, calendar, planung, planning, woche, week, monat, month"),
        .init("hourglass", String(localized: "Deadline"), "frist, deadline, abgabe, due, ablauf, expire, letzter tag, last day, anmeldeschluss"),
        .init("exclamationmark.circle", String(localized: "Important"), "wichtig, important, dringend, urgent"),
        .init("info.circle", String(localized: "Info"), "info, hinweis, note, notiz"),
        .init("questionmark.circle", String(localized: "Question"), "frage, question, unklar, unclear, vielleicht, maybe, offen, tbd"),
        .init("checkmark.circle", String(localized: "Done"), "erledigt, done, fertig, finished, bestaetigt, bestatigt, confirmed, zusage"),
        .init("pin", String(localized: "Pin")),
        .init("mappin", String(localized: "Place"), "treffpunkt, meeting point, ort, place, location, adresse, address"),
        // Home and family.
        .init("house", String(localized: "House"), "zuhause, zu hause, home, haus, house, daheim, homeoffice, home office, heim"),
        .init("house.lodge", String(localized: "Holiday home"), "ferienhaus, ferienwohnung, fewo, holiday home, cottage, hutte, huette, cabin, chalet"),
        .init("key", String(localized: "Key"), "schlussel, schluessel, key, ubergabe, uebergabe, handover, einzug, check-in, checkin"),
        .init("person.2", String(localized: "Visit"), "besuch, visit, gaste, gaeste, guests, freunde, friends, oma, opa, grandma, grandpa, grosseltern, grandparents"),
        .init("person.3", String(localized: "Meeting"), "treffen, meeting, elternabend, parents evening, versammlung, sitzung, besprechung, gruppe, group, verein, club"),
        .init("figure.and.child.holdinghands", String(localized: "Adult and child"),
              "kita, kindergarten, krippe, daycare, nursery, tagesmutter, childminder, abholen, pick up, pickup, bringen, drop off, eingewohn, umgang, kinder, kids, children"),
        .init("figure.2.and.child.holdinghands", String(localized: "Family"), "familie, family, familien, elternzeit, parental leave, ausflug, outing"),
        .init("teddybear", String(localized: "Teddy bear"), "baby, kleinkind, toddler, spielgruppe, playgroup, kuschel, teddy, spielzeug, toy"),
        .init("stroller", String(localized: "Stroller"), "baby, mutterschutz, maternity, geburt, birth, hebamme, midwife, kinderwagen, stroller, pekip"),
        // Getting around and trips.
        .init("car", String(localized: "Car"), "auto, car, fahrt, drive, werkstatt, garage, reifen, tyres, tires, tuv, inspektion, service, fahrschule, driving"),
        .init("bus", String(localized: "Bus"), "bus, schulbus, school bus, reisebus, coach"),
        .init("tram", String(localized: "Train"), "zug, train, bahn, rail, s-bahn, u-bahn, tram"),
        .init("bicycle", String(localized: "Bicycle"), "fahrrad, rad, bike, bicycle, radtour, cycling"),
        .init("airplane", String(localized: "Airplane"), "flug, flight, fly, fliegen, flughafen, airport, abflug, departure, ankunft, arrival"),
        .init("ferry", String(localized: "Ferry"), "fahre, faehre, ferry, schiff, ship, boot, boat, kreuzfahrt, cruise, segeln, sailing"),
        .init("suitcase", String(localized: "Suitcase"), "reise, travel, trip, koffer, suitcase, packen, packing, abreise, anreise"),
        .init("suitcase.rolling", String(localized: "Rolling suitcase"), "dienstreise, business trip, geschaftsreise, geschaeftsreise, messe, trade fair, konferenz, conference"),
        .init("beach.umbrella", String(localized: "Beach umbrella"), "urlaub, vacation, holiday, ferien, strand, beach, meer, sea, baden, see, lake"),
        .init("tent", String(localized: "Tent"), "camping, zelt, tent, zeltlager, ferienlager, camp, freizeit"),
        .init("mountain.2", String(localized: "Mountains"), "berg, mountain, alpen, alps, wanderurlaub, skiurlaub, gebirge"),
        .init("map", String(localized: "Trip"), "ausflug, trip, excursion, tour, wandertag, field trip, klassenfahrt, school trip, sightseeing"),
        // Sports and leisure.
        .init("figure.walk", String(localized: "Walk"), "spaziergang, walk, laufen, gassi, zu fuss, on foot"),
        .init("figure.run", String(localized: "Run"), "joggen, jogging, lauf, run, marathon, sport, bundesjugendspiele, sports day"),
        .init("figure.hiking", String(localized: "Hiking"), "wandern, wanderung, hike, hiking, wandertag"),
        .init("figure.pool.swim", String(localized: "Swimming"), "schwimm, swim, schwimmbad, pool, freibad, hallenbad, seepferdchen"),
        .init("figure.skiing.downhill", String(localized: "Skiing"), "ski, skifahren, skiing, skikurs, snowboard, winterurlaub, ski trip"),
        .init("figure.yoga", String(localized: "Yoga"), "yoga, pilates, meditation, entspann, relax"),
        .init("figure.equestrian.sports", String(localized: "Riding"), "reiten, reitstunde, riding, pferd, horse, pony"),
        .init("figure.martial.arts", String(localized: "Martial arts"), "judo, karate, taekwondo, kampfsport, martial, selbstverteidigung, boxen, boxing"),
        .init("figure.socialdance", String(localized: "Dance"), "tanz, dance, ballett, ballet, tanzkurs, disco"),
        .init("sportscourt", String(localized: "Sports"), "sport, training, verein, turnier, tournament, turnen, gymnastics, halle"),
        .init("soccerball", String(localized: "Football"), "fussball, football, soccer, kicken, bolzen"),
        .init("basketball", String(localized: "Basketball"), "basketball, handball, volleyball"),
        .init("tennis.racket", String(localized: "Tennis"), "tennis, badminton, tischtennis, table tennis, squash, padel"),
        .init("dumbbell", String(localized: "Workout"), "fitness, gym, workout, krafttraining, fitnessstudio, physio"),
        .init("trophy", String(localized: "Trophy"), "wettkampf, competition, turnier, tournament, finale, final, meisterschaft, championship, pokal, cup"),
        .init("medal", String(localized: "Medal"), "siegerehrung, award, preis, prize, medaille, medal, sportabzeichen"),
        .init("music.note", String(localized: "Music"), "musik, music, musikschule, music lesson, chor, choir, orchester, orchestra, konzert, concert, band"),
        .init("music.mic", String(localized: "Singing"), "singen, sing, gesang, karaoke, chor, choir, auftritt, performance"),
        .init("guitars", String(localized: "Guitar"), "gitarre, guitar, ukulele, bass"),
        .init("pianokeys", String(localized: "Piano"), "klavier, piano, keyboard, flugel"),
        .init("theatermasks", String(localized: "Theatre"), "theater, theatre, auffuhrung, auffuehrung, play, musical, fasching, karneval, carnival, kostum, kostuem, costume, oper, opera"),
        .init("ticket", String(localized: "Ticket"), "ticket, karten, eintritt, admission, event, veranstaltung, festival"),
        .init("film", String(localized: "Cinema"), "kino, cinema, movie, film"),
        .init("popcorn", String(localized: "Popcorn"), "filmabend, movie night, popcorn"),
        .init("gamecontroller", String(localized: "Games"), "spiel, game, zocken, gaming, spieleabend, game night"),
        .init("puzzlepiece", String(localized: "Puzzle"), "puzzle, lego, spielen, play date, playdate"),
        .init("paintpalette", String(localized: "Arts and crafts"), "basteln, crafts, malen, painting, kunst, werken, toepfern, topfern, pottery"),
        .init("camera", String(localized: "Camera"), "foto, photo, fotograf, photographer, schulfoto, school photo, kamera, camera, shooting"),
        // School and work.
        .init("book", String(localized: "Reading"), "lesen, read, buch, book, bucherei, buecherei, bibliothek, library, vorlese, hausaufgabe, homework"),
        .init("books.vertical", String(localized: "Books"), "lernen, study, studium, prufung, pruefung, exam, klausur, test, abitur, schulbuch"),
        .init("pencil", String(localized: "Writing"), "schreiben, write, klassenarbeit, diktat, dictation, arbeit schreiben, aufsatz, essay"),
        .init("backpack", String(localized: "Backpack"), "schule, school, schulstart, schulanfang, first day, einschulung, ranzen, hort, ogs, after school"),
        .init("graduationcap", String(localized: "Graduation cap"),
              "schule, school, uni, universitat, universitaet, university, zeugnis, report card, abschluss, graduation, abitur, elternsprechtag, parent-teacher, lehrer, teacher, kurs, course, seminar, fortbildung, training course"),
        .init("building.columns", String(localized: "Public building"), "amt, behorde, behoerde, rathaus, town hall, burgeramt, buergeramt, gericht, court, bank, museum, office visit"),
        .init("building.2", String(localized: "Office"), "buro, buero, office, firma, company, praesenz, prasenz"),
        .init("briefcase", String(localized: "Briefcase"), "arbeit, work, job, dienst, schicht, shift, bewerbung, interview, vorstellung, meeting, termin arbeit"),
        .init("laptopcomputer", String(localized: "Laptop"), "homeoffice, home office, remote, mobil, online, laptop, computer, zoom, teams, videocall"),
        .init("phone", String(localized: "Phone call"), "anruf, anrufen, call, telefon, phone, telefonat"),
        .init("envelope", String(localized: "Letter"), "brief, letter, post, mail, email, einladung, invitation, antrag, application"),
        .init("doc.text", String(localized: "Document"), "dokument, document, vertrag, contract, formular, form, steuer, tax, unterlagen, papers, ausweis, passport, reisepass, antrag"),
        // Health.
        .init("cross.case", String(localized: "First aid kit"), "arzt, doctor, praxis, clinic, kinderarzt, pediatrician, hausarzt, krankenhaus, hospital, notaufnahme, u-untersuchung, vorsorge, checkup, check-up, reha"),
        .init("stethoscope", String(localized: "Stethoscope"), "arzt, doctor, untersuchung, examination, kinderarzt, hausarzt, frauenarzt, hautarzt, orthopad, vorsorge, checkup"),
        .init("pills", String(localized: "Pills"), "medikament, medicine, tablette, pill, apotheke, pharmacy, rezept, prescription, allergie, allergy"),
        .init("syringe", String(localized: "Vaccination"), "impf, vaccin, shot, spritze, blutabnahme, blood test, grippe, flu"),
        .init("bandage", String(localized: "Bandage"), "verletz, injury, unfall, accident, verband, pflaster, wunde, wound, bruch, fracture, gips, cast"),
        .init("thermometer.medium", String(localized: "Thermometer"), "krank, sick, ill, fieber, fever, erkalt, cold, grippe, flu, infekt, infection, kind krank"),
        .init("bed.double", String(localized: "Bed"), "krank, sick, bettruhe, bed, ubernachtung, uebernachtung, overnight, hotel, schlafen, sleep, pension, airbnb"),
        .init("moon.zzz", String(localized: "Sleep"), "schlaf, sleep, nachtschicht, night shift, ausschlafen, lie-in, nap, mittagsschlaf"),
        .init("mouth", String(localized: "Dentist"), "zahnarzt, dentist, zahn, teeth, tooth, zahnreinigung, kieferorthopad, kieferorthopaede, orthodontist, zahnspange, braces"),
        .init("eye", String(localized: "Eyes"), "augenarzt, optiker, optician, eye, auge, sehtest, eye test, brille, glasses"),
        // Shopping, chores and errands.
        .init("cart", String(localized: "Shopping"), "einkauf, einkaufen, shopping, groceries, supermarkt, supermarket, markt, market, wocheneinkauf"),
        .init("bag", String(localized: "Shopping bag"), "shoppen, shop, bummel, stadtbummel, flohmarkt, flea market, basar, bazaar, sale"),
        .init("eurosign", String(localized: "Money"), "geld, money, zahlen, pay, rechnung, bill, invoice, gehalt, salary, miete, rent, taschengeld, pocket money, beitrag, fee"),
        .init("creditcard", String(localized: "Payment"), "zahlung, payment, abbuchung, debit, kreditkarte, credit card, uberweisung, ueberweisung, transfer, lastschrift"),
        .init("scissors", String(localized: "Hairdresser"), "friseur, frisor, hairdresser, haircut, haare, hair, barber"),
        .init("tshirt", String(localized: "Clothes"), "kleidung, clothes, wasche, waesche, laundry, sportzeug, schuhe, shoes, kostum, costume"),
        .init("wrench.and.screwdriver", String(localized: "Repairs"), "reparatur, repair, handwerker, tradesman, monteur, technician, wartung, maintenance, heizung, heating, installation"),
        .init("shippingbox", String(localized: "Box"), "umzug, moving, paket, parcel, package, lieferung, delivery, abholung, collection, karton"),
        .init("trash", String(localized: "Rubbish"), "mull, muell, rubbish, garbage, trash, abfall, sperrmull, sperrmuell, recycling, tonne, altpapier, gelber sack"),
        // Food.
        .init("fork.knife", String(localized: "Meal"), "essen, meal, dinner, abendessen, lunch, mittagessen, restaurant, brunch, fruhstuck, fruehstueck, breakfast, kochen, cooking, grillen"),
        .init("cup.and.saucer", String(localized: "Coffee"), "kaffee, coffee, tee, tea, cafe, kaffeeklatsch, kuchen"),
        .init("wineglass", String(localized: "Wine"), "wein, wine, sekt, prost, cheers, empfang, reception, weinfest, apero, aperitif"),
        // Animals and nature.
        .init("pawprint", String(localized: "Paw print"), "tier, animal, pet, haustier, tierarzt, vet, zoo, tierpark, tierheim"),
        .init("dog", String(localized: "Dog"), "hund, dog, welpe, puppy, hundeschule, gassi, dog sitter"),
        .init("cat", String(localized: "Cat"), "katze, cat, kater, kitten"),
        .init("bird", String(localized: "Bird"), "vogel, bird, pfingst, pentecost, taube, dove"),
        .init("leaf", String(localized: "Leaf"), "garten, garden, natur, nature, herbst, autumn, fall, laub, park, wald, forest, gartenarbeit"),
        .init("cloud.rain", String(localized: "Rain"), "regen, rain, unwetter, storm, schlechtwetter, bad weather"),
        .init("umbrella", String(localized: "Umbrella"), "regenschirm, umbrella, regenjacke, raincoat"),
        .init("snowflake", String(localized: "Snowflake"), "winter, schnee, snow, ski, schlitten, sledging, eislauf, ice skating, frost, winterferien"),
    ]

    private static let byName: [String: CalendarSymbolInfo] =
        Dictionary(catalog.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

    /// The symbol's name in words; for one not in the catalog its name, readable.
    static func title(_ name: String) -> String {
        byName[name]?.title ?? name.replacingOccurrences(of: ".", with: " ")
    }

    /// Emoji a name or comment may start with (a note's old emoji icon moved into its comment), and
    /// the symbol each one suggests.
    static let emojiSymbols: [String: String] = [
        "🕯": "flame", "🔥": "flame", "🎄": "tree", "🌲": "tree", "🎁": "gift", "🎂": "birthday.cake", "🍰": "birthday.cake",
        "🎉": "party.popper", "🎊": "party.popper", "🥳": "party.popper", "🎈": "balloon.2", "✨": "sparkles",
        "🎆": "fireworks", "🎇": "fireworks", "🐣": "hare", "🐰": "hare", "🐇": "hare", "🥚": "hare", "🎃": "moon.stars",
        "🌙": "moon.stars", "✝": "cross", "⛪": "cross", "🕊": "bird", "❤": "heart", "💕": "heart", "💍": "heart",
        "⭐": "star", "🌟": "star", "🔔": "bell", "⏰": "alarm", "⏳": "hourglass", "❗": "exclamationmark.circle",
        "⚠": "exclamationmark.triangle", "❓": "questionmark.circle", "✅": "checkmark.circle", "📌": "pin", "📍": "mappin",
        "🏠": "house", "🏡": "house", "🔑": "key", "👪": "figure.2.and.child.holdinghands", "👶": "teddybear",
        "🚗": "car", "🚌": "bus", "🚆": "tram", "🚂": "tram", "🚲": "bicycle", "✈": "airplane", "⛴": "ferry", "🚢": "ferry",
        "🧳": "suitcase", "🏖": "beach.umbrella", "🏝": "beach.umbrella", "⛺": "tent", "🏔": "mountain.2", "⛰": "mountain.2",
        "🗺": "map", "🚶": "figure.walk", "🏃": "figure.run", "🥾": "figure.hiking", "🏊": "figure.pool.swim",
        "⛷": "figure.skiing.downhill", "🎿": "figure.skiing.downhill", "🧘": "figure.yoga", "🐴": "figure.equestrian.sports",
        "🥋": "figure.martial.arts", "💃": "figure.socialdance", "⚽": "soccerball", "🏀": "basketball", "🎾": "tennis.racket",
        "🏋": "dumbbell", "🏆": "trophy", "🏅": "medal", "🎵": "music.note", "🎶": "music.note", "🎤": "music.mic",
        "🎸": "guitars", "🎹": "pianokeys", "🎭": "theatermasks", "🎟": "ticket", "🎫": "ticket", "🎬": "film",
        "🍿": "popcorn", "🎮": "gamecontroller", "🧩": "puzzlepiece", "🎨": "paintpalette", "📷": "camera", "📸": "camera",
        "📖": "book", "📚": "books.vertical", "✏": "pencil", "🎒": "backpack", "🏫": "graduationcap", "🎓": "graduationcap",
        "🏛": "building.columns", "🏢": "building.2", "💼": "briefcase", "💻": "laptopcomputer", "📞": "phone",
        "✉": "envelope", "📄": "doc.text", "🏥": "cross.case", "🩺": "stethoscope", "💊": "pills", "💉": "syringe",
        "🩹": "bandage", "🤒": "thermometer.medium", "🛏": "bed.double", "😴": "moon.zzz", "🦷": "mouth", "👓": "eye",
        "🛒": "cart", "🛍": "bag", "💶": "eurosign", "💰": "eurosign", "💳": "creditcard", "💇": "scissors", "✂": "scissors",
        "👕": "tshirt", "🔧": "wrench.and.screwdriver", "📦": "shippingbox", "🗑": "trash", "🍽": "fork.knife",
        "☕": "cup.and.saucer", "🍷": "wineglass", "🥂": "wineglass", "🐾": "pawprint", "🐶": "dog", "🐕": "dog",
        "🐱": "cat", "🐈": "cat", "🐦": "bird", "🍂": "leaf", "🍁": "leaf", "🌿": "leaf", "🌧": "cloud.rain", "☔": "umbrella",
        "❄": "snowflake", "⛄": "snowflake", "☀": "sun.max", "🌞": "sun.max", "🚩": "flag",
    ]

    /// The symbols a type's name or a note's comment suggests, best first: an emoji in it, then the
    /// keywords found (longer and earlier ones first). Nothing for a text without a clue.
    static func suggestions(for text: String, limit: Int = 6) -> [String] {
        var scores: [String: (score: Int, position: Int)] = [:]
        func add(_ name: String, _ score: Int, at position: Int) {
            let old = scores[name] ?? (0, Int.max)
            scores[name] = (old.score + score, min(old.position, position))
        }
        for (offset, character) in text.enumerated() {
            let key = String(String.UnicodeScalarView(character.unicodeScalars.filter { $0 != "\u{FE0F}" }))
            if let name = emojiSymbols[key] { add(name, 100, at: offset) }
        }
        let folded = fold(text)
        if !folded.isEmpty {
            let words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            for info in catalog {
                for keyword in info.keywords {
                    if keyword.count >= 5 {
                        if let range = folded.range(of: keyword) {
                            add(info.name, keyword.count, at: folded.distance(from: folded.startIndex, to: range.lowerBound))
                        }
                    } else if let word = words.first(where: { $0.hasPrefix(keyword) }) {
                        add(info.name, keyword.count, at: folded.distance(from: folded.startIndex, to: word.startIndex))
                    }
                }
            }
        }
        let order = Dictionary(catalog.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { first, _ in first })
        return scores
            .sorted { a, b in
                if a.value.score != b.value.score { return a.value.score > b.value.score }
                if a.value.position != b.value.position { return a.value.position < b.value.position }
                return (order[a.key] ?? .max) < (order[b.key] ?? .max)
            }
            .map(\.key)
            .filter(exists)
            .prefix(limit)
            .map { $0 }
    }

    /// Lowercased, without accents, "ß" as "ss": the form the keywords are written in.
    static func fold(_ text: String) -> String {
        text.replacingOccurrences(of: "ß", with: "ss")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
    }
}
