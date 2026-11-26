import Foundation

/// Token + activity counts for a span of time.
struct UsageTotals: Codable, Hashable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var messages = 0
    var toolCalls = 0
    var sessions = 0
    var activeMinutes = 0

    var total: Int { input + output + cacheRead + cacheWrite }
}

struct DayUsage: Codable, Hashable, Identifiable {
    var date: Date
    var totals: UsageTotals
    var id: Date { date }
}

struct HourUsage: Codable, Hashable, Identifiable {
    var hour: Int
    var tokens: Int
    var id: Int { hour }
}

struct ProjectUsage: Codable, Hashable, Identifiable {
    var name: String
    var tokens: Int
    var id: String { name }
}

enum ActivityState: String, Codable {
    case working   // Claude is mid-turn (thinking / running tools)
    case waiting   // Claude finished and is waiting on you
    case idle      // nothing recent
}

struct Activity: Codable, Hashable {
    var state: ActivityState = .idle
    var headline: String = "Napping"
    var detail: String?
    var toolName: String?
    var project: String?
    var prompt: String?
    var model: String?
    var lastEvent: Date?
    var sessionStart: Date?
    var activeSessions: Int = 0
    var isSubagent = false
}

struct Snapshot: Codable, Hashable {
    var generatedAt: Date
    var today: UsageTotals
    var todayHourly: [HourUsage]
    var week: UsageTotals
    var days: [DayUsage]          // oldest → newest, last is today
    var topProjects: [ProjectUsage]
    var activity: Activity

    static var empty: Snapshot {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        return Snapshot(
            generatedAt: .distantPast,
            today: .init(),
            todayHourly: (0..<24).map { HourUsage(hour: $0, tokens: 0) },
            week: .init(),
            days: (0..<7).reversed().map { DayUsage(date: cal.date(byAdding: .day, value: -$0, to: start)!, totals: .init()) },
            topProjects: [],
            activity: .init()
        )
    }

    /// Fake data for widget gallery previews.
    static var preview: Snapshot {
        var s = Snapshot.empty
        s.generatedAt = Date()
        s.today = UsageTotals(input: 4_200, output: 182_000, cacheRead: 9_400_000, cacheWrite: 610_000,
                              messages: 412, toolCalls: 318, sessions: 4, activeMinutes: 147)
        s.todayHourly = (0..<24).map { h in HourUsage(hour: h, tokens: (8...18).contains(h) ? (h * 37 % 11 + 2) * 120_000 : 0) }
        let w = [3.1, 5.4, 2.2, 7.9, 6.3, 4.4, 10.2]
        for i in 0..<7 {
            s.days[i].totals = UsageTotals(output: Int(w[i] * 18_000), cacheRead: Int(w[i] * 900_000), cacheWrite: Int(w[i] * 60_000), messages: Int(w[i] * 40))
        }
        s.week = UsageTotals(input: 21_000, output: 711_000, cacheRead: 35_500_000, cacheWrite: 2_370_000,
                             messages: 1_580, toolCalls: 1_204, sessions: 19, activeMinutes: 612)
        s.topProjects = [.init(name: "my-app", tokens: 21_000_000), .init(name: "Claude-Code-Widget", tokens: 9_800_000), .init(name: "website", tokens: 7_100_000)]
        s.activity = Activity(state: .working, headline: "Editing Snapshot.swift", detail: "Shared/Snapshot.swift",
                              toolName: "Edit", project: "Claude_Widget", prompt: "create me a widget app that shows claude code's progress",
                              model: "claude-opus-5-5", lastEvent: Date(), sessionStart: Date().addingTimeInterval(-1800), activeSessions: 1)
        return s
    }
}

enum SnapshotStore {
    static let appGroup = "W4MBZ59CH2.com.eisemon.ClaudeWidget"

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("snapshot.json")
    }

    static func load() -> Snapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func save(_ snapshot: Snapshot) {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

enum Fmt {
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB", d / 1e9)
        case 10_000_000...:    return String(format: "%.0fM", d / 1e6)
        case 1_000_000...:     return String(format: "%.1fM", d / 1e6)
        case 10_000...:        return String(format: "%.0fK", d / 1e3)
        case 1_000...:         return String(format: "%.1fK", d / 1e3)
        default:               return "\(n)"
        }
    }

    static func minutes(_ m: Int) -> String {
        m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    static func model(_ id: String?) -> String? {
        guard let id else { return nil }
        // claude-opus-5-5 → Opus 5.5
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) && $0.count <= 2 }.joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " \(version)")
    }
}
