import NextTypedCore
import Foundation

/// The App half of ``UsageDay``: Core counts days as ordinals and never asks what today is, so the
/// calendar — time zone, DST, the user's locale — lives here, on the side of the boundary that has one.
///
/// The two directions are inverses **of each other**, both anchored on the same local start-of-epoch, so
/// a day recorded and a day rendered can never disagree even where the local epoch start is not
/// 1970-01-01 (any time zone west of UTC).
extension UsageDay {
    static func today(_ now: Date = Date(), calendar: Calendar = .current) -> UsageDay {
        let days = calendar.dateComponents(
            [.day], from: epochStart(calendar), to: calendar.startOfDay(for: now)).day ?? 0
        return UsageDay(daysSinceEpoch: days)
    }

    func startOfDay(_ calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: daysSinceEpoch, to: Self.epochStart(calendar))
            ?? Date(timeIntervalSince1970: 0)
    }

    private static func epochStart(_ calendar: Calendar) -> Date {
        calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
    }
}
