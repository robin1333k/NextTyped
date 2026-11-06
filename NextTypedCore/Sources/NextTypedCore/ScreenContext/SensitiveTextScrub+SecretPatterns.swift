import Foundation

/// The **secret-pattern** half of the OCR-time pattern scrub (amendment
/// 2026-10-28). It runs on the whole text before the line-oriented numeric rules, because
/// a PEM private key spans lines and a URL or an assignment is a pattern inside a token, not a token.
///
/// Each pattern comes from the vendor's published format, not from another product. A match is replaced
/// with ``SensitiveTextScrub/redaction``; an assignment keeps its keyword and separator, and a quoted
/// value keeps its quotes, so the line still reads as what it was ("password: …").
///
/// The order matters only where two patterns can see the same text: the specific shapes (PEM, URL
/// credentials, signed-URL parameters, vendor keys, JWTs) run first, then `export`, then the generic
/// keyword assignment. Every replacement is `…`, and re-redacting `…` yields `…`, so a later pattern
/// that sees an earlier redaction leaves the line as it is.
extension SensitiveTextScrub {

    /// Keywords that name a credential in a one-line assignment. English and German, matched
    /// case-insensitively, also as a part of an identifier (`DB_PASSWORD`, `client_secret`, `x-api-key`).
    static let credentialKeywords = [
        "password", "passphrase", "passwd", "pwd", "secret", "token", "api[ _-]?key", "passwort", "kennwort",
    ]

    /// Drop every secret-shaped pattern from `text`. Line breaks survive except inside a PEM block,
    /// which collapses to a single redaction.
    static func scrubSecretPatterns(_ text: String) -> String {
        var result = text
        for (regex, template) in SecretPattern.wholeMatchRedactions {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        result = replacing(SecretPattern.export, in: result) { match, source in
            source.substring(with: match.range(at: 1)) + redactValue(source.substring(with: match.range(at: 2)))
        }
        result = replacing(SecretPattern.assignment, in: result) { match, source in
            redactAssignment(match, in: source)
        }
        return result
    }

    /// Keyword, separator and the redacted value. A `=`, `:=`, `?=` or `=>` value is one run without whitespace or `&` (code,
    /// config, a query string); a `:` value runs to the end of the line (a form or a YAML line, where a
    /// passphrase may contain spaces). An empty value leaves the line unchanged ("Password:").
    private static func redactAssignment(_ match: NSTextCheckingResult, in source: NSString) -> String? {
        let head = source.substring(with: match.range(at: 1))
        let separator = source.substring(with: match.range(at: 2))
        let gap = source.substring(with: match.range(at: 3))
        let value = source.substring(with: match.range(at: 4))
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let quoted = value.hasPrefix("\"") || value.hasPrefix("'")
        if quoted || separator == ":" {
            return head + separator + gap + redactValue(value)
        }
        let end = value.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "&" }) ?? value.endIndex
        return head + separator + gap + redaction + String(value[end...])
    }

    /// A quoted value keeps its quotes; anything else becomes the bare redaction.
    private static func redactValue(_ value: String) -> String {
        for quote in ["\"", "'"] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
            return quote + redaction + quote
        }
        return redaction
    }

    /// Replace each match of `regex` with `transform`'s result; `nil` keeps the match as it was.
    private static func replacing(
        _ regex: NSRegularExpression, in text: String,
        with transform: (NSTextCheckingResult, NSString) -> String?
    ) -> String {
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        let output = NSMutableString(string: source)
        for match in matches.reversed() {
            guard let replacement = transform(match, source) else { continue }
            output.replaceCharacters(in: match.range, with: replacement)
        }
        return output as String
    }
}

/// The compiled patterns. `NSRegularExpression` is immutable and documented as safe to share across
/// threads, which is what `nonisolated(unsafe)` asserts here.
enum SecretPattern {
    /// Characters that may continue a key-shaped token. A vendor key must not sit inside a longer run of
    /// them, or "sk-" inside "task-list-…" would match.
    private static let tokenChar = "A-Za-z0-9_-"

    /// Patterns whose whole match (or a template built from its groups) replaces the text.
    nonisolated(unsafe) static let wholeMatchRedactions: [(NSRegularExpression, String)] = [
        // PEM private key, BEGIN line through END line; a block cut off before its END line (the
        // clipboard bounds its head before the scrub) is dropped to the end of the text.
        (compile(#"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----[\s\S]*?(?:-----END (?:[A-Z0-9]+ )*PRIVATE KEY-----|\z)"#),
         SensitiveTextScrub.redaction),
        // Credentials in a URL: scheme://user:pass@host keeps the scheme and the host. The user may be
        // empty (redis://:pass@host).
        (compile(#"(?i)(?<![A-Za-z0-9+.-])([a-z][a-z0-9+.-]*://)[^\s/?#@:]*:[^\s/?#@]+@"#),
         "$1\(SensitiveTextScrub.redaction)@"),
        // Signed-URL parameters: AWS SigV4, Google Cloud Storage V4, CloudFront, Azure SAS.
        (compile(#"(?i)([?&](?:x-amz-signature|x-amz-credential|x-amz-security-token|x-goog-signature|x-goog-credential|signature|sig)=)[^&\s#]+"#),
         "$1\(SensitiveTextScrub.redaction)"),
        // Vendor key prefixes with their published shapes.
        (vendorKey("(?:AKIA|ASIA)[A-Z0-9]{16}"), SensitiveTextScrub.redaction),          // AWS access key id
        (vendorKey("gh[pousr]_[A-Za-z0-9]{36,255}"), SensitiveTextScrub.redaction),      // GitHub token
        (vendorKey("github_pat_[A-Za-z0-9_]{22,255}"), SensitiveTextScrub.redaction),    // GitHub fine-grained PAT
        (vendorKey("xox[abposr]-[A-Za-z0-9-]{10,}"), SensitiveTextScrub.redaction),      // Slack token
        (vendorKey("xapp-[0-9]+-[A-Za-z0-9-]{10,}"), SensitiveTextScrub.redaction),      // Slack app token
        (vendorKey("[sr]k_(?:live|test)_[A-Za-z0-9]{10,}"), SensitiveTextScrub.redaction), // Stripe secret/restricted
        (vendorKey("sk-[A-Za-z0-9_-]{20,}"), SensitiveTextScrub.redaction),              // OpenAI and Anthropic (sk-ant-)
        (vendorKey("AIza[0-9A-Za-z_-]{35}"), SensitiveTextScrub.redaction),              // Google API key
        // JWT: three base64url segments, the header starting with the encoded `{"`.
        (vendorKey(#"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*"#), SensitiveTextScrub.redaction),
    ]

    /// `export NAME=value` where NAME contains KEY, TOKEN, SECRET or PASSWORD. Group 1 is everything up
    /// to and including `=`, group 2 the value.
    nonisolated(unsafe) static let export = compile(
        #"(?im)^([ \t]*export[ \t]+[A-Za-z0-9_]*(?:key|token|secret|password)[A-Za-z0-9_]*=)("[^"\n]*"|'[^'\n]*'|\S+)"#)

    /// A credential keyword, optionally part of an identifier, then `:`, `=`, `:=` (Go), `?=` (Make) or `=>` (not `==`) and a
    /// value on the same line. `=>` is the PHP and Ruby hash separator (`'password' => 'hunter2'`); without
    /// it as its own alternative the `=` matched alone and only the `>` was redacted. Groups: 1 keyword with any closing quote and spaces, 2 separator, 3 spaces, 4 value.
    ///
    /// The identifier part before the keyword is one flat run of up to 40 identifier characters, so
    /// `DB_PASSWORD`, `x-api-key` and the camelCase `accessToken` all match. After the keyword come at
    /// most four `_`/`-` segments (`password_hash`), never bare letters, so "Tokenizer: BPE" stays.
    /// Both bounds keep the match time linear in the text: the earlier nested `(?:[A-Za-z0-9]+[_-])*`
    /// took 0.71 s on 1800 characters of `password_` and grew cubically.
    nonisolated(unsafe) static let assignment: NSRegularExpression = {
        let keywords = SensitiveTextScrub.credentialKeywords.joined(separator: "|")
        return compile(
            #"(?i)(?<![A-Za-z0-9])([A-Za-z0-9_-]{0,40}(?:"# + keywords
            + #")(?:[_-][A-Za-z0-9]+){0,4}["']?[ \t]*)(=>|:=|\?=|[:=])(?![=>])([ \t]*)("[^"\n]*"|'[^'\n]*'|[^\n]*)"#)
    }()

    private static func vendorKey(_ body: String) -> NSRegularExpression {
        compile("(?<![\(tokenChar)])\(body)(?![\(tokenChar)])")
    }

    private static func compile(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("SecretPattern does not compile: \(pattern) (\(error))")
        }
    }
}
