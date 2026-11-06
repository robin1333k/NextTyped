/// Whether a focus change lands on a field NextTyped completes, for the model pre-warm.
///
/// A field is editable here when it passes the `SurfaceEligibility` floor (the `ContextProvider`'s
/// own rejections: no focus, secure field, window chrome, no text) **and** the enablement verdict of
/// its app is `enabled`. A field in a switched-off app never pre-warms, so a password manager or a
/// blocklisted app does not make the 4B load (3.4 GB) on every focus.
public enum FocusEditability {
    /// `nil` means editable. Otherwise the reason, in the same tokens the predict path logs.
    ///
    /// - Parameters:
    ///   - floor: the floor rejection the surface probe found, `nil` when the surface passed it.
    ///   - bundleID: the focused app, `nil` when it exposes none (judged as `""`, like `ContextAssembler`).
    ///   - verdict: the enablement policy, read fresh by the caller.
    public static func rejection(
        floor: ContextRejection?,
        bundleID: String?,
        verdict: (SurfaceIdentity) -> EnablementVerdict
    ) -> ContextRejection? {
        if let floor { return floor }
        return verdict(SurfaceIdentity(bundleID: bundleID ?? "")).rejection
    }
}
