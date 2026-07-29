import Foundation

enum SessionSeparator {
    static func line(at timestamp: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return L10n.format(
            "──── Session started %@ ────",
            formatter.string(from: timestamp)
        )
    }
}
