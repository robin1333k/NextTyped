import AppKit
import Carbon.HIToolbox
import IOKit
import NextTypedCore

/// Polls `IsSecureEventInputEnabled()` once a second and reports the transitions of Core's
/// `SecureInputTracker` (CT-47). While the flag is on, another app's hold blinds our
/// event tap, so the coordinator shows a menu notice and hides the ghost.
///
/// The IORegistry key `kCGSSessionSecureInputPID` outlives the hold, so it is read only while the flag
/// is on; the tracker takes the read as a closure and never calls it otherwise.
@MainActor
final class SecureInputMonitor {
    private var tracker = SecureInputTracker()
    private var timer: Timer?
    /// Called with every transition, so the coordinator can raise or clear the notice.
    var onTransition: ((SecureInputTransition) -> Void)?

    var verdict: SecureInputVerdict { tracker.verdict }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let transitions = tracker.observe(
            enabled: IsSecureEventInputEnabled(),
            now: ProcessInfo.processInfo.systemUptime,
            frontmostPID: frontmost,
            holderPID: { Self.readHolderPID() },
            resolve: { pid in
                NSRunningApplication(processIdentifier: pid).map {
                    SecureInputHolder(bundleID: $0.bundleIdentifier, name: $0.localizedName)
                }
            },
            // Only the frontmost app's own hold can be "expected", so the AX read happens only when
            // the holder is the frontmost app or unresolved.
            focusedIsSecureField: { holder in
                if let holder, holder != frontmost { return false }
                return AXContextProvider.eligibilityFloor().rejection == .secure
            })
        for transition in transitions { onTransition?(transition) }
    }

    /// `kCGSSessionSecureInputPID` from the `IOConsoleUsers` entry of the IORegistry root. Best effort:
    /// Apple documents no reliable lookup, so a missing key gives `nil` (nameless notice).
    private static func readHolderPID() -> Int32? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(
            root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]]
        else { return nil }
        for user in users {
            if let pid = user["kCGSSessionSecureInputPID"] as? Int { return Int32(truncatingIfNeeded: pid) }
        }
        return nil
    }
}
