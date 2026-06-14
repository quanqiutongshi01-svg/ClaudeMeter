import AppKit
import SwiftUI
import ServiceManagement
import SQLite3

// MARK: - Formatting

func fmtPct(_ frac: Double?) -> String {
    guard let f = frac else { return "--" }
    return "\(Int((f * 100).rounded()))%"
}

func fmtCountdown(_ date: Date?) -> String {
    guard let date else { return "--" }
    let s = Int(date.timeIntervalSinceNow)
    if s <= 0 { return "reset now" }
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return h > 0 ? "\(d)d\(h)h" : "\(d)d" }
    if h > 0 { return "\(h)h\(m)m" }
    return "\(max(0, m))m"
}

func fmtResetClock(_ date: Date?) -> String {
    guard let date else { return "" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    if Calendar.current.isDateInToday(date) { f.dateFormat = "今天 HH:mm" }
    else if Calendar.current.isDateInTomorrow(date) { f.dateFormat = "明天 HH:mm" }
    else { f.dateFormat = "EEE HH:mm" }
    return f.string(from: date)
}

func fmtClock(_ date: Date?) -> String {
    guard let date else { return "--" }
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: date)
}

func fmtAge(_ date: Date?) -> String {
    guard let date else { return "--" }
    let s = max(0, Int(Date().timeIntervalSince(date)))
    if s < 60 { return "\(s)s ago" }
    let m = s / 60
    if m < 60 { return "\(m)m ago" }
    let h = m / 60
    if h < 48 { return "\(h)h ago" }
    return "\(h / 24)d ago"
}

// MARK: - Models

enum ProviderFreshness: String {
    case live
    case stale
    case unavailable
    case missingToken
    case error
}

struct UsageWindow: Identifiable {
    let id: String
    let title: String
    let icon: String
    var used: Double?
    var reset: Date?
    var status: String?
    var windowMinutes: Int?
}

struct ProviderUsage: Identifiable {
    let id: String
    let name: String
    let shortName: String
    let icon: String
    var source: String
    var badge: String
    var freshness: ProviderFreshness
    var windows: [UsageWindow]
    var observedAt: Date?
    var allowed: Bool?
    var limitReached: Bool?
    var error: String?
    var hint: String?

    var worstUsed: Double? {
        let values = windows.compactMap(\.used)
        return values.max()
    }

    var primaryUsed: Double? {
        windows.first(where: { $0.id == "5h" })?.used ?? worstUsed
    }

    var hasUsableData: Bool {
        windows.contains { $0.used != nil || $0.reset != nil }
    }
}

struct TaskItem: Codable, Identifiable {
    let id: String
    let subject: String?
    let status: String?
    let activeForm: String?
}

final class UsageState: ObservableObject {
    @Published var providers: [ProviderUsage] = []
    @Published var tasks: [TaskItem] = []
    @Published var lastUpdate: Date?
    @Published var loading = false
    @Published var tick = 0
}

struct FetchResult {
    var providers: [ProviderUsage] = []
    var tasks: [TaskItem] = []
}

enum HomePaths {
    static func candidates() -> [URL] {
        var urls: [URL] = []
        func add(_ path: String?) {
            guard let path, !path.isEmpty else { return }
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            if !urls.contains(where: { $0.path == url.path }) { urls.append(url) }
        }
        add(ProcessInfo.processInfo.environment["HOME"])
        add(FileManager.default.homeDirectoryForCurrentUser.path)
        add(NSHomeDirectory())
        add("/Users/\(NSUserName())")
        return urls
    }

    static func firstExisting(_ components: [String]) -> URL? {
        for home in candidates() {
            let url = components.reduce(home) { partial, component in
                partial.appendingPathComponent(component, isDirectory: false)
            }
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}

// MARK: - Claude Code

enum ClaudeFetcher {
    static func loadToken() -> String? {
        guard let url = HomePaths.firstExisting([".claude", "ccmenubar", "claude-token"]) else { return nil }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func fetch() -> ProviderUsage {
        guard let token = loadToken() else {
            return ProviderUsage(
                id: "claude",
                name: "Claude Code",
                shortName: "Cl",
                icon: "sparkles",
                source: "Anthropic response headers",
                badge: "needs token",
                freshness: .missingToken,
                windows: defaultWindows(),
                observedAt: nil,
                allowed: nil,
                limitReached: nil,
                error: nil,
                hint: "Run claude setup-token, then save it to ~/.claude/ccmenubar/claude-token."
            )
        }

        var usage = fetchOfficial(token: token)
        usage.observedAt = Date()
        return usage
    }

    static func defaultWindows() -> [UsageWindow] {
        [
            UsageWindow(id: "5h", title: "5-hour window", icon: "clock.fill", used: nil, reset: nil, status: nil, windowMinutes: 300),
            UsageWindow(id: "weekly", title: "Weekly window", icon: "calendar", used: nil, reset: nil, status: nil, windowMinutes: 10080)
        ]
    }

    private static func fetchOfficial(token: String) -> ProviderUsage {
        var provider = ProviderUsage(
            id: "claude",
            name: "Claude Code",
            shortName: "Cl",
            icon: "sparkles",
            source: "Anthropic response headers",
            badge: "official",
            freshness: .live,
            windows: defaultWindows(),
            observedAt: nil,
            allowed: nil,
            limitReached: nil,
            error: nil,
            hint: nil
        )

        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            provider.freshness = .error
            provider.error = "Invalid Anthropic API URL."
            return provider
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("TokenMeter/2.0", forHTTPHeaderField: "user-agent")
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "system": "You are Claude Code, Anthropic's official CLI for Claude.",
            "messages": [["role": "user", "content": "."]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, resp, err in
            defer { sem.signal() }
            guard let http = resp as? HTTPURLResponse else {
                provider.freshness = .error
                provider.error = err?.localizedDescription ?? "No Anthropic response."
                return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                provider.freshness = .error
                provider.error = "Token invalid or missing permission (\(http.statusCode)). Run claude setup-token again."
                return
            }
            if http.statusCode != 200 {
                provider.freshness = .error
                provider.error = "Anthropic HTTP \(http.statusCode)."
            }

            func header(_ key: String) -> String? { http.value(forHTTPHeaderField: key) }
            let fiveUsed = header("anthropic-ratelimit-unified-5h-utilization").flatMap(Double.init)
            let fiveReset = header("anthropic-ratelimit-unified-5h-reset").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            let weekUsed = header("anthropic-ratelimit-unified-7d-utilization").flatMap(Double.init)
            let weekReset = header("anthropic-ratelimit-unified-7d-reset").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            let overall = header("anthropic-ratelimit-unified-status") ?? ""

            provider.windows = [
                UsageWindow(id: "5h", title: "5-hour window", icon: "clock.fill", used: fiveUsed, reset: fiveReset, status: header("anthropic-ratelimit-unified-5h-status"), windowMinutes: 300),
                UsageWindow(id: "weekly", title: "Weekly window", icon: "calendar", used: weekUsed, reset: weekReset, status: header("anthropic-ratelimit-unified-7d-status"), windowMinutes: 10080)
            ]
            provider.allowed = !overall.contains("rejected")
            provider.limitReached = overall.contains("rejected")
            if !overall.isEmpty { provider.badge = overall }
        }.resume()
        sem.wait()
        return provider
    }
}

// MARK: - Codex

enum CodexFetcher {
    static let candidatePaths = [
        (components: [".codex", "logs_2.sqlite"], label: "~/.codex/logs_2.sqlite"),
        (components: [".codex", "sqlite", "logs_2.sqlite"], label: "~/.codex/sqlite/logs_2.sqlite")
    ]

    static func fetch() -> ProviderUsage {
        let fm = FileManager.default
        var lastError: String?

        for home in HomePaths.candidates() {
            for candidate in candidatePaths {
                let url = candidate.components.reduce(home) { partial, component in
                    partial.appendingPathComponent(component, isDirectory: false)
                }
                guard fm.fileExists(atPath: url.path) else { continue }
                switch readLatestEvent(from: url) {
                case .success(let event):
                    return provider(from: event, source: candidate.label)
                case .failure(let error):
                    lastError = error
                }
            }
        }

        return ProviderUsage(
            id: "codex",
            name: "Codex",
            shortName: "Cx",
            icon: "terminal",
            source: "local Codex logs",
            badge: "unavailable",
            freshness: .unavailable,
            windows: defaultWindows(),
            observedAt: nil,
            allowed: nil,
            limitReached: nil,
            error: lastError ?? "No codex.rate_limits event found in local logs.",
            hint: "Open Codex, complete one request, then refresh TokenMeter."
        )
    }

    static func defaultWindows() -> [UsageWindow] {
        [
            UsageWindow(id: "5h", title: "5-hour window", icon: "clock.fill", used: nil, reset: nil, status: nil, windowMinutes: 300),
            UsageWindow(id: "weekly", title: "Weekly window", icon: "calendar", used: nil, reset: nil, status: nil, windowMinutes: 10080)
        ]
    }

    private struct CodexEvent {
        var planType: String?
        var allowed: Bool?
        var limitReached: Bool?
        var primary: UsageWindow
        var secondary: UsageWindow
        var observedAt: Date?
    }

    private enum ReadResult {
        case success(CodexEvent)
        case failure(String)
    }

    private static func provider(from event: CodexEvent, source: String) -> ProviderUsage {
        let now = Date()
        let windows = [event.primary, event.secondary]
        let futureWindowExists = windows.contains { window in
            guard let reset = window.reset else { return false }
            return reset > now
        }

        let freshness: ProviderFreshness
        let badge: String
        let error: String?
        let hint: String?

        if !futureWindowExists {
            freshness = .unavailable
            badge = "expired"
            error = "Latest Codex rate-limit snapshot is past its reset time."
            hint = "Open Codex, complete one request, then refresh TokenMeter."
        } else if let observedAt = event.observedAt, now.timeIntervalSince(observedAt) <= 600 {
            freshness = .live
            badge = event.planType.map { "\($0) · fresh" } ?? "fresh"
            error = nil
            hint = nil
        } else {
            freshness = .stale
            badge = event.planType.map { "\($0) · stale" } ?? "stale"
            error = "Codex data may be stale. TokenMeter only reads local Codex websocket logs."
            hint = "Use Codex once, then press refresh."
        }

        return ProviderUsage(
            id: "codex",
            name: "Codex",
            shortName: "Cx",
            icon: "terminal",
            source: source,
            badge: badge,
            freshness: freshness,
            windows: windows,
            observedAt: event.observedAt,
            allowed: event.allowed,
            limitReached: event.limitReached,
            error: error,
            hint: hint
        )
    }

    private static func readLatestEvent(from dbURL: URL) -> ReadResult {
        if case .success(let event) = readLatestEventDirectly(from: dbURL) {
            return .success(event)
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenmeter-\(UUID().uuidString)-\(dbURL.lastPathComponent)")
        do {
            try FileManager.default.copyItem(at: dbURL, to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            return readLatestEventDirectly(from: tmp)
        } catch {
            return .failure("Could not read \(dbURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func readLatestEventDirectly(from dbURL: URL) -> ReadResult {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close(db) }
            return .failure(msg)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let sql = """
        SELECT feedback_log_body
        FROM logs
        WHERE feedback_log_body LIKE '%codex.rate_limits%'
          AND feedback_log_body LIKE '%websocket event:%'
        ORDER BY id DESC
        LIMIT 40
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return .failure(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(stmt, 0) else { continue }
            let body = String(cString: raw)
            if let event = parseEvent(from: body) {
                return .success(event)
            }
        }

        return .failure("No parseable codex.rate_limits websocket event.")
    }

    private static func parseEvent(from logBody: String) -> CodexEvent? {
        guard let marker = logBody.range(of: "websocket event: ") else { return nil }
        let jsonText = String(logBody[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "codex.rate_limits",
              let limits = root["rate_limits"] as? [String: Any] else { return nil }

        guard let primaryDict = limits["primary"] as? [String: Any],
              let secondaryDict = limits["secondary"] as? [String: Any] else { return nil }

        let primary = parseWindow(id: "5h", title: "5-hour window", icon: "clock.fill", dict: primaryDict)
        let secondary = parseWindow(id: "weekly", title: "Weekly window", icon: "calendar", dict: secondaryDict)
        let observed = observedAt(primaryDict: primaryDict, secondaryDict: secondaryDict)

        return CodexEvent(
            planType: root["plan_type"] as? String,
            allowed: boolValue(limits["allowed"]),
            limitReached: boolValue(limits["limit_reached"]),
            primary: primary,
            secondary: secondary,
            observedAt: observed
        )
    }

    private static func parseWindow(id: String, title: String, icon: String, dict: [String: Any]) -> UsageWindow {
        let usedPercent = doubleValue(dict["used_percent"])
        let reset = doubleValue(dict["reset_at"]).map { Date(timeIntervalSince1970: $0) }
        let minutes = intValue(dict["window_minutes"])
        return UsageWindow(
            id: id,
            title: title,
            icon: icon,
            used: usedPercent.map { min(1, max(0, $0 / 100.0)) },
            reset: reset,
            status: nil,
            windowMinutes: minutes
        )
    }

    private static func observedAt(primaryDict: [String: Any], secondaryDict: [String: Any]) -> Date? {
        for dict in [primaryDict, secondaryDict] {
            if let reset = doubleValue(dict["reset_at"]),
               let after = doubleValue(dict["reset_after_seconds"]) {
                return Date(timeIntervalSince1970: reset - after)
            }
        }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let i = value as? Int { return i }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String {
            if s == "true" { return true }
            if s == "false" { return false }
        }
        return nil
    }
}

// MARK: - Shared fetcher

enum Fetcher {
    static func fetchTasks() -> [TaskItem] {
        let fm = FileManager.default
        guard let tasksDir = HomePaths.firstExisting([".claude", "tasks"]) else { return [] }
        guard let subdirs = try? fm.contentsOfDirectory(
            at: tasksDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        let dirs = subdirs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let latest = dirs.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
        guard let dir = latest,
              let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        var items: [TaskItem] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let task = try? JSONDecoder().decode(TaskItem.self, from: data) {
                items.append(task)
            }
        }
        items.sort { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
        return items
    }

    static func fetchAll() -> FetchResult {
        FetchResult(
            providers: [ClaudeFetcher.fetch(), CodexFetcher.fetch()],
            tasks: fetchTasks()
        )
    }
}

// MARK: - Views

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

struct UsageBar: View {
    var ratio: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.13))
                Capsule()
                    .fill(color)
                    .frame(width: max(6, geo.size.width * min(1, max(0, ratio))))
            }
        }
        .frame(height: 7)
    }

    var color: Color {
        switch ratio {
        case ..<0.5: return Color(red: 0.30, green: 0.85, blue: 0.46)
        case ..<0.8: return Color(red: 0.98, green: 0.78, blue: 0.24)
        default: return Color(red: 0.98, green: 0.36, blue: 0.36)
        }
    }
}

struct ProviderCard: View {
    var provider: ProviderUsage
    var onOpenCodex: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: provider.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Text(provider.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text(provider.badge)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badgeColor.opacity(0.18))
                    .foregroundColor(badgeColor)
                    .clipShape(Capsule())
            }

            ForEach(provider.windows) { window in
                windowRow(window)
            }

            if let observedAt = provider.observedAt {
                Text("Source: \(provider.source) · seen \(fmtAge(observedAt))")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.38))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Source: \(provider.source)")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.38))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let error = provider.error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let hint = provider.hint {
                HStack(spacing: 8) {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if provider.id == "codex" {
                        Button("Open") { onOpenCodex() }
                            .font(.system(size: 10, weight: .semibold))
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .foregroundColor(.white.opacity(0.82))
                    }
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.07))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.10)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var badgeColor: Color {
        switch provider.freshness {
        case .live: return Color(red: 0.30, green: 0.85, blue: 0.46)
        case .stale: return Color(red: 0.98, green: 0.78, blue: 0.24)
        case .missingToken, .unavailable, .error: return Color(red: 0.98, green: 0.52, blue: 0.32)
        }
    }

    private func windowRow(_ window: UsageWindow) -> some View {
        let used = window.used ?? 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: window.icon)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.60))
                Text(window.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.82))
                Spacer()
                Text(fmtCountdown(window.reset))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.62))
            }
            UsageBar(ratio: used)
            HStack {
                Text("Used \(fmtPct(window.used)) · Left \(fmtPct(window.used.map { 1 - $0 }))")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.68))
                Spacer()
                Text(fmtResetClock(window.reset))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
            }
        }
    }
}

struct PanelView: View {
    @ObservedObject var state: UsageState
    var onRefresh: () -> Void
    var onQuit: () -> Void
    var onOpenCodex: () -> Void
    var preview: Bool = false

    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)

    @ViewBuilder private var backgroundView: some View {
        if preview { Color(red: 0.10, green: 0.11, blue: 0.13).opacity(0.96) }
        else { VisualEffectView() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ForEach(state.providers) { provider in
                ProviderCard(provider: provider, onOpenCodex: onOpenCodex)
            }
            tasksSection
            footer
        }
        .padding(14)
        .frame(width: 372)
        .background(backgroundView.clipShape(RoundedRectangle(cornerRadius: 16)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .foregroundColor(.white)
        .id(state.tick)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .foregroundColor(.white.opacity(0.9))
            Text("TokenMeter")
                .font(.system(size: 14, weight: .semibold))
            Text("Claude + Codex")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.white.opacity(0.16))
                .clipShape(Capsule())
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            if state.loading {
                ProgressView().controlSize(.small).colorScheme(.dark)
            } else {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.7))
            }
        }
    }

    private var tasksSection: some View {
        let done = state.tasks.filter { $0.status == "completed" }.count
        let total = state.tasks.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
                Text("Claude current tasks")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                if total > 0 {
                    Text("\(done)/\(total) done")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            if total == 0 {
                Text("No active task list found.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            } else {
                ForEach(Array(state.tasks.prefix(4))) { task in
                    HStack(spacing: 7) {
                        Text(icon(for: task.status)).font(.system(size: 11))
                        Text(label(for: task))
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(task.status == "completed" ? 0.4 : 0.85))
                            .strikethrough(task.status == "completed", color: .white.opacity(0.3))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                }
                if total > 4 {
                    Text("... \(total - 4) more")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Divider().overlay(Color.white.opacity(0.12))
            HStack {
                Button {
                    let target = !launchAtLogin
                    do {
                        if target { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                        launchAtLogin = target
                    } catch {
                        launchAtLogin = (SMAppService.mainApp.status == .enabled)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(launchAtLogin ? Color(red: 0.30, green: 0.85, blue: 0.46) : Color.white.opacity(0.22))
                            .frame(width: 7, height: 7)
                        Text("Launch at login")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Updated \(fmtClock(state.lastUpdate))")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                Button(action: onQuit) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.6))
            }
        }
    }

    private func icon(for status: String?) -> String {
        switch status {
        case "completed": return "✓"
        case "in_progress": return "●"
        default: return "○"
        }
    }

    private func label(for task: TaskItem) -> String {
        if task.status == "in_progress", let active = task.activeForm, !active.isEmpty { return active }
        return task.subject ?? task.activeForm ?? "Task \(task.id)"
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = UsageState()
    var statusItem: NSStatusItem!
    var panel: FloatingPanel!
    var dataTimer: Timer?
    var uiTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPanel()
        refresh()
        dataTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.refresh() }
        uiTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.state.tick += 1
            self?.updateStatusTitle()
        }
        let env = ProcessInfo.processInfo.environment
        if env["TOKENMETER_SHOW"] == "1" || env["CCMETER_SHOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in self?.togglePanel() }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "⏳ TokenMeter"
            button.action = #selector(togglePanel)
            button.target = self
        }
    }

    private func setupPanel() {
        let root = PanelView(
            state: state,
            onRefresh: { [weak self] in self?.refresh() },
            onQuit: { NSApp.terminate(nil) },
            onOpenCodex: { [weak self] in self?.openCodex() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 372, height: 560),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered,
                              defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = hosting
    }

    @objc private func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) }
        else {
            refitPanel()
            positionPanel()
            panel.makeKeyAndOrderFront(nil)
            refresh()
        }
    }

    private func positionPanel() {
        guard let button = statusItem.button, let window = button.window else { return }
        let buttonFrame = window.frame
        let size = panel.frame.size
        var x = buttonFrame.midX - size.width / 2
        var y = buttonFrame.minY - size.height - 6
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            x = min(max(visible.minX + 8, x), visible.maxX - size.width - 8)
            y = max(visible.minY + 8, y)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func refitPanel() {
        guard let hosting = panel.contentView as? NSHostingView<PanelView> else { return }
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        if fit.height > 1 {
            panel.setContentSize(fit)
            panel.invalidateShadow()
        }
    }

    func refresh() {
        if state.loading { return }
        state.loading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Fetcher.fetchAll()
            DispatchQueue.main.async {
                guard let self else { return }
                self.apply(result)
                self.state.loading = false
            }
        }
    }

    private func apply(_ result: FetchResult) {
        state.providers = result.providers
        state.tasks = result.tasks
        state.lastUpdate = Date()
        updateStatusTitle()
        if panel.isVisible {
            refitPanel()
            positionPanel()
        }
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        if state.providers.isEmpty {
            button.title = "⏳ TokenMeter"
            return
        }
        let dot = statusDot()
        let parts = state.providers.map { provider in
            let marker: String
            let value: Double?
            switch provider.freshness {
            case .live:
                marker = ""
                value = provider.primaryUsed
            case .stale:
                marker = "~"
                value = provider.primaryUsed
            case .missingToken, .unavailable, .error:
                marker = "!"
                value = nil
            }
            return "\(marker)\(provider.shortName) \(fmtPct(value))"
        }
        button.title = "\(dot) " + parts.joined(separator: " · ")
    }

    private func statusDot() -> String {
        if state.providers.contains(where: { $0.limitReached == true || $0.freshness == .error }) { return "🔴" }
        if state.providers.contains(where: { [.stale, .missingToken, .unavailable].contains($0.freshness) }) { return "🟡" }
        let worst = state.providers.compactMap(\.worstUsed).max() ?? 0
        if worst >= 0.8 { return "🟡" }
        if state.providers.contains(where: { $0.hasUsableData }) { return "🟢" }
        return "⚙︎"
    }

    private func openCodex() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.open(url)
            return
        }
        let fallback = URL(fileURLWithPath: "/Applications/Codex.app")
        NSWorkspace.shared.open(fallback)
    }
}

// MARK: - Render mode

enum RenderMode {
    @MainActor static func run(to path: String) {
        let result = Fetcher.fetchAll()
        let state = UsageState()
        state.providers = result.providers
        state.tasks = result.tasks
        state.lastUpdate = Date()

        let content = ZStack {
            LinearGradient(colors: [
                Color(red: 0.10, green: 0.18, blue: 0.26),
                Color(red: 0.11, green: 0.26, blue: 0.19),
                Color(red: 0.24, green: 0.16, blue: 0.32)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
            PanelView(state: state, onRefresh: {}, onQuit: {}, onOpenCodex: {}, preview: true)
                .padding(36)
        }
        .frame(width: 460, height: 650)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        if let image = renderer.nsImage,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

// MARK: - Entrypoint

if let index = CommandLine.arguments.firstIndex(of: "--render"), index + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[index + 1]
    _ = NSApplication.shared
    MainActor.assumeIsolated { RenderMode.run(to: path) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
