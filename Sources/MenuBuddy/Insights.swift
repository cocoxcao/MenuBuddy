import Foundation

/// Usage counts for Settings → Insights: how often the drop-down opens, how often you click an app
/// in it, and which apps. Stored only in MenuBuddy's own settings on this Mac (UserDefaults); never
/// sent anywhere. Per-day counts are kept for the last 90 days.
final class Insights: ObservableObject {
    static let shared = Insights()

    struct Day: Codable { var opens = 0, clicks = 0 }
    struct AppCount: Codable { var name: String; var clicks: Int }
    struct Data: Codable {
        var since = Date()
        var opens = 0
        var clicks = 0
        var apps: [String: AppCount] = [:]   // menu bar entry key → its name and clicks
        var days: [String: Day] = [:]        // "yyyy-MM-dd" (local) → that day's counts

        init() {}
        /// Reads what's there and defaults the rest, so a later version that adds a field still
        /// keeps the counts saved by an earlier one (updates never reset Insights).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            since = (try? c.decodeIfPresent(Date.self, forKey: .since)) ?? Date()
            opens = (try? c.decodeIfPresent(Int.self, forKey: .opens)) ?? 0
            clicks = (try? c.decodeIfPresent(Int.self, forKey: .clicks)) ?? 0
            apps = (try? c.decodeIfPresent([String: AppCount].self, forKey: .apps)) ?? [:]
            days = (try? c.decodeIfPresent([String: Day].self, forKey: .days)) ?? [:]
        }
    }

    private static let key = "insights"
    @Published private(set) var data: Data
    private var persist = true

    #if DEV_BUILD
    /// Made-up numbers for `--settings-snapshot`; never saved.
    init(sample: Bool) {
        persist = false
        var d = Data()
        d.since = Date().addingTimeInterval(-11 * 86400)
        d.opens = 214
        d.clicks = 131
        let names = ["Clipboard": 42, "VPN": 31, "Music": 23, "Timer": 19, "Notes": 9]
        for (name, n) in names { d.apps[name] = AppCount(name: name, clicks: n) }
        for back in 0..<12 {
            let day = Self.dayFormat.string(from: Date().addingTimeInterval(Double(-back) * 86400))
            d.days[day] = Day(opens: 12 + (back * 7) % 11, clicks: 7 + (back * 5) % 9)
        }
        data = d
    }
    #endif

    private init() {
        if let raw = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode(Data.self, from: raw) {
            data = saved
        } else {
            data = Data()
        }
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private var today: String { Self.dayFormat.string(from: Date()) }

    func recordOpen() {
        data.opens += 1
        data.days[today, default: Day()].opens += 1
        save()
    }

    func recordClick(key: String, name: String) {
        data.clicks += 1
        data.days[today, default: Day()].clicks += 1
        data.apps[key, default: AppCount(name: name, clicks: 0)].clicks += 1
        data.apps[key]?.name = name
        save()
    }

    func reset() {
        data = Data()
        save()
    }

    private func save() {
        guard persist else { return }
        let cutoff = Self.dayFormat.string(from: Date().addingTimeInterval(-90 * 86400))
        data.days = data.days.filter { $0.key >= cutoff }
        if let raw = try? JSONEncoder().encode(data) { UserDefaults.standard.set(raw, forKey: Self.key) }
    }

    // MARK: - For the Settings view

    /// Days counted so far, today included (at least 1).
    var daysTracked: Int {
        let start = Calendar.current.startOfDay(for: data.since)
        let days = Calendar.current.dateComponents([.day], from: start, to: Calendar.current.startOfDay(for: Date())).day ?? 0
        return max(1, days + 1)
    }
    var opensPerDay: Double { Double(data.opens) / Double(daysTracked) }
    var clicksPerDay: Double { Double(data.clicks) / Double(daysTracked) }
    var todayCounts: Day { data.days[today] ?? Day() }
    /// The last `n` days, oldest first, with zeros for days without use.
    func lastDays(_ n: Int) -> [(day: Date, opens: Int, clicks: Int)] {
        let cal = Calendar.current, today = cal.startOfDay(for: Date())
        return (0..<n).reversed().compactMap { back in
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            let c = data.days[Self.dayFormat.string(from: day)] ?? Day()
            return (day, c.opens, c.clicks)
        }
    }

    func topApps(_ n: Int = 5) -> [AppCount] {
        data.apps.values.sorted { $0.clicks != $1.clicks ? $0.clicks > $1.clicks : $0.name < $1.name }.prefix(n).map { $0 }
    }
}
