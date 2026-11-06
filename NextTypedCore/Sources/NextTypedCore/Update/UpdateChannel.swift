import Foundation

/// The update channel the user picks in Settings → About (`updateChannel`). Sparkle's default channel is the empty one, so an appcast item without a
/// `<sparkle:channel>` belongs to every user and an item tagged `beta` only to those who chose Beta.
/// The filter runs on the Mac; the request never names the channel.
public enum UpdateChannel: String, Sendable, CaseIterable, Equatable {
    case stable
    case beta

    /// The channel names Sparkle may offer on top of the default channel.
    public var allowedSparkleChannels: Set<String> {
        switch self {
        case .stable: return []
        case .beta: return ["beta"]
        }
    }

    /// Reads the stored `defaults` string; anything unknown or missing is `stable`.
    public init(storedValue: String?) {
        self = storedValue.flatMap(UpdateChannel.init(rawValue:)) ?? .stable
    }
}

/// Whether the updater may start at launch. It never starts in a harness run, so no test run
/// contacts a feed.
public enum UpdaterStartPolicy {
    public enum Decision: Equatable, Sendable {
        case start
        case skip(reason: String)
    }

    public static func decision(environment: [String: String]) -> Decision {
        if let socket = environment["NEXTTYPED_HARNESS_SOCKET"], !socket.isEmpty {
            return .skip(reason: "harness")
        }
        if environment["NEXTTYPED_ENGINE"] == "fake" {
            return .skip(reason: "harness")
        }
        return .start
    }
}
