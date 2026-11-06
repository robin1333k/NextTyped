/// What the menu bar and Settings say about the on-device model.
public enum ModelLoadState: Equatable, Sendable {
    case loading
    /// 0...1 of bytes fetched (Hub first-run path only).
    case downloading(Double)
    case ready
    case failed
    /// The weights were released by the residency ladder or "Unload model now". The next prediction reloads.
    case unloaded

    public var menuLabel: String {
        switch self {
        case .loading:              return "Loading model…"
        case .downloading(let f):   return "Downloading model… \(Int((f * 100).rounded()))%"
        case .ready:                return "Model ready"
        case .failed:               return "Model could not load"
        case .unloaded:             return "Model unloaded to save memory"
        }
    }

    /// Whether the menu should offer a Retry button.
    public var isFailed: Bool { self == .failed }

    /// Whether the menu offers "Unload model now": only while the weights are resident and idle.
    public var offersUnloadNow: Bool { self == .ready }

    /// Whether a prediction can run now or after an automatic reload (`ready` or `unloaded`).
    public var canPredict: Bool { self == .ready || self == .unloaded }
}

/// A model transition reported by the engine, in the order it happened.
public enum ModelLoadEvent: Equatable, Sendable {
    case loadingStarted
    case downloading(Double)
    case loadingWeights
    case ready
    case failed
    case unloaded
    /// The disk cannot take the download, checked before it starts. The state is `.failed`; the
    /// verdict carries the numbers for the Model page.
    case diskTooSmall(ModelDiskVerdict)
}

/// The pure rule that folds `ModelLoadEvent`s into a `ModelLoadState`.
public enum ModelLoadStatus {
    public static func apply(_ event: ModelLoadEvent, to state: ModelLoadState) -> ModelLoadState {
        switch event {
        case .ready:                    return .ready
        case .failed, .diskTooSmall:    return .failed
        case .loadingStarted, .loadingWeights: return .loading
        case .unloaded:                 return state == .failed ? .failed : .unloaded
        case .downloading(let fraction):
            switch state {
            case .ready, .failed:       return state   // a late tick never overwrites a verdict
            case .loading, .downloading, .unloaded: return .downloading(fraction)
            }
        }
    }
}
