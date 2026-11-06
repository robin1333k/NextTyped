import NextTypedCore
import Foundation

/// Reads the two numbers the free-disk check needs: the free bytes on the home volume and the
/// bytes of this repo already in the Hub cache. The rule itself is pure Core (`ModelDiskCheck`).
enum ModelDiskReader {
    /// Nil when the repo has no known size (an override repo) or the volume cannot be read: the
    /// download then goes ahead as before.
    static func verdict(repoId: String) -> ModelDiskVerdict? {
        guard let downloadBytes = ShippingModel.downloadBytes(repoId: repoId),
              let freeBytes = freeBytes() else { return nil }
        return ModelDiskCheck.verdict(downloadBytes: downloadBytes, cachedBytes: cachedBytes(repoId: repoId),
                                      freeBytes: freeBytes)
    }

    static func freeBytes() -> Int64? {
#if DEBUG
        // Test seam for the too-small path: `defaults write com.robinklotz.NextTyped
        // debugModelFreeDiskBytes -int 1000000` makes the next Hub load refuse without touching the disk.
        let override = UserDefaults.standard.object(forKey: "debugModelFreeDiskBytes") as? NSNumber
        if let override { return override.int64Value }
#endif
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Bytes under `models--<org>--<name>/blobs` in the Hub cache (`HF_HUB_CACHE`, else
    /// `HF_HOME/hub`, else `~/.cache/huggingface/hub`), so a resumed or cached download needs less room.
    static func cachedBytes(repoId: String) -> Int64 {
        let environment = ProcessInfo.processInfo.environment
        let root: URL
        if let hubCache = environment["HF_HUB_CACHE"], !hubCache.isEmpty {
            root = URL(fileURLWithPath: hubCache)
        } else if let home = environment["HF_HOME"], !home.isEmpty {
            root = URL(fileURLWithPath: home).appendingPathComponent("hub")
        } else {
            root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/huggingface/hub")
        }
        let folder = "models--" + repoId.replacingOccurrences(of: "/", with: "--")
        let blobs = root.appendingPathComponent(folder).appendingPathComponent("blobs")
        guard let files = FileManager.default.enumerator(at: blobs, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
