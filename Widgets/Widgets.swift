import WidgetKit
import SwiftUI
import Charts

// MARK: - Timeline

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot
    var isPlaceholder = false
    /// Snapshot is old enough that the companion app probably isn't running.
    var isStale: Bool { !isPlaceholder && date.timeIntervalSince(snapshot.generatedAt) > 15 * 60 }
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: .preview, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        if context.isPreview, SnapshotStore.load() == nil {
            completion(UsageEntry(date: Date(), snapshot: .preview, isPlaceholder: true))
        } else {
            completion(UsageEntry(date: Date(), snapshot: SnapshotStore.load() ?? .empty))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = UsageEntry(date: Date(), snapshot: SnapshotStore.load() ?? .empty)
        // The app pushes reloads whenever data changes; this is just a fallback.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(5 * 60))))
    }
}

// MARK: - Shared bits

struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) var scheme
    func body(content: Content) -> some View {
        content.containerBackground(for: .widget) { Palette.background(scheme) }
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

struct WidgetHeader: View {
    var title: String
    var mood: ClawdMood = .happy
    var body: some View {
        HStack(spacing: 6) {
            ClawdView(mood: mood).frame(width: 22, height: 14)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

struct Stat: View {
    var label: String
    var value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
        }
    }
}

struct StaleNote: View {
    var body: some View {
        Label("Open Claude Widget to refresh", systemImage: "exclamationmark.arrow.circlepath")
            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
    }
}

// MARK: - Today

struct TodayView: View {
    @Environment(\.widgetFamily) var family
    let entry: UsageEntry
    var t: UsageTotals { entry.snapshot.today }

    var body: some View {
        switch family {
        case .systemSmall: small
        default: medium
        }
    }

    var headline: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Fmt.tokens(t.total))
                .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(Palette.clay)
                .minimumScaleFactor(0.6)
            Text("tokens today").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(title: "Today", mood: ClawdMood(entry.snapshot.activity.state))
            headline
            Spacer(minLength: 0)
            HStack {
                Stat(label: "output", value: Fmt.tokens(t.output))
                Spacer()
                Stat(label: "messages", value: "\(t.messages)")
            }
            if entry.isStale { StaleNote() }
        }
        .card()
    }

    var medium: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "Today", mood: ClawdMood(entry.snapshot.activity.state))
                headline
                Spacer(minLength: 0)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Stat(label: "output", value: Fmt.tokens(t.output))
                        Stat(label: "cache read", value: Fmt.tokens(t.cacheRead))
                    }
                    GridRow {
                        Stat(label: "sessions", value: "\(t.sessions)")
                        Stat(label: "tool calls", value: "\(t.toolCalls)")
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("By hour").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("active \(Fmt.minutes(t.activeMinutes))").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Chart(entry.snapshot.todayHourly) { h in
                    BarMark(x: .value("Hour", h.hour), y: .value("Tokens", h.tokens), width: .fixed(4.5))
                        .foregroundStyle(h.hour == Calendar.current.component(.hour, from: entry.date) ? Palette.clay : Palette.clay.opacity(0.45))
                        .cornerRadius(1.5)
                }
                .chartXScale(domain: 0...23)
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18]) { v in
                        AxisValueLabel { if let h = v.as(Int.self) { Text(h == 0 ? "12a" : h == 12 ? "12p" : h < 12 ? "\(h)a" : "\(h - 12)p") } }
                    }
                }
                .chartYAxis(.hidden)
                if entry.isStale { StaleNote() }
            }
        }
        .card()
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TodayUsage", provider: UsageProvider()) { TodayView(entry: $0) }
            .configurationDisplayName("Today's Usage")
            .description("Claude Code tokens, messages and sessions so far today.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Week

struct WeekView: View {
    @Environment(\.widgetFamily) var family
    let entry: UsageEntry
    var s: Snapshot { entry.snapshot }

    var chart: some View {
        Chart(s.days) { d in
            BarMark(x: .value("Day", d.date, unit: .day), y: .value("Tokens", d.totals.total), width: .ratio(0.62))
                .foregroundStyle(Calendar.current.isDate(d.date, inSameDayAs: entry.date) ? Palette.clay : Palette.clay.opacity(0.45))
                .cornerRadius(3)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
            }
        }
        .chartYAxis(family == .systemSmall ? .hidden : .automatic)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.25))
                AxisValueLabel { if let n = v.as(Int.self) { Text(Fmt.tokens(n)) } }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(title: "This week", mood: ClawdMood(s.activity.state))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.tokens(s.week.total))
                    .font(.system(size: family == .systemSmall ? 22 : 26, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Palette.clay)
                Text("tokens · 7 days").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if family != .systemSmall {
                    Stat(label: "output", value: Fmt.tokens(s.week.output))
                    Stat(label: "sessions", value: "\(s.week.sessions)").padding(.leading, 8)
                    Stat(label: "active", value: Fmt.minutes(s.week.activeMinutes)).padding(.leading, 8)
                }
            }
            chart
            if family == .systemLarge { large }
            if entry.isStale { StaleNote() }
        }
        .card()
    }

    @ViewBuilder var large: some View {
        Divider().padding(.vertical, 2)
        Text("TOP PROJECTS").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
        let maxT = max(s.topProjects.first?.tokens ?? 1, 1)
        ForEach(s.topProjects) { p in
            HStack(spacing: 8) {
                Text(p.name).font(.system(size: 11, weight: .medium)).lineLimit(1).frame(width: 110, alignment: .leading)
                GeometryReader { g in
                    Capsule().fill(Palette.clay.opacity(0.8))
                        .frame(width: max(4, g.size.width * CGFloat(p.tokens) / CGFloat(maxT)))
                }
                .frame(height: 6)
                Text(Fmt.tokens(p.tokens)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
        if s.topProjects.isEmpty { Text("No sessions yet this week").font(.caption).foregroundStyle(.secondary) }
        HStack {
            Stat(label: "messages", value: "\(s.week.messages)")
            Spacer(); Stat(label: "tool calls", value: "\(s.week.toolCalls)")
            Spacer(); Stat(label: "cache read", value: Fmt.tokens(s.week.cacheRead))
            Spacer(); Stat(label: "cache write", value: Fmt.tokens(s.week.cacheWrite))
        }
        .padding(.top, 2)
    }
}

struct WeekWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WeekUsage", provider: UsageProvider()) { WeekView(entry: $0) }
            .configurationDisplayName("Weekly Usage")
            .description("Claude Code tokens per day over the last 7 days.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Right now

struct NowView: View {
    @Environment(\.widgetFamily) var family
    let entry: UsageEntry
    var a: Activity { entry.snapshot.activity }
    var mood: ClawdMood { ClawdMood(a.state) }

    var stateLabel: (String, Color) {
        switch a.state {
        case .working: return ("Working", .green)
        case .waiting: return ("Your turn", .orange)
        case .idle: return ("Idle", .secondary)
        }
    }

    var statusPill: some View {
        HStack(spacing: 4) {
            Circle().fill(stateLabel.1).frame(width: 6, height: 6)
            Text(stateLabel.0).font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }

    var updated: some View {
        Group {
            if let last = a.lastEvent {
                Text(last, style: .relative) + Text(" ago")
            } else {
                Text("No activity yet")
            }
        }
        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
    }

    var body: some View {
        if family == .systemSmall { small } else { medium }
    }

    var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { statusPill; Spacer() }
            ClawdBadge(mood: mood).frame(height: 34).frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            Text(a.headline).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(2)
            HStack(spacing: 4) {
                if let p = a.project { Text(p).lineLimit(1) }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            if entry.isStale { StaleNote() }
        }
        .card()
    }

    var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 8) {
                ClawdBadge(mood: mood).frame(width: 74, height: 46).padding(.top, 10)
                statusPill
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("RIGHT NOW").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(0.6).foregroundStyle(.secondary)
                    Spacer()
                    updated
                }
                Text(a.headline).font(.system(size: 16, weight: .bold, design: .rounded)).lineLimit(1)
                if let d = a.detail {
                    Text(d).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let p = a.prompt {
                    Text("“\(p)”").font(.system(size: 11)).italic().lineLimit(2).foregroundStyle(.primary.opacity(0.85))
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    if let p = a.project { Label(p, systemImage: "folder").lineLimit(1) }
                    if let m = Fmt.model(a.model) { Label(m, systemImage: "cpu").lineLimit(1) }
                    if a.activeSessions > 1 { Label("\(a.activeSessions) sessions", systemImage: "square.stack") }
                }
                .font(.system(size: 9)).foregroundStyle(.secondary)
                if entry.isStale { StaleNote() }
            }
        }
        .card()
    }
}

struct NowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RightNow", provider: UsageProvider()) { NowView(entry: $0) }
            .configurationDisplayName("What Claude's Doing")
            .description("Live status of your most recent Claude Code session.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Clawd

struct ClawdWidgetView: View {
    let entry: UsageEntry
    var a: Activity { entry.snapshot.activity }

    var line: String {
        switch a.state {
        case .working: return "On it!"
        case .waiting: return "Your move."
        case .idle:
            let h = Calendar.current.component(.hour, from: entry.date)
            if h < 6 || h >= 23 { return "Zzz…" }
            return entry.snapshot.today.messages == 0 ? "Ready when you are" : "Taking a break"
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(line)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .bottom) {
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: 7))
                        .foregroundStyle(.background.opacity(0.7)).offset(y: 5)
                }
            ClawdBadge(mood: ClawdMood(a.state))
                .frame(maxWidth: .infinity).frame(height: 54)
                .padding(.top, 4)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text(Fmt.tokens(entry.snapshot.today.output)).bold().foregroundStyle(Palette.clay)
                Text("written today").foregroundStyle(.secondary)
            }
            .font(.system(size: 10, design: .rounded))
        }
        .card()
    }
}

struct ClawdWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Clawd", provider: UsageProvider()) { ClawdWidgetView(entry: $0) }
            .configurationDisplayName("Clawd")
            .description("The Claude Code mascot, reacting to what Claude is up to.")
            .supportedFamilies([.systemSmall])
    }
}

@main
struct ClaudeWidgets: WidgetBundle {
    var body: some Widget {
        NowWidget()
        TodayWidget()
        WeekWidget()
        ClawdWidget()
    }
}

#Preview("Now", as: .systemMedium) { NowWidget() } timeline: { UsageEntry(date: .now, snapshot: .preview) }
#Preview("Week", as: .systemLarge) { WeekWidget() } timeline: { UsageEntry(date: .now, snapshot: .preview) }
