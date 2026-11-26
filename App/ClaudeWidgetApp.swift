import SwiftUI
import WidgetKit
import ServiceManagement
import Charts

@MainActor
final class Monitor: ObservableObject {
    @Published var snapshot: Snapshot = SnapshotStore.load() ?? .empty
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let scanner = UsageScanner()
    private let queue = DispatchQueue(label: "scanner", qos: .utility)
    private var timer: Timer?
    private var lastReload = Date.distantPast
    private var lastPushed: Snapshot?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh(force: Bool = false) {
        queue.async { [scanner] in
            let snap = scanner.scan()
            DispatchQueue.main.async { self.publish(snap, force: force) }
        }
    }

    private func publish(_ snap: Snapshot, force: Bool) {
        snapshot = snap
        var cmp = snap; cmp.generatedAt = .distantPast
        let changed = cmp != lastPushed
        let stateChanged = lastPushed?.activity.state != snap.activity.state || lastPushed?.activity.headline != snap.activity.headline
        // Always keep the file fresh; throttle widget reloads (WidgetKit budgets them).
        if changed || Date().timeIntervalSince(lastReload) > 300 || force {
            SnapshotStore.save(snap)
        }
        if force || (changed && (stateChanged || Date().timeIntervalSince(lastReload) > 30)) || Date().timeIntervalSince(lastReload) > 300 {
            WidgetCenter.shared.reloadAllTimelines()
            lastReload = Date()
            lastPushed = cmp
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { NSLog("Launch at login failed: \(error)") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

@main
struct ClaudeWidgetApp: App {
    @StateObject private var monitor = Monitor()

    var body: some Scene {
        MenuBarExtra {
            Dashboard().environmentObject(monitor)
        } label: {
            Image(nsImage: ClawdShape.menuBarImage(mood: ClawdMood(monitor.snapshot.activity.state)))
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Dashboard (menu bar popover)

struct AnimatedClawd: View {
    var mood: ClawdMood
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let bob = mood == .working ? sin(t * 6) * 2.5 : mood == .sleeping ? sin(t * 1.2) * 1.2 : sin(t * 2) * 1.5
            let blink = mood != .sleeping && t.truncatingRemainder(dividingBy: 4.2) < 0.14
            let glance: CGFloat = mood == .working ? CGFloat(sin(t * 1.7)) : 0
            ClawdView(mood: mood, glance: glance, blink: blink)
                .offset(y: bob)
        }
    }
}

struct Dashboard: View {
    @EnvironmentObject var monitor: Monitor
    var s: Snapshot { monitor.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            nowCard
            HStack(spacing: 10) {
                tile("Today", Fmt.tokens(s.today.total), "\(Fmt.tokens(s.today.output)) out · \(s.today.messages) msgs")
                tile("This week", Fmt.tokens(s.week.total), "\(s.week.sessions) sessions · \(Fmt.minutes(s.week.activeMinutes))")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Last 7 days").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Chart(s.days) { d in
                    BarMark(x: .value("Day", d.date, unit: .day), y: .value("Tokens", d.totals.total))
                        .foregroundStyle(Calendar.current.isDateInToday(d.date) ? Palette.clay : Palette.clay.opacity(0.45))
                        .cornerRadius(3)
                }
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true) } }
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine(); AxisValueLabel { if let n = v.as(Int.self) { Text(Fmt.tokens(n)) } } } }
                .frame(height: 110)
            }
            if !s.topProjects.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top projects this week").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(s.topProjects) { p in
                        HStack { Text(p.name).lineLimit(1); Spacer(); Text(Fmt.tokens(p.tokens)).monospacedDigit().foregroundStyle(.secondary) }
                            .font(.callout)
                    }
                }
            }
            Divider()
            HStack {
                Toggle("Launch at login", isOn: Binding(get: { monitor.launchAtLogin }, set: { monitor.setLaunchAtLogin($0) }))
                    .toggleStyle(.checkbox).font(.callout)
                Spacer()
                Button { monitor.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh widgets now")
                Button("Quit") { NSApp.terminate(nil) }
            }
            Text("Add widgets: right-click the desktop → Edit Widgets → search “Claude”.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340)
    }

    var nowCard: some View {
        let a = s.activity
        return HStack(alignment: .center, spacing: 14) {
            AnimatedClawd(mood: ClawdMood(a.state)).frame(width: 76, height: 50)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle().fill(a.state == .working ? .green : a.state == .waiting ? .orange : .gray).frame(width: 7, height: 7)
                    Text(a.state == .working ? "Working" : a.state == .waiting ? "Your turn" : "Idle")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let last = a.lastEvent {
                        Text("·").foregroundStyle(.tertiary)
                        Text(last, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(a.headline).font(.headline).lineLimit(1)
                if let p = a.prompt { Text(p).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                HStack(spacing: 8) {
                    if let p = a.project { Label(p, systemImage: "folder") }
                    if let m = Fmt.model(a.model) { Label(m, systemImage: "cpu") }
                }
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.clay.opacity(0.10)))
    }

    func tile(_ title: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(Palette.clay).monospacedDigit()
            Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}
