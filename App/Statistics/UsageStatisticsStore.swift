import NextTypedCore
import Foundation

/// The at-rest half of local usage statistics: a `Codable` JSON file in
/// Application Support, written owner-only, holding **counts and bundle IDs — never text**.
///
/// **Why this file is not encrypted, when the style profile is.** The style profile stores the user's own
/// sentences, so its file is the sensitive artefact and AES-GCM + a Keychain key is proportionate. This
/// store holds integers and app identifiers; wrapping them in the same machinery would buy little and
/// cost the known failure mode of an orphaned Keychain key turning the store
/// silently RAM-only. It would also make the file unreadable to the one person entitled to audit it. So:
/// plain JSON at `0600`, in the same owner-only directory, deletable from the Statistics pane.
///
/// **Writes are debounced.** A batch arrives roughly per predict, which is far too often for disk IO;
/// the resident copy is authoritative and the file catches up a couple of seconds later (immediately on
/// reset). The worst case — a crash or a quit — costs those two seconds of counters, which is the right
/// trade against a file write per keystroke.
actor UsageStatisticsStore {
    private var statistics: UsageStatistics?
    private var saveTask: Task<Void, Never>?
    private var dirty = false

    /// How long a change may sit in memory before it reaches the file. Short, because nothing
    /// asynchronous is guaranteed to run at termination: this window *is* what a quit can cost.
    private static let saveDebounce: Duration = .seconds(2)

    /// A harness run types real keystrokes into a real app, and those must no more pollute the
    /// user's statistics than they may reach the user's style profile — so a run writes its own file.
    private static let userFileName = "usage-statistics.json"
    private let fileName = HarnessEnvironment.isActive
        ? "usage-statistics.harness.json" : UsageStatisticsStore.userFileName

    // MARK: Read paths

    /// Bring the file into memory (called at app start so the first flush pays no decode).
    func preload() {
        // A harness run starts from zero, so a scenario can assert the menu-bar figure without
        // knowing what an earlier run accepted. `fileName` is `usage-statistics.harness.json` under the
        // harness (since the store was written), so this deletes the run's own file; the guard on the name
        // makes sure the user's `usage-statistics.json` can never be the one removed.
        if HarnessEnvironment.isActive, fileName != Self.userFileName, let url = fileURL() {
            try? FileManager.default.removeItem(at: url)
        }
        _ = current()
    }

    /// A copy for the Statistics pane — this store's whole transparency surface.
    func snapshot() -> UsageStatistics {
        current()
    }

    // MARK: Write paths

    /// Fold one flushed batch into `day`. Retention is enforced by `record` itself, so the file cannot
    /// outgrow the 90-day window however long the process runs.
    func record(_ batch: UsageBatch, on day: UsageDay) {
        guard !batch.isEmpty else { return }
        var statistics = current()
        statistics.record(batch, on: day)
        self.statistics = statistics
        scheduleSave()
    }

    /// The Statistics pane's reset: drop the resident copy **and** the file.
    func reset() {
        statistics = UsageStatistics()
        saveTask?.cancel()
        saveTask = nil
        dirty = false
        if let url = fileURL() { try? FileManager.default.removeItem(at: url) }
        #if DEBUG
        acLog("[stats]: reset (file deleted)")
        #endif
    }

    /// Write now — at shutdown, so a quit does not cost the debounce window.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        persistIfDirty()
    }

    // MARK: Load / persist

    private func current() -> UsageStatistics {
        if let statistics { return statistics }
        let loaded = load() ?? UsageStatistics()
        statistics = loaded
        return loaded
    }

    private func load() -> UsageStatistics? {
        guard let url = fileURL(), FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(UsageStatistics.self, from: try Data(contentsOf: url))
        } catch {
            // Counters are not worth failing over: start empty and count again. Unlike the style profile
            // there is nothing here to protect from an overwrite, so no stall latch is needed either.
            acLog("[stats]: load failed (%@) — starting from empty counters", String(describing: error))
            return nil
        }
    }

    private func scheduleSave() {
        dirty = true
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            await self?.persistAfterDebounce()
        }
    }

    private func persistAfterDebounce() {
        saveTask = nil
        persistIfDirty()
    }

    private func persistIfDirty() {
        guard dirty, let statistics, let url = fileURL() else { return }
        dirty = false
        do {
            try JSONEncoder().encode(statistics).write(to: url, options: [.atomic])
            // Owner-only: what the user writes in which app is nobody else's business on a shared Mac.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            acLog("[stats]: persist failed (%@)", String(describing: error))
        }
    }

    private func fileURL() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        let directory = support.appendingPathComponent("com.robinklotz.NextTyped", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }
}
