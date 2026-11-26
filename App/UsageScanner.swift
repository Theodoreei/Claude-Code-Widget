import Foundation

/// Reads Claude Code transcripts (~/.claude/projects/**/*.jsonl) incrementally and
/// turns them into a `Snapshot`. Only appended bytes are parsed on each pass.
final class UsageScanner {
    private struct UsageEvent {
        let date: Date
        let input, output, cacheRead, cacheWrite: Int
        let session: String
        let project: String
    }

    private enum LastKind {
        case toolUse(name: String, headline: String, detail: String?)
        case toolResult
        case prompt
        case thinking
        case text(stopReason: String?)
    }

    private struct FileState {
        var offset: UInt64 = 0
        var mtime: Date = .distantPast
        var events: [UsageEvent] = []
        var toolCallDates: [Date] = []
        var lastKind: LastKind?
        var lastDate: Date?
        var firstDate: Date?
        var lastPrompt: String?
        var project: String?
        var sessionId: String?
        var model: String?
        let isSubagent: Bool
    }

    private let root: URL
    private var files: [String: FileState] = [:]
    private var seenMessages = Set<String>()
    private var seenTools = Set<String>()

    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let iso = ISO8601DateFormatter()

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")) {
        self.root = root
    }

    // MARK: - Scanning

    func scan(now: Date = Date()) -> Snapshot {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        let weekStart = cal.date(byAdding: .day, value: -6, to: todayStart)!
        let cutoff = weekStart.addingTimeInterval(-86_400)

        for url in transcriptURLs(modifiedAfter: cutoff) {
            ingest(url)
        }
        return build(now: now, todayStart: todayStart, weekStart: weekStart, cal: cal)
    }

    private func transcriptURLs(modifiedAfter cutoff: Date) -> [URL] {
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            if url.path.contains("/memory/") { continue }
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if mod >= cutoff { out.append(url) }
        }
        return out
    }

    private func ingest(_ url: URL) {
        let key = url.path
        var st = files[key] ?? FileState(isSubagent: key.contains("/subagents/"))
        let attrs = try? FileManager.default.attributesOfItem(atPath: key)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
        if size < st.offset { st = FileState(isSubagent: st.isSubagent) }   // rewritten
        guard size > st.offset else { files[key] = st; return }

        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: st.offset)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return }

        // Only consume complete lines; keep a partial trailing line for next pass.
        guard let lastNL = data.lastIndex(of: 0x0A) else { files[key] = st; return }
        let complete = data[data.startIndex...lastNL]
        st.offset += UInt64(complete.count)
        st.mtime = mtime

        for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
            parse(line: Data(line), into: &st)
        }
        files[key] = st
    }

    private func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }

    private func parse(line: Data, into st: inout FileState) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = obj["type"] as? String, type == "assistant" || type == "user",
              let msg = obj["message"] as? [String: Any],
              let ts = date(obj["timestamp"]) else { return }

        if st.project == nil, let cwd = obj["cwd"] as? String { st.project = (cwd as NSString).lastPathComponent }
        if st.sessionId == nil { st.sessionId = obj["sessionId"] as? String }
        if st.firstDate == nil { st.firstDate = ts }
        let isMeta = (obj["isMeta"] as? Bool) == true

        if type == "assistant" {
            if let m = msg["model"] as? String, m != "<synthetic>" { st.model = m }
            let msgId = (msg["id"] as? String).map { $0 + ((obj["requestId"] as? String) ?? "") }
            if let usage = msg["usage"] as? [String: Any], let msgId, !seenMessages.contains(msgId) {
                seenMessages.insert(msgId)
                func n(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
                st.events.append(UsageEvent(date: ts, input: n("input_tokens"), output: n("output_tokens"),
                                            cacheRead: n("cache_read_input_tokens"), cacheWrite: n("cache_creation_input_tokens"),
                                            session: st.sessionId ?? "?", project: st.project ?? "Unknown"))
            }
            let blocks = msg["content"] as? [[String: Any]] ?? []
            for b in blocks {
                switch b["type"] as? String {
                case "tool_use":
                    let name = b["name"] as? String ?? "tool"
                    if let id = b["id"] as? String, !seenTools.contains(id) {
                        seenTools.insert(id)
                        st.toolCallDates.append(ts)
                    }
                    let (h, d) = describe(tool: name, input: b["input"] as? [String: Any] ?? [:])
                    st.lastKind = .toolUse(name: name, headline: h, detail: d)
                case "thinking", "redacted_thinking":
                    st.lastKind = .thinking
                case "text":
                    st.lastKind = .text(stopReason: msg["stop_reason"] as? String)
                default: break
                }
            }
            st.lastDate = ts
        } else {
            if let s = msg["content"] as? String {
                if !isMeta, let p = cleanPrompt(s) { st.lastPrompt = p; st.lastKind = .prompt; st.lastDate = ts }
            } else if let blocks = msg["content"] as? [[String: Any]] {
                if blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                    st.lastKind = .toolResult; st.lastDate = ts
                } else if !isMeta, let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
                          let p = cleanPrompt(text) {
                    st.lastPrompt = p; st.lastKind = .prompt; st.lastDate = ts
                }
            }
        }
    }

    private func cleanPrompt(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("Caveat:"), !t.hasPrefix("[Request interrupted") else { return nil }
        let oneLine = t.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return oneLine.count > 160 ? String(oneLine.prefix(157)) + "…" : oneLine
    }

    private func describe(tool: String, input: [String: Any]) -> (String, String?) {
        func file(_ k: String = "file_path") -> String? { (input[k] as? String).map { ($0 as NSString).lastPathComponent } }
        func str(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch tool {
        case "Read": return ("Reading \(file() ?? "a file")", str("file_path"))
        case "Edit", "MultiEdit": return ("Editing \(file() ?? "a file")", str("file_path"))
        case "Write": return ("Writing \(file() ?? "a file")", str("file_path"))
        case "NotebookEdit": return ("Editing \(file("notebook_path") ?? "a notebook")", nil)
        case "Bash":
            let cmd = str("command")
            return (str("description") ?? "Running a command", cmd.map { String($0.prefix(120)) })
        case "Grep": return ("Searching code", str("pattern"))
        case "Glob": return ("Finding files", str("pattern"))
        case "WebSearch": return ("Searching the web", str("query"))
        case "WebFetch": return ("Reading a web page", str("url"))
        case "Agent", "Task": return ("Delegating to a subagent", str("description"))
        case "TodoWrite", "TaskCreate", "TaskUpdate": return ("Updating the plan", nil)
        case "AskUserQuestion": return ("Asking you a question", nil)
        case "Skill": return ("Using a skill", str("skill"))
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
                let action = parts.last.map(String.init)?.replacingOccurrences(of: "_", with: " ") ?? tool
                if tool.contains("update_plan") { return ("Updating the plan", nil) }
                if tool.contains("wrap_up") { return ("Wrapping up", nil) }
                return ("Using \(action)", nil)
            }
            return ("Using \(tool)", nil)
        }
    }

    // MARK: - Aggregation

    private func build(now: Date, todayStart: Date, weekStart: Date, cal: Calendar) -> Snapshot {
        var snap = Snapshot.empty
        snap.generatedAt = now

        let all = files.values.flatMap(\.events).filter { $0.date >= weekStart }
        let tools = files.values.flatMap(\.toolCallDates).filter { $0 >= weekStart }

        func totals(_ evs: [UsageEvent], toolDates: [Date]) -> UsageTotals {
            var t = UsageTotals()
            for e in evs {
                t.input += e.input; t.output += e.output; t.cacheRead += e.cacheRead; t.cacheWrite += e.cacheWrite
            }
            t.messages = evs.count
            t.toolCalls = toolDates.count
            t.sessions = Set(evs.map(\.session)).count
            // Active time: sum gaps between consecutive responses, ignoring breaks > 5 min.
            let dates = evs.map(\.date).sorted()
            var secs: TimeInterval = 0
            for (a, b) in zip(dates, dates.dropFirst()) where b.timeIntervalSince(a) < 300 { secs += b.timeIntervalSince(a) }
            t.activeMinutes = Int(secs / 60)
            return t
        }

        snap.week = totals(all, toolDates: tools)
        let todayEvents = all.filter { $0.date >= todayStart }
        snap.today = totals(todayEvents, toolDates: tools.filter { $0 >= todayStart })

        var hourly = [Int](repeating: 0, count: 24)
        for e in todayEvents { hourly[cal.component(.hour, from: e.date)] += e.input + e.output + e.cacheRead + e.cacheWrite }
        snap.todayHourly = hourly.enumerated().map { HourUsage(hour: $0.offset, tokens: $0.element) }

        snap.days = (0..<7).map { i in
            let start = cal.date(byAdding: .day, value: i, to: weekStart)!
            let end = cal.date(byAdding: .day, value: 1, to: start)!
            let evs = all.filter { $0.date >= start && $0.date < end }
            return DayUsage(date: start, totals: totals(evs, toolDates: tools.filter { $0 >= start && $0 < end }))
        }

        var byProject: [String: Int] = [:]
        for e in all { byProject[e.project, default: 0] += e.input + e.output + e.cacheRead + e.cacheWrite }
        snap.topProjects = byProject.sorted { $0.value > $1.value }.prefix(4).map { ProjectUsage(name: $0.key, tokens: $0.value) }

        snap.activity = activity(now: now)
        return snap
    }

    private func activity(now: Date) -> Activity {
        var a = Activity()
        let recent = files.values.filter { ($0.lastDate ?? .distantPast) > now.addingTimeInterval(-180) && !$0.isSubagent }
        a.activeSessions = Set(recent.compactMap(\.sessionId)).count

        guard let latest = files.values.max(by: { ($0.lastDate ?? .distantPast) < ($1.lastDate ?? .distantPast) }),
              let last = latest.lastDate else { return a }

        // For a subagent, borrow the parent session's prompt.
        let parent = latest.isSubagent ? files.values.first { !$0.isSubagent && $0.sessionId == latest.sessionId } : nil
        a.project = latest.project
        a.prompt = latest.lastPrompt ?? parent?.lastPrompt
        a.model = latest.model
        a.lastEvent = last
        a.sessionStart = parent?.firstDate ?? latest.firstDate
        a.isSubagent = latest.isSubagent

        let age = now.timeIntervalSince(last)
        if age > 600 {
            a.state = .idle
            a.headline = "Napping"
            return a
        }
        switch latest.lastKind {
        case let .toolUse(name, headline, detail)?:
            a.state = .working; a.headline = headline; a.detail = detail; a.toolName = name
            if name == "AskUserQuestion" || name.hasSuffix("wrap_up") { a.state = .waiting }
        case .toolResult?, .prompt?, .thinking?:
            a.state = .working; a.headline = "Thinking…"
        case let .text(stop)?:
            if stop == "tool_use" || age < 3 { a.state = .working; a.headline = "Writing a reply…" }
            else { a.state = .waiting; a.headline = "Waiting for you" }
        case nil:
            a.state = .idle; a.headline = "Napping"
        }
        if a.isSubagent, a.state == .working { a.headline = "Subagent: " + a.headline }
        return a
    }
}
