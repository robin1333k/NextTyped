import Foundation

/// **OCR-time pattern scrub** — the last guard in the scrub-chain, and the only
/// one that can reach the residual the structural guards provably cannot: **credentials rendered inside
/// a browser tab**. A bank page or a web password manager is not a separate bundle, so the pre-capture
/// `excludingApplications` filter can't exclude it, and the AX secure-field subrole is rarely exposed
/// for web content.
///
/// This is deliberately **not** a "password detector" — a fragile one would give false confidence.
/// It drops the highest-signal *numeric* offenders, cheaply and predictably:
///   - credit-card numbers (13–19 digits **and** Luhn-valid — the check that separates a card from a
///     long order number),
///   - IBANs (2 letters + 2 check digits + 10–30 alphanumerics),
///   - long bare digit runs (account/reference numbers),
///   - short numeric codes on a line that mentions Code / OTP / 2FA / TAN / Verification.
///
/// It also drops secret-shaped text, from the vendors' published formats (see
/// `SensitiveTextScrub+SecretPatterns.swift`): the value of a one-line credential assignment
/// (password, token, secret, API key, Passwort, Kennwort and similar), the value of an `export` whose
/// name contains KEY/TOKEN/SECRET/PASSWORD, PEM private key blocks, AWS/GitHub/Slack/Stripe/OpenAI/
/// Anthropic/Google keys, JWTs, `user:pass@` in URLs and signed-URL signature parameters. The same scrub
/// runs on clipboard context (`ClipboardContextPolicy`).
///
/// What it does not catch is documented, not hidden (the Privacy panel discloses
/// it). The honest framing: OCR text is local-only and never persisted or transmitted, so the harm from
/// a residual is a sensitive token briefly entering the *local* prompt — not exfiltration.
public enum SensitiveTextScrub {
    /// Keywords that mark a line as carrying a one-time code. Includes the German TAN, since the user
    /// writes DE and German banking UIs say "TAN" where EN says "OTP".
    static let oneTimeCodeKeywords = [
        "code", "otp", "2fa", "tan", "verification", "verifizierung", "bestätigung",
        "einmalpasswort", "passcode", "pin",
    ]

    /// Digit-count bounds for the one-time-code rule. Wide enough for 4-digit PINs through 8-digit
    /// backup codes; a bare year or a price stays untouched unless the line names a code.
    static let oneTimeCodeDigitRange = 4...8

    /// A bare digit run at least this long is treated as an account/reference number.
    static let longDigitRunLength = 9

    /// What replaces a dropped token — a visible gap rather than silent deletion, so a reader of the
    /// DEBUG log can tell scrubbing happened. The model sees an unremarkable placeholder token.
    static let redaction = "…"

    /// Scrub a block of recognised text: the secret patterns over the whole text first (a PEM block
    /// spans lines), then the numeric rules line by line, because the one-time-code rule needs the
    /// line's own words as context.
    public static func scrub(_ text: String) -> String {
        scrubSecretPatterns(text)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { scrubLine(String($0)) }
            .joined(separator: "\n")
    }

    static func scrubLine(_ line: String) -> String {
        let mentionsCode = oneTimeCodeKeywords.contains { line.lowercased().contains($0) }
        // Split on spaces only (not all whitespace) so the line's own shape survives the round-trip.
        let tokens = line.split(separator: " ", omittingEmptySubsequences: false)
        let scrubbed = tokens.map { token -> String in
            isSensitive(String(token), lineMentionsCode: mentionsCode) ? redaction : String(token)
        }
        return scrubbed.joined(separator: " ")
    }

    /// Whether a single whitespace-delimited token should be dropped.
    static func isSensitive(_ token: String, lineMentionsCode: Bool) -> Bool {
        // Strip surrounding punctuation ("4111-1111-1111-1111." → the number) before judging; a token
        // judged sensitive is dropped whole, so we never need to put the punctuation back.
        let trimmed = token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard !trimmed.isEmpty else { return false }

        if isIBAN(trimmed) { return true }

        // Card/account rules look at the digits with the usual human separators removed, so
        // "4111 1111" split across tokens is still caught per-token by the long-run rule below.
        let digits = trimmed.filter(\.isNumber)
        let separatorsOnly = trimmed.allSatisfy { $0.isNumber || $0 == "-" || $0 == "." || $0 == "/" }
        guard !digits.isEmpty else { return false }

        if separatorsOnly {
            if (13...19).contains(digits.count), isLuhnValid(digits) { return true }
            if digits.count >= longDigitRunLength { return true }
            if lineMentionsCode, oneTimeCodeDigitRange.contains(digits.count),
               digits.count == trimmed.filter({ $0.isNumber || $0 == "-" }).count {
                return true
            }
        }
        return false
    }

    /// The Luhn (mod-10) checksum — what tells a real card number from a long order reference.
    static func isLuhnValid(_ digits: String) -> Bool {
        guard digits.count >= 2, digits.allSatisfy(\.isNumber) else { return false }
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            guard let value = character.wholeNumberValue else { return false }
            if index % 2 == 1 {
                let doubled = value * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += value
            }
        }
        return sum % 10 == 0
    }

    /// IBAN shape: two country letters, two check digits, then 10–30 alphanumerics (the per-country
    /// length table is deliberately not encoded — shape is enough to redact on).
    static func isIBAN(_ token: String) -> Bool {
        let compact = token.filter { !$0.isWhitespace && $0 != "-" }.uppercased()
        guard (14...34).contains(compact.count) else { return false }
        let characters = Array(compact)
        guard characters[0].isLetter, characters[1].isLetter,
              characters[2].isNumber, characters[3].isNumber else { return false }
        return characters.dropFirst(4).allSatisfy { $0.isLetter || $0.isNumber }
            && characters.dropFirst(4).contains(where: \.isNumber)
    }
}
