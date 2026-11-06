/// The synchronous verdict the global event tap returns to macOS for a keyDown: pass the key on to
/// the host app, or swallow it (we handled it — e.g. `Tab` accepting a ghost word).
///
/// Lifted into Core (from the App's `EventTapController`) so `SuggestionSession.interceptKey` can
/// return it: the tap callback must answer **synchronously**, and the suppress/passThrough rule is a
/// decision (Esc dismisses the ghost yet still passes through to the host) that belongs in tested
/// Core, not the untestable App shell. The App's `EventTapController` consumes this same
/// type — `.suppress` drops the event, `.passThrough` forwards it.
public enum TapDecision: Equatable, Sendable {
    case passThrough
    case suppress
}
