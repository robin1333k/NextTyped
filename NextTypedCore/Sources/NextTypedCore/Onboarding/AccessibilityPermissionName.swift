/// The name System Settings gives the list where NextTyped's Accessibility permission lives.
/// macOS 27 renamed the list to "Device Control and Data Access", so a user who looks for
/// "Accessibility" would not find it. Pure, so the OS-version rule is tested without a Mac of each version.
public enum AccessibilityPermissionName {
    /// First macOS major version that uses the new list title.
    public static let renamedInMajorVersion = 27

    /// The list title in System Settings → Privacy & Security.
    public static func listTitle(osMajorVersion: Int) -> String {
        osMajorVersion >= renamedInMajorVersion ? "Device Control and Data Access" : "Accessibility"
    }

    /// One sentence that tells the user where to find the list by hand.
    public static func findHint(osMajorVersion: Int) -> String {
        "In System Settings, open Privacy & Security and choose \(listTitle(osMajorVersion: osMajorVersion))."
    }
}
