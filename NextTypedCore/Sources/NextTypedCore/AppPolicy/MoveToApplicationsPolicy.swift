/// Decides whether the app offers to move itself to Applications at launch (CT-80).
///
/// A quarantined app launched from a disk image or from Downloads runs from a random read-only path
/// (App Translocation): the Accessibility grant does not stick, launch at login points at a path that
/// vanishes, and Sparkle cannot update it. The App classifies the bundle path into a
/// ``BundleLocation``; this type turns that and two flags into a decision. Pure, no AppKit.
public enum MoveToApplicationsPolicy {
    /// Where the running bundle lives, as classified by the App from its path.
    public enum BundleLocation: String, Sendable, Equatable, CaseIterable {
        case diskImage      // under /Volumes/
        case downloads      // ~/Downloads
        case translocated   // App Translocation path
        case applications   // /Applications or ~/Applications
        case developer      // DerivedData, the repo's build/ folder, a worktree build
        case other
    }

    public enum SkipReason: String, Sendable, Equatable {
        case inApplications = "in-applications"
        case developer
        case harness
        case declined
        case otherLocation = "other-location"
    }

    public enum Decision: Sendable, Equatable {
        case offer(from: BundleLocation)
        case skip(reason: SkipReason)

        /// The category written after `[install]:`, never a path.
        public var logLine: String {
            switch self {
            case .offer(let from): return "[install]: offer from=\(from.rawValue)"
            case .skip(let reason): return "[install]: skip reason=\(reason.rawValue)"
            }
        }
    }

    public static func decide(location: BundleLocation, harnessActive: Bool, declined: Bool) -> Decision {
        // A harness run must never pop an alert in front of the fixture, wherever the bundle sits.
        if harnessActive { return .skip(reason: .harness) }
        switch location {
        case .applications: return .skip(reason: .inApplications)
        case .developer: return .skip(reason: .developer)
        case .other: return .skip(reason: .otherLocation)
        case .diskImage, .downloads, .translocated:
            return declined ? .skip(reason: .declined) : .offer(from: location)
        }
    }

    /// Classifies a bundle path. `home` is the user's home directory. Order matters: translocated first, then developer paths, then `/Volumes/`. A path under `/Volumes/` may be an external drive, not a disk image; ``disposal`` handles that.
    public static func classify(bundlePath: String, home: String) -> BundleLocation {
        let path = bundlePath
        if path.contains("/AppTranslocation/") { return .translocated }
        // Developer paths come before /Volumes/, so a dev build on an external volume is not offered.
        if path.contains("/DerivedData/") || path.contains("/build/") || path.contains("/.worktrees")
            || path.contains("/Library/Caches/NextTyped/derived/") { return .developer }
        if path.hasPrefix("/Volumes/") { return .diskImage }
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") { return .applications }
        if path.hasPrefix(home + "/Downloads/") { return .downloads }
        return .other
    }

    /// What to do with the old copy once the moved copy has launched.
    public enum Disposal: Sendable, Equatable {
        case trash
        case eject(volume: String)   // the mount point, "/Volumes/<name>"
        case leave
    }

    /// Chooses the disposal by the class of the ORIGINAL path. A quarantined app runs from a translocated
    /// path, so the App resolves the original first and passes its class and path here.
    /// `volumeIsDiskImage` says whether the `/Volumes/<name>` mount is a mounted disk image (the App
    /// asks `hdiutil info`). An external drive is never ejected: it gets `.leave`.
    public static func disposal(originClass: BundleLocation, originPath: String, volumeIsDiskImage: Bool) -> Disposal {
        switch originClass {
        case .downloads: return .trash
        case .diskImage:
            let parts = originPath.split(separator: "/", omittingEmptySubsequences: true)  // ["Volumes", name,...]
            guard volumeIsDiskImage, parts.count >= 2, parts[0] == "Volumes" else { return .leave }
            return .eject(volume: "/Volumes/" + parts[1])
        case .translocated, .applications, .developer, .other: return .leave
        }
    }

    /// `system` (normally `/Applications`) when the user can write there, else `<home>/Applications`.
    public static func targetDirectory(system: String, systemWritable: Bool, home: String) -> String {
        systemWritable ? system : home + "/Applications"
    }

    /// How the move gets the app into the target folder.
    public enum InstallStep: Sendable, Equatable {
        case copy             // copy the bundle to the target, then launch the copy
        case relaunchInPlace  // the original is already installed: strip quarantine there, launch it, copy nothing
    }

    /// A translocated bundle whose original already sits in Applications (put there by `mv` or an unzip
    /// tool) must not be copied: the target is the original, and replacing it would delete the source
    /// behind the translocation mount.
    public static func installStep(originClass: BundleLocation, originPath: String, targetPath: String) -> InstallStep {
        if originClass == .applications || originPath == targetPath { return .relaunchInPlace }
        return .copy
    }
}
