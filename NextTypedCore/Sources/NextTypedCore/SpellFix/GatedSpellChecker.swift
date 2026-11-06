/// The user's "Suggest spelling fixes" switch (General). Wraps any `SpellChecker`:
/// while the switch is off it returns a clean verdict without asking the base, so no spell check runs and
/// the continuation ghost is untouched. The switch is read on every call, so a change applies to
/// the next keystroke.
public struct GatedSpellChecker: SpellChecker {
    private let base: any SpellChecker
    private let isEnabled: @Sendable () -> Bool
    private let log: @Sendable (String) -> Void

    public init(
        base: any SpellChecker,
        isEnabled: @escaping @Sendable () -> Bool,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.base = base
        self.isEnabled = isEnabled
        self.log = log
    }

    public func verdict(for context: TypingContext) async -> SpellVerdict {
        guard isEnabled() else {
            log("[gate]: spelling-fix off reason=user")
            return .clean(nil)
        }
        return await base.verdict(for: context)
    }
}
