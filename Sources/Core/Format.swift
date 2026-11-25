import Foundation

/// Formatters are costly to create; cards ask for one on every redraw, so they are made once per locale and kind.
private final class FormatterCache: @unchecked Sendable {
    static let shared = FormatterCache()
    private let lock = NSLock()
    private var dates: [String: DateFormatter] = [:]
    private var numbers: [String: NumberFormatter] = [:]

    func date(_ template: String, _ locale: Locale, _ calendar: Calendar) -> DateFormatter {
        let key = "\(template)|\(locale.identifier)|\(calendar.identifier)|\(calendar.timeZone.identifier)"
        lock.lock(); defer { lock.unlock() }
        if let f = dates[key] { return f }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(template)
        dates[key] = f
        return f
    }

    func decimal(_ locale: Locale) -> NumberFormatter {
        lock.lock(); defer { lock.unlock() }
        if let f = numbers[locale.identifier] { return f }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = locale
        numbers[locale.identifier] = f
        return f
    }
}

/// How long ago, in a few characters: Now, 2m, 3h, Yesterday, 4d, Dec 6, Dec 11, 2025.
public func relativeTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
    let seconds = now.timeIntervalSince(date)
    if seconds < 60 { return "Now" }
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    if days == 0 { return seconds < 3600 ? "\(Int(seconds / 60))m" : "\(Int(seconds / 3600))h" }
    if days == 1 { return "Yesterday" }
    if days < 7 { return "\(days)d" }
    return FormatterCache.shared.date(days < 180 ? "MMMd" : "yMMMd", locale, calendar).string(from: date)
}

/// How long ago, in words, for the card header: Just now, 5 minutes ago, 3 hours ago, Yesterday, 4 days ago, Dec 6.
public func relativeTimeLong(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
    let seconds = now.timeIntervalSince(date)
    if seconds < 60 { return "Just now" }
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    func plural(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s") ago" }
    if days == 0 { return seconds < 3600 ? plural(Int(seconds / 60), "minute") : plural(Int(seconds / 3600), "hour") }
    if days == 1 { return "Yesterday" }
    if days < 7 { return plural(days, "day") }
    return relativeTime(date, now: now, calendar: calendar, locale: locale)
}

/// The line at the bottom of a card.
public func footerText(locale: Locale = .current, _ item: Item) -> String {
    switch item.kind {
    case .text, .richText:
        let n = FormatterCache.shared.decimal(locale)
        return "\(n.string(from: NSNumber(value: item.charCount)) ?? "\(item.charCount)") character\(item.charCount == 1 ? "" : "s")"
    case .image:
        guard let w = item.width, let h = item.height else { return "Image" }
        return "\(w) × \(h)"
    case .file:
        return "\(item.fileURLs.count) file\(item.fileURLs.count == 1 ? "" : "s")"
    case .link:
        let host = URL(string: item.text ?? item.preview)?.host ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    case .color:
        guard let hex = parseColor(item.preview) ?? parseColor(item.text ?? ""), hex.count >= 7,
              let v = UInt32(hex.dropFirst().prefix(6), radix: 16) else { return item.preview }
        return "rgb(\(v >> 16 & 0xFF), \(v >> 8 & 0xFF), \(v & 0xFF))"
    }
}
