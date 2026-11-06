import NextTypedCore
import CryptoKit
import Foundation
import NaturalLanguage
import Security

/// The at-rest half of the personalization profile: an **encrypted** `Codable` JSON store
/// in Application Support, plus the two heavy pure-Core operations (ingest, retrieval) run **off the main
/// actor** on this actor's own executor.
///
/// Four properties are load-bearing:
///
/// - **Encrypted at rest with a Keychain-held key.** AES-GCM (CryptoKit); the key is a 256-bit symmetric
///   key stored as a generic password. The AES job is purely *file* protection — the resident decrypted
///   copy is guarded by OS process isolation, not by this cipher (swap is encrypted; an unprivileged
///   same-user process cannot read another process's heap).
/// - **Resident, and NOT on the model residency ladder.** Loaded/decrypted once and kept — at well
///   under 1 MB it is negligible against the ~0.2 GB Tier-2 idle target, and keeping it resident is what
///   makes selection free of reload latency. An implementer must **not** wire a profile-drop into
///   `unload()` (that invariant is about MLX buffers, not arbitrary heap).
/// - **Retrieval is model-independent.** Selection is lexical, so it runs fine while the model is
///   Tier-2-unloaded — priming is never blocked by a reload stall.
/// - **The lost-key downside is neutralized.** The profile is regenerable (it re-learns) and deletable by
///   design, so an unreadable file or a missing key just means "reset", a supported operation.
actor StyleProfileStore {
    /// Written once, then read on every commit — kept in memory for the whole process lifetime.
    private var profile: StyleProfile?
    /// Latched when an existing file could not be decrypted. It suppresses `persist` (see there) — which
    /// is why it must also be *visible*: while it is set, everything learned lives in RAM and dies at
    /// quit, and the transparency view would otherwise list sentences that are already doomed
    /// .
    private var loadFailed = false
    /// Set once a commit has actually **changed** the resident profile while the latch was up. It is what
    /// makes the retry in `ingest` safe: re-reading the file replaces the resident copy, so it may only
    /// happen while that copy still holds nothing the user would lose.
    ///
    /// "Changed", not "ran": `ingest` is a no-op for text that is too short or a near-duplicate of what is
    /// already stored, and latching on a no-op commit would strand a *self-healable* session (a keychain
    /// that unlocks a minute later) in the stall for the rest of the process.
    private var learnedWhileStalled = false

    // Under `NEXTTYPED_PERSONALIZATION=temp` the harness gets its own file +
    // Keychain item, so an opted-in learning scenario can never read or write the user's profile.
    private nonisolated static var fileName: String {
        HarnessEnvironment.personalization == .temp
            ? "style-profile.harness.enc" : "style-profile.enc"
    }
    /// Process-lifetime key for the harness's throwaway profile (never persisted — see `key()`).
    private var ephemeralKey: SymmetricKey?

    private let keychainService = "com.robinklotz.NextTyped.styleProfile"
    private let keychainAccount = HarnessEnvironment.personalization == .temp
        ? "profile-encryption-key.harness" : "profile-encryption-key"

    // MARK: Read paths

    /// Whether the encrypted profile file is on disk. Key-free by design: no decrypt, no Keychain read,
    /// no directory creation, so it is safe to call at launch while learning is off. The harness's
    /// `.off` posture reports no file, because there the store would point at the user's real file.
    nonisolated func profileFileExists() -> Bool {
        if HarnessEnvironment.personalization == .off { return false }
        guard let url = Self.profileURL(createDirectory: false) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Bring the store into memory (called at app start so the first context switch pays no decrypt).
    func preload() {
        _ = current()
    }

    /// A copy for the "what NextTyped has learned from you" view (transparency through
    /// the app, so the file can stay encrypted).
    func snapshot() -> StyleProfile {
        current()
    }

    /// Select the frozen segment for a context switch. Runs **here**, not on the main actor: the scan
    /// tokenizes every stored exemplar, which is a few milliseconds we don't want on the UI thread.
    func select(
        query: String,
        budget: Int,
        termLine: PersonalizationRetrieval.TermLineFormat
    ) -> PersonalizationSelection? {
        PersonalizationRetrieval.select(
            profile: current(), query: query, budget: budget, termLine: termLine)
    }

    // MARK: Write paths

    /// Learn from one field's worth of own-inserted text and persist. The language tag is derived here
    /// (`NLLanguageRecognizer`, on-device, no resident model) so a later **language-selective ship**
    ///  needs no re-learn.
    func ingest(ownText: String) {
        retryLoadIfStalled()
        var profile = current()
        let before = profile.exemplars.count
        let unchanged = profile
        profile.ingest(ownText: ownText, language: Self.dominantLanguage(of: ownText))
        self.profile = profile
        persist(profile)
        if loadFailed, profile != unchanged { learnedWhileStalled = true }
        #if DEBUG
        acLog("[style]: commit chars=%d exemplars=%d(+%d) terms=%d",
              ownText.count, profile.exemplars.count, profile.exemplars.count - before, profile.terms.count)
        #else
        _ = before
        #endif
    }

    /// The one-click reset: drop the resident copy, delete the file **and** the Keychain key.
    /// Deleting the key matters — a surviving key plus a restored backup file would resurrect the profile.
    func reset() {
        profile = StyleProfile()
        loadFailed = false
        learnedWhileStalled = false
        if let url = fileURL() { try? FileManager.default.removeItem(at: url) }
        deleteKey()
        #if DEBUG
        acLog("[style]: reset (file + key deleted)")
        #endif
    }

    /// Whether the store is in the silent RAM-only stall: an existing profile file exists but could not
    /// be decrypted, so nothing learned this session will survive the quit. Read by the Privacy pane and
    /// the transparency view, which offer the reset as the repair (the failure has to be
    /// visible at the surface built to make the feature transparent).
    func isUnreadable() -> Bool {
        _ = current()   // a stall is only known once a load has been attempted
        return loadFailed
    }

    // MARK: Load / persist

    /// Give the file one more chance at each commit. The common cause of a load failure is *transient* —
    /// a keychain still locked during login — and that case self-heals here with no UI at all.
    ///
    /// Only while nothing has been learned since the failure: a successful re-read **replaces** the
    /// resident profile, so retrying after a session's worth of commits would trade a stall for actual
    /// data loss.
    ///
    /// The rule stays here rather than in Core on purpose: it is two flags whose whole meaning
    /// is "what the file IO on the next two lines is allowed to do", and lifting it would buy a test of
    /// `a && !b` at the cost of a Core type that models nothing the domain has a name for.
    private func retryLoadIfStalled() {
        guard loadFailed, !learnedWhileStalled else { return }
        loadFailed = false
        if let recovered = load() {
            profile = recovered
            acLog("[style]: load retry ok — saving resumes")
        }
        // `load()` re-latches on a second failure; a missing file leaves the latch down, which is right —
        // there is no longer anything to protect from being overwritten.
    }

    private func current() -> StyleProfile {
        if let profile { return profile }
        let loaded = load() ?? StyleProfile()
        profile = loaded
        return loaded
    }

    private func load() -> StyleProfile? {
        guard let url = fileURL(), FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let sealed = try AES.GCM.SealedBox(combined: try Data(contentsOf: url))
            let plaintext = try AES.GCM.open(sealed, using: try key())
            return try JSONDecoder().decode(StyleProfile.self, from: plaintext)
        } catch {
            // A corrupt file or a lost key is recoverable by design: start empty and re-learn rather than
            // failing the loop. Do NOT delete the file here — a transient Keychain failure (locked
            // keychain during login) would otherwise destroy a good profile.
            loadFailed = true
            acLog("[style]: load failed (%@) — starting from an empty profile",
                  String(describing: error))
            return nil
        }
    }

    private func persist(_ profile: StyleProfile) {
        guard !loadFailed else {
            // We couldn't read the existing file; overwriting it would turn a temporary failure into
            // permanent data loss. Stay in memory for this session.
            return
        }
        guard let url = fileURL() else { return }
        do {
            let plaintext = try JSONEncoder().encode(profile)
            let sealed = try AES.GCM.seal(plaintext, using: try key())
            guard let combined = sealed.combined else { return }
            try combined.write(to: url, options: [.atomic])
            // Owner-only: the ciphertext needs no help, but the file's existence and size shouldn't be
            // readable by other users on a shared Mac either.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            acLog("[style]: persist failed (%@)", String(describing: error))
        }
    }

    private func fileURL() -> URL? { Self.profileURL(createDirectory: true) }

    /// The one place the profile path is written out; the read path and the menu's existence check both
    /// go through it. `createDirectory: false` leaves the disk untouched.
    private nonisolated static func profileURL(createDirectory: Bool) -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
            create: createDirectory)
        else { return nil }
        let directory = support.appendingPathComponent("com.robinklotz.NextTyped", isDirectory: true)
        if createDirectory, !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: Keychain-held encryption key

    private func key() throws -> SymmetricKey {
        // Harness runs (`NEXTTYPED_PERSONALIZATION=temp`) never touch the Keychain: the
        // profile is throwaway, and a Keychain item whose ACL is bound to the app's signature raises a
        // SecurityAgent password dialog after every rebuild — which would both stall the run and steal
        // the keystrokes the run is posting. An ephemeral per-process key is exactly right for a store
        // that is deleted afterwards.
        if HarnessEnvironment.personalization == .temp {
            if let cached = ephemeralKey { return cached }
            let fresh = SymmetricKey(size: .bits256)
            ephemeralKey = fresh
            return fresh
        }
        if let existing = readKey() { return existing }
        let fresh = SymmetricKey(size: .bits256)
        try storeKey(fresh)
        return fresh
    }

    private func readKey() -> SymmetricKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 32
        else { return nil }
        return SymmetricKey(data: data)
    }

    private func storeKey(_ key: SymmetricKey) throws {
        let status = add(key)
        if status == errSecSuccess { return }
        // A duplicate means an item exists that `readKey` could not use (unreadable, or the wrong size).
        // Returning the fresh key here would seal the profile with a key that was never written — learning
        // would then silently fail to survive every restart, forever, with nothing to repair. So replace
        // the unusable item instead, and surface a genuine failure rather than swallowing it.
        guard status == errSecDuplicateItem else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        deleteKey()
        let retry = add(key)
        guard retry == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(retry))
        }
    }

    private func add(_ key: SymmetricKey) -> OSStatus {
        var attributes = baseQuery()
        attributes[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        // `WhenUnlocked` (not `…ThisDeviceOnly`) so the key follows a migration the way the profile file
        // does; the profile is regenerable either way.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    private func deleteKey() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: keychainAccount]
    }

    // MARK: Language tagging

    /// Dominant language of the committed buffer, for the future language-selective injection gate. Nil
    /// when the recognizer is unsure — nothing depends on it yet, so an unknown tag costs nothing.
    private static func dominantLanguage(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }
}
