import NextTypedCore
import Foundation
import Sparkle

/// Owns the one `SPUStandardUpdaterController`.
///
/// The updater starts at launch only when `UpdaterStartPolicy` allows it, so a harness run or the fake
/// engine never contacts a feed. What the check sends is fixed: one HTTPS GET of
/// `SUFeedURL`, no query, no system profile, no identifier. Release builds read nothing from the
/// environment (`HarnessEnvironment` ignores it there), so the policy gets an empty environment.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateController()

    nonisolated static let channelKey = "updateChannel"
    /// DEBUG builds only: a feed URL for the local end-to-end test (`scripts/test-sparkle-local.sh`).
    nonisolated static let feedOverrideKey = "updateFeedURLOverride"

    private var sparkle: SPUStandardUpdaterController?
    private var autoCheckObservation: NSKeyValueObservation?

    /// True once the updater runs; false under the harness, or when Sparkle refused to start.
    @Published private(set) var isRunning = false
    /// Mirrors `SPUUpdater.automaticallyChecksForUpdates`. False until the user answers Sparkle's
    /// question on the second launch, or flips the About toggle.
    @Published private(set) var automaticChecks = false
    @Published private(set) var channel: UpdateChannel = UpdateController.storedChannel()

    private static func storedChannel() -> UpdateChannel {
        UpdateChannel(storedValue: UserDefaults.standard.string(forKey: channelKey))
    }

    /// Called once from `AppCoordinator.start()`. Logs `[update]: start...` or `[update]: skipped...`.
    func start() {
        guard sparkle == nil else { return }
        let environment: [String: String]
        #if DEBUG
        environment = ProcessInfo.processInfo.environment
        #else
        environment = [:]
        #endif
        switch UpdaterStartPolicy.decision(environment: environment) {
        case .skip(let reason):
            acLog("[update]: skipped reason=%@", reason)
            return
        case .start:
            break
        }
        channel = Self.storedChannel()
        // Not started by the initializer: a start error (a bad public key) is logged here instead of
        // opening a Sparkle alert on every launch.
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do {
            try controller.updater.start()
        } catch {
            acLog("[update]: start-failed error=%@", String(describing: error))
            return
        }
        sparkle = controller
        isRunning = true
        automaticChecks = controller.updater.automaticallyChecksForUpdates
        // Sparkle's second-launch prompt changes this property without going through setAutomaticChecks.
        autoCheckObservation = controller.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) {
            [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self, self.automaticChecks != value else { return }
                self.automaticChecks = value
                acLog("[update]: auto=%d source=sparkle", value ? 1 : 0)
            }
        }
        acLog("[update]: start channel=%@ auto=%d", channel.rawValue, automaticChecks ? 1 : 0)
    }

    var canCheckForUpdates: Bool { sparkle?.updater.canCheckForUpdates ?? false }

    /// "Check for Updates..." in the menu bar and in About. One request to the feed, on demand.
    func checkForUpdates() {
        guard let sparkle else { return }
        acLog("[update]: check manual")
        sparkle.checkForUpdates(nil)
    }

    /// Re-reads the updater's flag; About and Privacy call it when they appear, as a second path
    /// next to the observation.
    func refreshAutomaticChecks() {
        guard let sparkle else { return }
        automaticChecks = sparkle.updater.automaticallyChecksForUpdates
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard let sparkle else { return }
        sparkle.updater.automaticallyChecksForUpdates = enabled
        automaticChecks = sparkle.updater.automaticallyChecksForUpdates
        acLog("[update]: auto=%d", automaticChecks ? 1 : 0)
    }

    func setChannel(_ newChannel: UpdateChannel) {
        UserDefaults.standard.set(newChannel.rawValue, forKey: Self.channelKey)
        channel = newChannel
        acLog("[update]: channel=%@", newChannel.rawValue)
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        // Read from defaults, not from the main-actor property: Sparkle calls this off the main actor.
        UpdateChannel(storedValue: UserDefaults.standard.string(forKey: Self.channelKey)).allowedSparkleChannels
    }

    #if DEBUG
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        let value = UserDefaults.standard.string(forKey: Self.feedOverrideKey)
        return (value?.isEmpty ?? true) ? nil : value
    }
    #endif
}
