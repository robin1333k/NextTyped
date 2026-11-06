/// The onboarding pages in the order a fresh launch shows them. The Tab demo comes
/// first, so the user sees what the app does before macOS asks for a permission or the model downloads.
public enum OnboardingPage: Int, CaseIterable, Sendable {
    /// A canned completion drawn in our own window: no model, no permission.
    case tryTab
    /// The Accessibility switch, with our own drawing of it.
    case permission
    /// Download size, progress, the free-disk check and the licence line.
    case model
    /// The real loop in a practice field (`TabPracticeProgress`), always last.
    case practice
}

/// Which onboarding page shows, as a pure reducer. The App feeds it button presses and the live
/// Accessibility state; it never reads a clock or the OS.
public struct OnboardingFlow: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case next
        case back
        /// The Accessibility state read by `PermissionsModel`, sent on every poll or activation.
        case accessibilityChanged(Bool)
    }

    public private(set) var page: OnboardingPage = .tryTab
    public private(set) var accessibilityGranted: Bool

    /// `page` other than `.tryTab` is for the snapshot renderer, which draws each page on its own.
    public init(accessibilityGranted: Bool, page: OnboardingPage = .tryTab) {
        self.accessibilityGranted = accessibilityGranted
        self.page = page
    }

    public var canGoBack: Bool { page != .tryTab }

    /// The permission page holds until Accessibility is granted: every later page needs it. The last
    /// page has no next.
    public var canGoNext: Bool {
        switch page {
        case .tryTab, .model: return true
        case .permission: return accessibilityGranted
        case .practice: return false
        }
    }

    public mutating func apply(_ event: Event) {
        switch event {
        case .next:
            guard canGoNext, let next = OnboardingPage(rawValue: page.rawValue + 1) else { return }
            page = next
        case .back:
            guard let previous = OnboardingPage(rawValue: page.rawValue - 1) else { return }
            page = previous
        case .accessibilityChanged(let granted):
            let flipped = granted && !accessibilityGranted
            accessibilityGranted = granted
            // Only the flip advances, so going Back to an already granted permission page stays there.
            if flipped, page == .permission { page = .model }
        }
    }
}

/// The canned completion on the first onboarding page. It is a demo, drawn by the App in its own
/// window: no model runs, no permission is needed, and the loop never sees it.
public struct TabDemo: Equatable, Sendable {
    public static let start = "Thanks for the update. I will send the"
    public static let words = [" report", " by", " Friday."]

    private var acceptedCount = 0

    public init() {}

    /// The text left of the caret: the start plus every accepted word.
    public var typed: String { Self.start + Self.words.prefix(acceptedCount).joined() }
    /// The gray part not yet accepted.
    public var ghost: String { Self.words.dropFirst(acceptedCount).joined() }
    public var isDone: Bool { acceptedCount == Self.words.count }

    /// The action the user's bindings map the pressed key to (`InterceptBindings.action(for:)`), or nil.
    public mutating func apply(_ action: InterceptAction?) {
        switch action {
        case .acceptWord?: acceptedCount = min(acceptedCount + 1, Self.words.count)
        case .acceptAll?: acceptedCount = Self.words.count
        case .dismiss?, nil: break
        }
    }

    public mutating func restart() { acceptedCount = 0 }
}
