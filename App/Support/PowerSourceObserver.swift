import NextTypedCore
import Foundation
import IOKit.ps

/// Reports where the Mac draws power from. Reads `IOPSGetProvidingPowerSourceType` once at
/// `start` and again on every IOKit power-source notification. "Battery Power" maps to `.battery`,
/// every other answer (AC, UPS, unknown) to `.ac`, so an unreadable source never silences suggestions.
///
/// In DEBUG builds the `powerSourceOverride` defaults key (`battery` or `ac`) wins and IOKit is
/// ignored, which is how the harness drives the battery posture on a desktop.
@MainActor
final class PowerSourceObserver {
    private(set) var current: PowerSource = .ac
    private var runLoopSource: CFRunLoopSource?
    private var onChange: ((PowerSource) -> Void)?

    /// Reads the source, reports it once through `onChange`, then reports each later change.
    func start(onChange: @escaping (PowerSource) -> Void) {
        self.onChange = onChange
        current = Self.read()
        onChange(current)
        #if DEBUG
        if Self.override != nil { return }
        #endif
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let observer = Unmanaged<PowerSourceObserver>.fromOpaque(context).takeUnretainedValue()
            // The source is added to the main run loop, so this callback already runs on the main thread.
            MainActor.assumeIsolated { observer.refresh() }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else {
            return
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    func stop() {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode) }
        runLoopSource = nil
        onChange = nil
    }

    private func refresh() {
        let now = Self.read()
        guard now != current else { return }
        current = now
        onChange?(now)
    }

    private static func read() -> PowerSource {
        #if DEBUG
        if let override { return override }
        #endif
        guard let type = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as String? else {
            return .ac
        }
        return type == kIOPMBatteryPowerKey ? .battery : .ac
    }

    #if DEBUG
    private static var override: PowerSource? {
        UserDefaults.standard.string(forKey: "powerSourceOverride").flatMap(PowerSource.init(rawValue:))
    }
    #endif
}
