/// Whether the disk can take a model download, decided before the Hub download starts.
public enum ModelDiskVerdict: Equatable, Sendable {
    case enough
    case tooSmall(neededBytes: Int64, freeBytes: Int64)

    /// The sentence the Model page shows instead of a failed download; nil when there is room.
    public var message: String? {
        switch self {
        case .enough:
            return nil
        case .tooSmall(let needed, let free):
            return "Not enough free disk space. The model needs \(ByteLabel.gigabytes(needed)) and this Mac has "
                + "\(ByteLabel.gigabytes(free)) free. Free up space, then press Retry."
        }
    }
}

/// The free-disk rule for a model download. The engine reads the free bytes and the bytes already in
/// the Hub cache; this decides.
public enum ModelDiskCheck {
    /// Room left over after the download, so the download does not fill the disk to the last byte.
    public static let headroomBytes: Int64 = 1_073_741_824

    /// A model already fully in the cache downloads nothing, so it is `.enough` whatever the free space:
    /// the engine runs this check on every Hub load, the reload after an idle unload included.
    public static func verdict(downloadBytes: Int64, cachedBytes: Int64, freeBytes: Int64) -> ModelDiskVerdict {
        let missing = downloadBytes - cachedBytes
        if missing <= 0 { return .enough }
        let needed = missing + headroomBytes
        return freeBytes >= needed ? .enough : .tooSmall(neededBytes: needed, freeBytes: freeBytes)
    }
}

/// "820 MB of 3.2 GB" under the Model page's progress bar.
public enum ModelDownloadProgressLine {
    public static func line(fraction: Double, totalBytes: Int64) -> String {
        let clamped = min(max(fraction, 0), 1)
        let done = Int64((Double(totalBytes) * clamped).rounded())
        return "\(ByteLabel.size(done)) of \(sizeLabel(totalBytes: totalBytes))"
    }

    /// The download size alone, as the Model page names it before the download ("3.2 GB").
    public static func sizeLabel(totalBytes: Int64) -> String { ByteLabel.gigabytes(totalBytes) }
}

/// Byte counts as the app writes them: 1024-based units labelled GB and MB, as the model sizes in the
/// picker are ("3.2 GB" is the 4B's 3,438,534,656 bytes).
enum ByteLabel {
    static let gib = 1_073_741_824.0
    static let mib = 1_048_576.0

    static func gigabytes(_ bytes: Int64) -> String {
        let tenths = (Double(bytes) / gib * 10).rounded()
        return "\(Int(tenths) / 10).\(Int(tenths) % 10) GB"
    }

    /// Whole MB below 1 GB, one decimal GB from there.
    static func size(_ bytes: Int64) -> String {
        if Double(bytes) < gib { return "\(Int((Double(bytes) / mib).rounded())) MB" }
        return gigabytes(bytes)
    }
}

extension ShippingModel {
    /// Bytes on disk of each hosted model's snapshot (measured 2026-11-04 from the Hub cache blobs).
    /// Nil for any other repo: an override repo has no known size, so the disk check is skipped.
    public static func downloadBytes(repoId: String) -> Int64? {
        switch repoId {
        case hubRepoId: return 3_438_534_656
        case hub2BRepoId: return 1_549_799_424
        default: return nil
        }
    }
}
