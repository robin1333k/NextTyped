import Testing
@testable import NextTypedCore

/// The secret-pattern half of the OCR-time pattern scrub (amendment 2026-10-28):
/// credential assignments, `export` secrets, PEM private keys, vendor key prefixes, JWTs and URL
/// credentials. Every pattern has a literal true positive and a literal near miss.
///
/// Vendor-shaped inputs are assembled from two literal halves (`"sk_" + "live_…"`). The halves keep
/// GitHub's push protection from reading the test file as a leaked secret; the expected outputs stay
/// literal.
@Suite struct SecretPatternScrubTests {

    private func scrub(_ text: String) -> String { SensitiveTextScrub.scrub(text) }

    // MARK: credential assignments

    @Test func dropsTheValueOfAColonAssignmentToTheEndOfTheLine() {
        #expect(scrub("password: hunter2") == "password: …")
        #expect(scrub("Kennwort: correct horse battery staple") == "Kennwort: …")
        #expect(scrub("api key: abc123def") == "api key: …")
        #expect(scrub("first\nPasswort: geheim123\nlast") == "first\nPasswort: …\nlast")
    }

    @Test func dropsOneValueOfAnEqualsAssignment() {
        #expect(scrub("Passwort = geheim123") == "Passwort = …")
        #expect(scrub("DB_PASSWORD=s3cr3t # local only") == "DB_PASSWORD=… # local only")
        #expect(scrub("https://x.test/cb?access_token=abc123&page=2")
                == "https://x.test/cb?access_token=…&page=2")
        #expect(scrub("pwd=Sommer2026") == "pwd=…")
        #expect(scrub("passphrase=one-two-three") == "passphrase=…")
        #expect(scrub("passwd=letmein") == "passwd=…")
    }

    @Test func keepsTheQuotesOfAQuotedValue() {
        #expect(scrub(#"{"client_secret": "abc-123", "name": "demo"}"#)
                == #"{"client_secret": "…", "name": "demo"}"#)
        #expect(scrub("token = 'abc123'") == "token = '…'")
        #expect(scrub("x-api-key: \"k-123\"") == "x-api-key: \"…\"")
    }

    @Test func dropsTheValueAfterAHashRocket() {
        #expect(scrub("'password' => 'hunter2',") == "'password' => '…',")
        #expect(scrub(#""password" => "hunter2","#) == #""password" => "…","#)
        #expect(scrub("password => hunter2, user => bob") == "password => … user => bob")
        #expect(scrub(":api_key=>'abc123'") == ":api_key=>'…'")
        #expect(scrub("token =>> x") == "token =>> x")
    }

    @Test func dropsTheValueAfterAGoOrMakeAssignment() {
        #expect(scrub(#"password := "hunter2""#) == #"password := "…""#)
        #expect(scrub("apiKey := os.Getenv(x)") == "apiKey := …")
        #expect(scrub("TOKEN := abc123") == "TOKEN := …")
        #expect(scrub("API_KEY ?= abc123") == "API_KEY ?= …")
        #expect(scrub("token ?== x") == "token ?== x")
    }

    @Test func dropsTheValueOfACamelCaseCredentialIdentifier() {
        #expect(scrub("accessToken: abc123") == "accessToken: …")
        #expect(scrub(#"{"accessToken": "abc123"}"#) == #"{"accessToken": "…"}"#)
        #expect(scrub("authToken=abc123") == "authToken=…")
        #expect(scrub("clientSecret=xyz789") == "clientSecret=…")
    }

    @Test func keepsAKeywordWithNoValue() {
        #expect(scrub("Forgot your password?") == "Forgot your password?")
        #expect(scrub("Password:") == "Password:")
        #expect(scrub("Password reset: check your inbox") == "Password reset: check your inbox")
        #expect(scrub("Enter your token below") == "Enter your token below")
        #expect(scrub("Tokenizer: BPE") == "Tokenizer: BPE")
        #expect(scrub("if token == nil { return }") == "if token == nil { return }")
    }

    // MARK: export

    @Test func dropsTheValueOfAnExportedSecret() {
        #expect(scrub("export GITHUB_TOKEN=abc123") == "export GITHUB_TOKEN=…")
        #expect(scrub("export STRIPE_KEY=\"abc123\"") == "export STRIPE_KEY=\"…\"")
        #expect(scrub("  export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI") == "  export AWS_SECRET_ACCESS_KEY=…")
        #expect(scrub("export SMTP_PASSWORD=hunter2") == "export SMTP_PASSWORD=…")
    }

    @Test func keepsAnExportWithoutASecretName() {
        #expect(scrub("export PATH=/usr/local/bin:$PATH") == "export PATH=/usr/local/bin:$PATH")
        #expect(scrub("export LANG=de_DE.UTF-8") == "export LANG=de_DE.UTF-8")
    }

    // MARK: PEM private keys

    @Test func dropsAPEMPrivateKeyBlock() {
        let begin = "-----BEGIN RSA " + "PRIVATE KEY-----"
        let end = "-----END RSA " + "PRIVATE KEY-----"
        let text = "before\n\(begin)\nMIIEowIBAAKCAQEAfake\nZm9vYmFyYmF6\n\(end)\nafter"
        #expect(scrub(text) == "before\n…\nafter")
    }

    @Test func dropsEveryPrivateKeyFlavour() {
        for label in ["PRIVATE KEY", "OPENSSH PRIVATE KEY", "EC PRIVATE KEY", "ENCRYPTED PRIVATE KEY"] {
            let text = "-----BEGIN " + label + "-----\nb3BlbnNzaC1rZXk\n-----END " + label + "-----"
            #expect(scrub(text) == "…")
        }
    }

    @Test func dropsAPrivateKeyBlockCutOffBeforeItsEndLine() {
        // The clipboard policy bounds its head before scrubbing, so the END line can be missing.
        let text = "key:\n-----BEGIN " + "PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEF\nMIIEowIBAAKC"
        #expect(scrub(text) == "key:\n…")
    }

    @Test func keepsAPublicKeyBlock() {
        let text = "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE\n-----END PUBLIC KEY-----"
        #expect(scrub(text) == text)
    }

    // MARK: vendor key prefixes

    @Test func dropsAnAWSAccessKeyID() {
        // AKIAIOSFODNN7EXAMPLE is the example id in AWS's own documentation.
        #expect(scrub("Key id AKIAIOSFODNN7EXAMPLE here") == "Key id … here")
        #expect(scrub("temp ASIA" + "IOSFODNN7EXAMPLE.") == "temp ….")
    }

    @Test func dropsGitHubTokens() {
        let classic = "ghp_" + String(repeating: "aB3", count: 12)            // 36 after the prefix
        let server = "ghs_" + String(repeating: "Zx9", count: 12)
        let fineGrained = "github_pat_" + "11ABCDEFG0123456789_" + String(repeating: "aZ", count: 30)
        #expect(scrub("Use \(classic) to push") == "Use … to push")
        #expect(scrub(server) == "…")
        #expect(scrub("pat \(fineGrained)") == "pat …")
    }

    @Test func dropsSlackTokens() {
        let bot = "xoxb-" + "123456789012-1234567890123-AbCdEfGhIjKlMnOpQrStUvWx"
        let app = "xapp-" + "1-A0123456789-1234567890123-abcdef0123456789"
        #expect(scrub("SLACK \(bot) ok") == "SLACK … ok")
        #expect(scrub(app) == "…")
    }

    @Test func dropsStripeSecretAndRestrictedKeys() {
        let secret = "sk_" + "live_" + String(repeating: "4eC3", count: 6)
        let restricted = "rk_" + "test_" + String(repeating: "9Qa1", count: 6)
        #expect(scrub("stripe \(secret)") == "stripe …")
        #expect(scrub("\(restricted) end") == "… end")
    }

    @Test func dropsOpenAIAndAnthropicKeys() {
        let openAI = "sk-" + "proj-" + String(repeating: "Ab1_", count: 12)
        let legacyOpenAI = "sk-" + String(repeating: "T3Bl", count: 12)
        let anthropic = "sk-ant-" + "api03-" + String(repeating: "xY7-", count: 20)
        #expect(scrub("key \(openAI) done") == "key … done")
        #expect(scrub(legacyOpenAI) == "…")
        #expect(scrub("claude \(anthropic)") == "claude …")
    }

    @Test func dropsAGoogleAPIKey() {
        let key = "AIza" + "SyA-" + String(repeating: "q1W2e3R4", count: 3) + "t5Y6u7Z"   // 35 after AIza
        #expect(scrub("maps \(key) end") == "maps … end")
    }

    @Test func keepsWordsThatOnlyResembleAPrefix() {
        #expect(scrub("pip install sk-learn and run the task-list") == "pip install sk-learn and run the task-list")
        #expect(scrub("AKIA is a prefix, AKIAshort is not a key") == "AKIA is a prefix, AKIAshort is not a key")
        #expect(scrub("the ghp_ prefix marks a token") == "the ghp_ prefix marks a token")
    }

    // MARK: JWT

    @Test func dropsAJWT() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
            + ".eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ"
            + ".dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        #expect(scrub("Authorization: Bearer \(jwt)") == "Authorization: Bearer …")
    }

    @Test func keepsDottedNamesThatAreNotAJWT() {
        #expect(scrub("see eyJ.md and a.b.c") == "see eyJ.md and a.b.c")
    }

    // MARK: URL credentials

    @Test func dropsTheUserInfoOfAURL() {
        #expect(scrub("DATABASE_URL postgres://admin:hunter2@db.example.com:5432/app")
                == "DATABASE_URL postgres://…@db.example.com:5432/app")
        #expect(scrub("clone https://robin:ghtoken123@git.example.com/repo.git")
                == "clone https://…@git.example.com/repo.git")
    }

    @Test func dropsAURLPasswordWithAnEmptyUser() {
        #expect(scrub("redis://:hunter2@host:6379") == "redis://…@host:6379")
    }

    @Test func dropsSignedURLSignatureParameters() {
        let url = "https://b.s3.amazonaws.com/f.pdf?X-Amz-Algorithm=AWS4-HMAC-SHA256"
            + "&X-Amz-Credential=EXAMPLEID%2F20261028%2Fus-east-1&X-Amz-Signature=fe5f80f77d5fa3be"
        #expect(scrub(url) == "https://b.s3.amazonaws.com/f.pdf?X-Amz-Algorithm=AWS4-HMAC-SHA256"
                + "&X-Amz-Credential=…&X-Amz-Signature=…")
        #expect(scrub("https://storage.googleapis.com/b/o?X-Goog-Signature=0a1b2c&alt=media")
                == "https://storage.googleapis.com/b/o?X-Goog-Signature=…&alt=media")
        #expect(scrub("https://cdn.example.com/v.mp4?Expires=1700000000&Signature=Ab~cD&Key-Pair-Id=K2")
                == "https://cdn.example.com/v.mp4?Expires=1700000000&Signature=…&Key-Pair-Id=K2")
        #expect(scrub("https://acct.blob.core.windows.net/c/f?sv=2022-11-02&sig=abc%3D")
                == "https://acct.blob.core.windows.net/c/f?sv=2022-11-02&sig=…")
    }

    @Test func keepsURLsWithoutCredentials() {
        let text = "https://example.com/docs?page=2 mailto:robin@example.com git@github.com:org/repo.git"
        #expect(scrub(text) == text)
    }

    // MARK: near misses the ticket names

    @Test func keepsAGitSHAAndAUUID() {
        let sha = "commit 3f786850e387550fdab836ed7e6dc881de23001b fixed it"
        let uuid = "id 123e4567-e89b-12d3-a456-426614174000 saved"
        #expect(scrub(sha) == sha)
        #expect(scrub(uuid) == uuid)
    }

    // MARK: bounded time

    /// The clipboard scrubs a head of up to 2400 characters on the typing path. An identifier pattern
    /// with nested repetitions took 0.71 s on 1800 characters of `password_` and grew cubically; the
    /// bound here is generous for a loaded test machine and still two orders below that.
    @Test(arguments: ["password_", "a_", "aB", "-token", "x"])
    func scrubsAPathological2400CharacterHeadQuickly(unit: String) {
        let text = String(repeating: unit, count: 2400 / unit.count) + ": x"
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = scrub(text) }
        #expect(elapsed < .milliseconds(100), "\(unit): \(elapsed)")
    }
}
