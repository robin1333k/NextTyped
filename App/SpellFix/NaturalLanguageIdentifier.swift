import NextTypedCore
import NaturalLanguage

/// `NLLanguageRecognizer`, on-device, behind the `LanguageIdentifying` port. The thresholds live in
/// Core (`SpellLanguagePolicy`); this reads the two best hypotheses and the letter count.
struct NaturalLanguageIdentifier: LanguageIdentifying {
    func reading(of text: String) -> LanguageReading? {
        let letters = text.reduce(0) { $0 + ($1.isLetter ? 1 : 0) }
        guard letters > 0 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let top = recognizer.languageHypotheses(withMaximum: 2)
            .sorted { $0.value > $1.value }
        guard let first = top.first else { return nil }
        return LanguageReading(tag: first.key.rawValue, probability: first.value,
                               runnerUpProbability: top.dropFirst().first?.value ?? 0,
                               letterCount: letters)
    }
}
