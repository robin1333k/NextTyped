import AppKit
import NextTypedCore

/// Offers to move the running bundle to Applications (CT-80). The decision lives in Core
/// (`MoveToApplicationsPolicy`); this file classifies the path, shows the alert, copies and relaunches.
@MainActor
enum MoveToApplications {
    static let declinedKey = "moveToApplicationsDeclined"
    /// Set by the old copy when launch at login was on; the relaunched copy registers itself from its
    /// own path and clears the key.
    static let reregisterLaunchAtLoginKey = "moveToApplicationsReregisterLaunchAtLogin"

    enum CopyError: Error { case copy, launch }

    // MARK: Entry point

    /// Runs at launch, before `PermissionsOnboarding`. Returns true when the app is quitting for the
    /// relaunch of the moved copy; the caller must then not continue starting.
    static func runAtLaunch() -> Bool {
        consumeLaunchAtLoginReregistration()
        let bundleURL = Bundle.main.bundleURL
        let home = NSHomeDirectory()
        let location = MoveToApplicationsPolicy.classify(bundlePath: bundleURL.path, home: home)
        let decision = MoveToApplicationsPolicy.decide(
            location: location,
            harnessActive: HarnessEnvironment.isActive,
            declined: UserDefaults.standard.bool(forKey: declinedKey))
        log(decision.logLine)
        guard case .offer = decision else { return false }
        // A quarantined app runs translocated; the old copy to dispose of is at the original path.
        let origin = originalURL(of: bundleURL)
        let originClass = MoveToApplicationsPolicy.classify(bundlePath: origin.path, home: home)
        log("[install]: origin class=\(originClass.rawValue)")
        if originClass == .translocated {
            // The original path could not be resolved; copying could delete the source behind the mount.
            log("[install]: skip reason=origin-unresolved")
            return false
        }
        return presentOffer(bundleURL: bundleURL, origin: origin, originClass: originClass)
    }

    // MARK: Alert

    private static func presentOffer(bundleURL: URL, origin: URL, originClass: MoveToApplicationsPolicy.BundleLocation) -> Bool {
        let targetDir = chooseTargetDirectory()
        let target = targetDir.appendingPathComponent(bundleURL.lastPathComponent)
        let replacing = exists(atLinkPath: target.path)

        let alert = NSAlert()
        alert.messageText = "Move NextTyped to Applications?"
        var info = "It needs to run from there for the Accessibility permission to stick."
        if replacing { info += " An older copy in that folder will be replaced." }
        alert.informativeText = info
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Not now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let dontAsk = alert.suppressionButton?.state == .on
        guard response == .alertFirstButtonReturn else {
            if dontAsk { UserDefaults.standard.set(true, forKey: declinedKey) }
            log("[install]: declined")
            return false
        }

        let hadLaunchAtLogin = LaunchAtLogin.isEnabled
        let newCopy: URL
        switch MoveToApplicationsPolicy.installStep(originClass: originClass, originPath: origin.path, targetPath: target.path) {
        case .relaunchInPlace:
            // Already installed: copying would delete the source behind the translocation mount.
            newCopy = origin
            stripQuarantine(at: origin)
            log("[install]: step=relaunch-in-place")
        case .copy:
            do {
                newCopy = try installCopy(of: bundleURL, into: targetDir)
            } catch {
                log("[install]: failed step=copy")
                return false
            }
        }
        if hadLaunchAtLogin {
            UserDefaults.standard.set(true, forKey: reregisterLaunchAtLoginKey)
            try? LaunchAtLogin.setEnabled(false)
        }
        guard launch(newCopy) else {
            UserDefaults.standard.removeObject(forKey: reregisterLaunchAtLoginKey)
            if hadLaunchAtLogin { try? LaunchAtLogin.setEnabled(true) }
            log("[install]: failed step=launch")
            return false
        }
        log("[install]: moved")
        if newCopy != origin { disposeOfOldCopy(origin, originClass: originClass) }
        // The new instance is starting; quit this one once the launch call has been made.
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return true
    }

    // MARK: Copy (takes the target directory so a script can test it)

    /// `/Applications` when the user can write there, else `~/Applications` (created if needed).
    static func chooseTargetDirectory(system: String = "/Applications", home: String = NSHomeDirectory()) -> URL {
        let writable = FileManager.default.isWritableFile(atPath: system)
        let path = MoveToApplicationsPolicy.targetDirectory(system: system, systemWritable: writable, home: home)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Copies `source` into `directory`, replacing what is at the target and clearing quarantine on the
    /// copy so it is not translocated itself. A symlink at the target is removed as a link, never
    /// resolved (on a dev machine `/Applications/NextTyped.app` can point at a Debug build).
    @discardableResult
    static func installCopy(of source: URL, into directory: URL) throws -> URL {
        let fm = FileManager.default
        let target = directory.appendingPathComponent(source.lastPathComponent)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let temp = directory.appendingPathComponent(".\(source.lastPathComponent).installing")
            if exists(atLinkPath: temp.path) { try fm.removeItem(at: temp) }
            try fm.copyItem(at: source, to: temp)
            // Only after the copy succeeded is the old target removed (a symlink as a link).
            if exists(atLinkPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: temp, to: target)
        } catch {
            throw CopyError.copy
        }
        stripQuarantine(at: target)
        return target
    }

    /// True when anything, including a dangling symlink, is at `path`. Does not follow links.
    static func exists(atLinkPath path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    private static func stripQuarantine(at url: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-dr", "com.apple.quarantine", url.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    // MARK: Relaunch and cleanup

    private static func launch(_ url: URL) -> Bool {
        // `open -n` semantics: a second instance of the same bundle ID, since this one is still alive.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", url.path]
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// The path a translocated bundle was launched from, via `SecTranslocateCreateOriginalPathForURL`
    /// (private, so loaded with dlsym as LetsMove does). Returns `url` itself when it is not translocated
    /// or the symbol is missing.
    static func originalURL(of url: URL) -> URL {
        typealias Fn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecTranslocateCreateOriginalPathForURL")  // RTLD_DEFAULT
        else { return url }
        let fn = unsafeBitCast(sym, to: Fn.self)
        var err: Unmanaged<CFError>?
        guard let out = fn(url as CFURL, &err) else { err?.release(); return url }
        return out.takeRetainedValue() as URL
    }

    private static func disposeOfOldCopy(_ old: URL, originClass: MoveToApplicationsPolicy.BundleLocation) {
        let volumeIsDiskImage = originClass == .diskImage && isMountedDiskImage(volumeOf: old.path)
        switch MoveToApplicationsPolicy.disposal(originClass: originClass, originPath: old.path, volumeIsDiskImage: volumeIsDiskImage) {
        case .trash:
            let ok = (try? FileManager.default.trashItem(at: old, resultingItemURL: nil)) != nil
            log("[install]: dispose action=trash ok=\(ok)")
        case .eject(let volume):
            // This process still runs from the volume, so an eject now would fail as busy. A detached
            // helper waits for our pid to exit, then ejects.
            let ok = ejectAfterExit(volume: volume)
            log("[install]: dispose action=eject deferred=true ok=\(ok)")
        case .leave:
            log("[install]: dispose action=leave")
        }
    }

    /// Starts `/bin/sh` detached: it polls until this pid is gone (at most 60 s), then runs `diskutil eject`.
    private static func ejectAfterExit(volume: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c",
            "i=0; while kill -0 \"$1\" 2>/dev/null && [ $i -lt 120 ]; do sleep 0.5; i=$((i+1)); done; /usr/sbin/diskutil eject \"$2\"",
            "sh", String(ProcessInfo.processInfo.processIdentifier), volume]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        return true
    }

    /// True when `/Volumes/<name>` of `path` is a mount point listed by `hdiutil info`, i.e. a mounted
    /// disk image and not an external drive.
    private static func isMountedDiskImage(volumeOf path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return false }
        let volume = "/Volumes/" + parts[1]
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["info", "-plist"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return false }
        return images.contains { image in
            ((image["system-entities"] as? [[String: Any]]) ?? []).contains { $0["mount-point"] as? String == volume }
        }
    }

    private static func consumeLaunchAtLoginReregistration() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: reregisterLaunchAtLoginKey) else { return }
        defaults.removeObject(forKey: reregisterLaunchAtLoginKey)
        try? LaunchAtLogin.setEnabled(true)
    }

    private static func log(_ line: String) {
        #if DEBUG
        acLog("%@", line)
        #endif
    }
}
