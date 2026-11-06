import Foundation

/// The user's choice of when the model leaves RAM (Settings → General → Model). Stored as a string under the
/// `modelUnloadAfterIdle` default. The raw values are part of
/// the stored format: do not rename them.
public enum ModelUnloadSetting: String, CaseIterable, Sendable {
    /// Today's rule: unload 150 s after you leave the writing app, and on lock or sleep. The default.
    case automatic
    case min2
    case min5
    case min15
    case hour1
    case never
    /// 15 seconds, for the VM harness. Read as `.automatic` outside DEBUG builds.
    case sec15

    /// A missing or unknown string reads as `.automatic`; so does `sec15` when `allowDebugValues` is false.
    public init(storedValue: String?, allowDebugValues: Bool) {
        guard let storedValue, let value = ModelUnloadSetting(rawValue: storedValue),
              value != .sec15 || allowDebugValues
        else {
            self = .automatic
            return
        }
        self = value
    }

    /// The residency rule this choice stands for.
    public var rule: ModelResidencyPolicy.UnloadRule {
        switch self {
        case .automatic: .whenAway(absenceSeconds: 150)
        case .min2: .afterIdle(seconds: 120)
        case .min5: .afterIdle(seconds: 300)
        case .min15: .afterIdle(seconds: 900)
        case .hour1: .afterIdle(seconds: 3600)
        case .sec15: .afterIdle(seconds: 15)
        case .never: .never
        }
    }

    /// The picker entries in display order; the debug value comes last and only when allowed.
    public static func pickerCases(allowDebugValues: Bool) -> [ModelUnloadSetting] {
        var cases: [ModelUnloadSetting] = [.automatic, .min2, .min5, .min15, .hour1, .never]
        if allowDebugValues { cases.append(.sec15) }
        return cases
    }
}
