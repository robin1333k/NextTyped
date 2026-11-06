/// The shipped bilingual **common-word denylist**: the "not common" half of
/// *characteristic = frequent-for-you ∧ not common*.
///
/// Three properties are load-bearing:
///
/// - **It is tested as a UNION.** A term counts as characteristic only if it is absent from *both* the
///   EN and the DE list. That removes any need for per-text language detection: a German sentence with
///   an English filler word ("Wir nutzen Kubernetes **and** Terraform") filters that word too.
/// - **It is casing-agnostic** (everything is lowercased before the test). German capitalizes *all*
///   nouns, so the casing heuristic other systems use to find names fails here; the denylist sidesteps
///   it — and **names are characteristic by definition**, since no common-word list contains them.
/// - **It is deliberately small.** A full MB-scale bilingual frequency table (real TF-IDF) is a Wave-3
///   refinement; a few hundred function words already surface jargon and names,
///   which is the stated painpoint.
///
/// Shipped as a Swift constant rather than a bundle resource: the list is the size of a source file, and
/// a `Set` literal keeps `NextTypedCore` resource-free (no `Bundle.module` plumbing for the App
/// target, and no on-disk asset to go missing).
enum CommonWords {
    /// The union of both lists — the only thing callers need.
    static let union: Set<String> = english.union(german)

    /// Shortest term worth storing. Two-letter tokens are almost all function words or noise in both
    /// languages, and filtering them by length is cheaper than enumerating them.
    static let minimumTermLength = 3

    static let english: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one",
        "our", "out", "day", "get", "has", "him", "his", "how", "its", "may", "new", "now", "old", "see",
        "two", "who", "boy", "did", "she", "use", "way", "who", "oil", "sit", "set", "run", "eat", "far",
        "off", "own", "say", "too", "any", "yet", "yes", "let", "put", "end", "why", "ask", "men", "big",
        "that", "this", "with", "have", "from", "they", "will", "would", "there", "their", "what", "about",
        "which", "when", "make", "like", "time", "just", "know", "take", "into", "your", "some", "could",
        "them", "than", "then", "look", "only", "come", "over", "also", "back", "after", "work", "first",
        "well", "even", "want", "because", "these", "give", "most", "very", "much", "still", "should",
        "here", "where", "being", "does", "done", "made", "many", "more", "must", "need", "next", "said",
        "same", "such", "sure", "thanks", "thank", "think", "through", "under", "until", "while", "again",
        "already", "always", "another", "before", "between", "both", "cannot", "each", "either", "every",
        "going", "however", "instead", "maybe", "might", "never", "nothing", "other", "perhaps", "please",
        "really", "since", "something", "sorry", "thing", "things", "today", "using", "actually", "anyway",
        "around", "best", "better", "case", "cheers", "good", "great", "hello", "regards", "right", "part",
        "point", "quite", "seems", "sent", "small", "start", "than", "thats", "used", "were", "without",
        "yours", "was", "isnt", "dont", "doesnt", "didnt", "wont", "cant", "ive", "youre", "thats", "its",
    ]

    static let german: Set<String> = [
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einer", "eines", "einem", "einen",
        "und", "oder", "aber", "auch", "noch", "nur", "schon", "dann", "wenn", "weil", "dass", "daß",
        "ich", "wir", "sie", "ihr", "mir", "mich", "uns", "euch", "ihnen", "man", "sich", "dich", "dir",
        "ist", "sind", "war", "waren", "wird", "werden", "wurde", "wurden", "hat", "haben", "hatte",
        "hatten", "kann", "können", "konnte", "muss", "müssen", "soll", "sollen", "will", "wollen",
        "darf", "dürfen", "mag", "möchte", "sein", "seine", "seinen", "seiner", "ihre", "ihren", "ihrer",
        "mein", "meine", "meinen", "meiner", "dein", "deine", "unser", "unsere", "nicht", "kein", "keine",
        "auf", "aus", "bei", "bis", "durch", "für", "gegen", "hinter", "über", "unter", "vor", "von",
        "mit", "nach", "seit", "zu", "zum", "zur", "beim", "vom", "ins", "als", "wie", "was", "wer",
        "wo", "warum", "welche", "welcher", "welches", "hier", "dort", "heute", "morgen", "gestern",
        "jetzt", "immer", "wieder", "sehr", "mehr", "viel", "viele", "wenig", "alle", "alles", "etwas",
        "nichts", "jeder", "jede", "jedes", "andere", "anderen", "gut", "gute", "guten", "besser",
        "beste", "neue", "neuen", "erste", "letzte", "ganz", "ganze", "kurz", "lang", "damit", "dafür",
        "davon", "dabei", "darauf", "daran", "dazu", "denn", "doch", "eben", "eher", "einfach", "erst",
        "etwa", "fast", "gerade", "gleich", "grüße", "hallo", "danke", "bitte", "leider", "natürlich",
        "vielleicht", "sicher", "sowie", "sondern", "zwar", "zwischen", "trotzdem", "deshalb", "dadurch",
        "also", "oben", "unten", "vielen", "kurzem", "moin", "servus", "tschüss", "gerne", "genau",
        "einmal", "schnell", "langsam", "wirklich", "eigentlich", "möglich", "nötig", "klar", "okay",
        "geht", "gehen", "ging", "kommt", "kommen", "kam", "macht", "machen", "gemacht", "sagt", "sagen",
        "gesagt", "sieht", "sehen", "gesehen", "gibt", "geben", "steht", "stehen", "liegt", "liegen",
        "bleibt", "bleiben", "schaue", "schauen", "denke", "denken", "finde", "finden", "weiß", "wissen",
    ]
}
