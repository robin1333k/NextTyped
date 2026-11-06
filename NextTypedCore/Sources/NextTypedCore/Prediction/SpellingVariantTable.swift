import Foundation

/// The word table behind `SpellingVariant`, generated from stems and suffixes so each class is
/// written once. Built lazily, once per variant.
enum SpellingVariantTable {

    static func table(for variant: SpellingVariant) -> [String: String] {
        switch variant {
        case .off: return [:]
        case .british: return british
        case .canadian: return canadian
        }
    }

    private static let british: [String: String] = shared.merging(britishOnly) { _, new in new }
    private static let canadian: [String: String] = shared.merging(canadianOnly) { _, new in new }

    // MARK: Classes shared by British and Canadian

    private static let shared: [String: String] = {
        var t: [String: String] = [:]
        func add(_ us: String, _ uk: String) { t[us] = uk }

        // -or to -our. Suffix set avoids forms that are real words in both spellings.
        let ourStems = ["color", "honor", "favor", "neighbor", "behavior", "flavor", "labor", "humor",
                        "rumor", "vigor", "harbor", "savior", "odor", "parlor", "armor", "candor",
                        "clamor", "endeavor", "fervor", "glamor", "rigor", "splendor", "tumor", "valor",
                        "vapor", "ardor", "demeanor", "rancor"]
        for stem in ourStems {
            let uk = stem.dropLast(2) + "our"
            for suffix in ["", "s", "ed", "ing", "ful", "less", "able", "ably", "ite", "ites", "er", "ers"] {
                add(stem + suffix, uk + suffix)
            }
        }
        for (us, uk) in [("neighborhood", "neighbourhood"), ("neighborhoods", "neighbourhoods"),
                         ("neighboring", "neighbouring"), ("behavioral", "behavioural"),
                         ("colorful", "colourful"), ("discolor", "discolour"),
                         ("discolored", "discoloured"), ("watercolor", "watercolour"),
                         ("watercolors", "watercolours"), ("honorable", "honourable")] { add(us, uk) }

        // -er to -re.
        for stem in ["center", "theater", "fiber", "liter", "caliber", "saber", "somber", "specter",
                     "luster", "meager"] {
            let uk = String(stem.dropLast(2)) + "re"
            add(stem, uk)
            if stem != "somber" && stem != "meager" { add(stem + "s", uk + "s") }
        }
        for stem in ["kilometer", "centimeter", "millimeter"] {
            add(stem, String(stem.dropLast(2)) + "re")
            add(stem + "s", String(stem.dropLast(2)) + "res")
        }
        for (us, uk) in [("centered", "centred"), ("centering", "centring"),
                         ("centerpiece", "centrepiece"), ("fibers", "fibres")] { add(us, uk) }

        // Doubled l.
        for stem in ["travel", "cancel", "label", "model", "level", "signal", "fuel", "counsel", "jewel",
                     "dial", "total", "tunnel", "panel", "shovel", "quarrel", "marshal", "rival",
                     "equal", "channel", "pencil", "duel"] {
            add(stem + "ed", stem + "led")
            add(stem + "ing", stem + "ling")
        }
        for (us, uk) in [("traveler", "traveller"), ("travelers", "travellers"),
                         ("counselor", "counsellor"), ("counselors", "counsellors"),
                         ("jeweler", "jeweller"), ("marvelous", "marvellous"),
                         ("modeler", "modeller"), ("leveler", "leveller"),
                         ("worshiper", "worshipper"), ("canceling", "cancelling"),
                         ("fulfill", "fulfil"), ("fulfillment", "fulfilment"), ("enroll", "enrol"),
                         ("instill", "instil"), ("distill", "distil"),
                         ("skillful", "skilful"), ("willful", "wilful")] { add(us, uk) }

        // -og to -ogue.
        for stem in ["catalog", "dialog", "analog", "monolog", "epilog", "prolog", "demagog"] {
            add(stem, stem + "ue")
            add(stem + "s", stem + "ues")
        }
        add("cataloged", "catalogued")
        add("cataloging", "cataloguing")

        // -ense to -ence.
        for stem in ["defense", "offense", "pretense"] {
            add(stem, String(stem.dropLast(2)) + "ce")
            add(stem + "s", String(stem.dropLast(2)) + "ces")
        }
        add("defenseless", "defenceless")

        // Irregulars shared by both.
        for (us, uk) in [("gray", "grey"), ("grays", "greys"), ("grayed", "greyed"),
                         ("graying", "greying"), ("grayish", "greyish"),
                         ("plow", "plough"), ("plows", "ploughs"), ("plowed", "ploughed"),
                         ("plowing", "ploughing"),
                         ("pajamas", "pyjamas"), ("pajama", "pyjama"),
                         ("mold", "mould"), ("molds", "moulds"), ("molded", "moulded"),
                         ("molding", "moulding"), ("moldy", "mouldy"),
                         ("skeptic", "sceptic"), ("skeptics", "sceptics"), ("skeptical", "sceptical"),
                         ("skepticism", "scepticism"),
                         ("maneuver", "manoeuvre"), ("maneuvers", "manoeuvres"),
                         ("maneuvered", "manoeuvred"), ("maneuvering", "manoeuvring"),
                         ("mustaches", "moustaches"),
                         ("mustache", "moustache")] { add(us, uk) }
        return t
    }()

    // MARK: British only

    private static let britishOnly: [String: String] = {
        var t: [String: String] = [:]
        func add(_ us: String, _ uk: String) { t[us] = uk }

        // -ize to -ise.
        let izeStems = ["organ", "real", "recogn", "apolog", "critic", "emphas", "summar", "minim", "maxim",
                        "priorit", "final", "author", "custom", "util", "special", "familiar", "capital",
                        "categor", "character", "civil", "colon", "memor", "normal", "optim", "patron",
                        "penal", "personal", "popular", "public", "standard", "symbol", "sympath",
                        "synchron", "visual", "general", "harmon", "hypothes", "ideal", "immun",
                        "initial", "legal", "local", "material", "mobil", "modern", "monopol",
                        "neutral", "central", "equal", "energ", "econom", "fertil", "formal", "global",
                        "hospital", "industrial", "internal", "item", "jeopard", "legitim", "magnet",
                        "mechan", "moral", "national", "natural", "rational", "revolution", "scrutin",
                        "sensit", "social", "stabil", "steril", "stigmat", "subsid", "terror", "theor",
                        "traumat", "vandal", "verbal", "vocal", "western", "computer", "digit",
                        "random", "monet", "commercial", "deput", "crystall", "dramat", "empath",
                        "fantas", "ostrac", "pasteur", "plagiar"]
        for stem in izeStems {
            for (usSuffix, ukSuffix) in [("ize", "ise"), ("izes", "ises"), ("ized", "ised"),
                                         ("izing", "ising"), ("izer", "iser"), ("izers", "isers"),
                                         ("ization", "isation"), ("izations", "isations"),
                                         ("izable", "isable")] {
                add(stem + usSuffix, stem + ukSuffix)
            }
        }
        add("tranquilize", "tranquillise")
        add("tranquilizer", "tranquilliser")

        // -yze to -yse.
        for stem in ["analy", "paraly", "cataly", "breathaly"] {
            for (usSuffix, ukSuffix) in [("ze", "se"), ("zes", "ses"), ("zed", "sed"), ("zing", "sing"),
                                         ("zer", "ser")] {
                add(stem + usSuffix, stem + ukSuffix)
            }
        }

        // Irregulars.
        for (us, uk) in [("aluminum", "aluminium"), ("mom", "mum"), ("moms", "mums"),
                         ("cozy", "cosy"), ("jewelry", "jewellery"), ("sulfur", "sulphur"),
                         ("artifact", "artefact"), ("artifacts", "artefacts"),
                         ("airplane", "aeroplane"), ("airplanes", "aeroplanes"),
                         ("esthetic", "aesthetic"), ("esthetics", "aesthetics"),
                         ("diarrhea", "diarrhoea"), ("anemia", "anaemia"),
                         ("acknowledgment", "acknowledgement")] { add(us, uk) }
        return t
    }()

    // MARK: Canadian only

    private static let canadianOnly: [String: String] = [:]
}
