import NextTypedCore
import Foundation

/// Keeps the Settings → Setup advisory row in step with the OS setting **while the row is on screen**,
/// without our window ever being touched.
///
/// The row is advice about a checkbox in *another* app's window, so the whole duration of the task it
/// describes is time our window spends in the background. Until now the only refresh was incidental —
/// the read happened during `body`, so the pill flipped when something re-rendered the view, activation
/// being the usual trigger. That is precisely backwards: it updated at the one moment the user no
/// longer needed it to.
///
/// **Polling, not observation.** `UserDefaults.didChangeNotification` is process-local and never fires
/// for another process's write, and no distributed notification is documented for this key. A poll
/// degrades honestly where an undocumented notification name would not (the key is treated as
/// soft-use only), so it polls — and the read it polls is the cache-bypassing one, or it would return the
/// stale value for as long as we stay in the background and still test as working the moment anybody
/// clicked into our window to look.
///
/// **Bounded to the row's lifetime.** Started from the view's `onAppear` and stopped from its
/// `onDisappear`, so it runs only while somebody is looking at the row — which also keeps it off the
/// typing path by construction. Selecting another Settings section tears the view down and stops it.
@MainActor
final class InlinePredictionStatusModel: ObservableObject {
    /// What the row should render. Starts `.hidden` so a pane that somehow never polls shows nothing
    /// rather than a guess.
    @Published private(set) var advisory: InlinePredictionAdvisory = .hidden

    /// Which button the row offers, decided by Core's `toggleAction(for:)` from the last reading.
    @Published private(set) var toggle: InlinePredictionToggleAction = .turnOff

    /// One second: fast enough to read as immediate when the user unticks the checkbox, and one
    /// preference read is microseconds.
    private static let pollInterval = Duration.seconds(1)

    /// Set when the last click did not stick; the row then points at the manual steps.
    @Published private(set) var lastClickFailed = false

    private var pollTask: Task<Void, Never>?
    private var lastReading: OSInlinePredictionReading?

    func startPolling() {
        guard pollTask == nil else { return }
        refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// The button's action, run only from a click.
    func perform(_ action: InlinePredictionToggleAction) {
        let sw = OSInlinePredictionSwitch(store: InlinePredictionNudge.GlobalStore())
        let result = action == .turnOff ? sw.turnOff() : sw.turnBackOn()
        switch result {
        case .changed: lastClickFailed = false
        case .notApplied: lastClickFailed = true
        }
        #if DEBUG
        acLog("[nudge]: os inline prediction toggle action=\(action.rawValue) result=\(result)")
        #endif
        refresh()
    }

    private func refresh() {
        let reading = InlinePredictionNudge.osInlinePredictionReading
        guard reading != lastReading else { return }
        lastReading = reading
        advisory = InlinePredictionStatus.advisory(for: reading)
        toggle = InlinePredictionStatus.toggleAction(for: reading)
        #if DEBUG
        // Logged on change only. This is the sole evidence available for the acceptance criterion,
        // which forbids activating our window — and an unchanged reading logged every second would
        // bury it.
        acLog("[nudge]: os inline prediction reading=\(reading.rawValue) advisory=\(advisory.rawValue)")
        #endif
    }
}
