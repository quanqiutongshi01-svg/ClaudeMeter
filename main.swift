import AppKit
import SwiftUI
import ServiceManagement

// MARK: - 格式化

func fmtPct(_ frac: Double?) -> String {
    guard let f = frac else { return "—" }
    return "\(Int((f * 100).rounded()))%"
}

/// 倒计时：>1天显示 Xd Yh，否则 Xh Ym / Xm
func fmtCountdown(_ date: Date?) -> String {
    guard let date else { return "—" }
    let s = Int(date.timeIntervalSinceNow)
    if s <= 0 { return "即将重置" }
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return h > 0 ? "\(d)d\(h)h" : "\(d)d" }
    if h > 0 { return "\(h)h\(m)m" }
    return "\(m)m"
}

/// 绝对重置时刻，如 "周五 02:00" 或 "今天 13:30"
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
    guard let date else { return "—" }
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    return f.string(from: date)
}

// MARK: - 任务数据

struct TaskItem: Codable, Identifiable {
    let id: String
    let subject: String?
    let status: String?
    let activeForm: String?
}

// MARK: - 官方限额（来自 /v1/messages 的 anthropic-ratelimit-unified-* 响应头）

struct OfficialUsage {
    var fiveUtil: Double?
    var fiveReset: Date?
    var fiveStatus: String?
    var weekUtil: Double?
    var weekReset: Date?
    var weekStatus: String?
    var overallStatus: String?
    var error: String?
}

// MARK: - 运行时状态

final class UsageState: ObservableObject {
    @Published var hasToken = true
    @Published var fiveUtil: Double?
    @Published var fiveReset: Date?
    @Published var weekUtil: Double?
    @Published var weekReset: Date?
    @Published var overallStatus = ""
    @Published var tasks: [TaskItem] = []
    @Published var lastUpdate: Date?
    @Published var loading = false
    @Published var errorMsg: String?
    @Published var tick = 0          // 仅用于驱动倒计时重绘
}

struct FetchResult {
    var noToken = false
    var official = OfficialUsage()
    var tasks: [TaskItem] = []
}

// MARK: - 数据获取

enum Fetcher {
    static func homeURL() -> URL { FileManager.default.homeDirectoryForCurrentUser }

    static func loadToken() -> String? {
        let url = homeURL().appendingPathComponent(".claude/ccmenubar/claude-token")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 发一个极小的 /v1/messages 请求(max_tokens=1)，只为读取统一限额响应头。
    static func fetchOfficial(token: String) -> OfficialUsage {
        var r = OfficialUsage()
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return r }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("ClaudeMeter/1.0", forHTTPHeaderField: "user-agent")
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
                r.error = err?.localizedDescription ?? "无响应"; return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                r.error = "token 失效/无权限 (\(http.statusCode))，请重跑 claude setup-token"; return
            }
            if http.statusCode != 200 { r.error = "HTTP \(http.statusCode)" }
            func h(_ k: String) -> String? { http.value(forHTTPHeaderField: k) }
            if let s = h("anthropic-ratelimit-unified-5h-utilization") { r.fiveUtil = Double(s) }
            if let s = h("anthropic-ratelimit-unified-5h-reset"), let t = Double(s) { r.fiveReset = Date(timeIntervalSince1970: t) }
            r.fiveStatus = h("anthropic-ratelimit-unified-5h-status")
            if let s = h("anthropic-ratelimit-unified-7d-utilization") { r.weekUtil = Double(s) }
            if let s = h("anthropic-ratelimit-unified-7d-reset"), let t = Double(s) { r.weekReset = Date(timeIntervalSince1970: t) }
            r.weekStatus = h("anthropic-ratelimit-unified-7d-status")
            r.overallStatus = h("anthropic-ratelimit-unified-status")
        }.resume()
        sem.wait()
        return r
    }

    static func fetchTasks() -> [TaskItem] {
        let fm = FileManager.default
        let tasksDir = homeURL().appendingPathComponent(".claude/tasks")
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
        for f in files where f.pathExtension == "json" {
            if let d = try? Data(contentsOf: f), let t = try? JSONDecoder().decode(TaskItem.self, from: d) {
                items.append(t)
            }
        }
        items.sort { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
        return items
    }

    static func fetchAll() -> FetchResult {
        var r = FetchResult()
        guard let token = loadToken() else {
            r.noToken = true; r.tasks = fetchTasks(); return r
        }
        r.official = fetchOfficial(token: token)
        r.tasks = fetchTasks()
        return r
    }
}

// MARK: - 视图组件

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = material; v.blendingMode = .behindWindow; v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

struct Bar: View {
    var ratio: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(color).frame(width: max(6, geo.size.width * min(1, max(0, ratio))))
            }
        }.frame(height: 8)
    }
    var color: Color {
        switch ratio {
        case ..<0.5: return Color(red: 0.30, green: 0.85, blue: 0.46)
        case ..<0.8: return Color(red: 0.98, green: 0.78, blue: 0.24)
        default:     return Color(red: 0.98, green: 0.36, blue: 0.36)
        }
    }
}

// MARK: - 浮窗

struct PanelView: View {
    @ObservedObject var state: UsageState
    var onRefresh: () -> Void
    var onQuit: () -> Void
    var preview: Bool = false

    @State private var launchAtLogin = (SMAppService.mainApp.status == .enabled)

    @ViewBuilder private var backgroundView: some View {
        if preview { Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.95) }
        else { VisualEffectView() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !state.hasToken {
                noTokenHint
            } else {
                window(icon: "clock.fill", title: "5 小时窗口", util: state.fiveUtil, reset: state.fiveReset)
                window(icon: "calendar", title: "本周 · 7 天", util: state.weekUtil, reset: state.weekReset)
            }
            tasksSection
            footer
        }
        .padding(16)
        .frame(width: 304)
        .background(backgroundView.clipShape(RoundedRectangle(cornerRadius: 16)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .foregroundColor(.white)
        .id(state.tick)   // 倒计时刷新
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "gauge.with.dots.needle.67percent").foregroundColor(.white.opacity(0.9))
            Text("Claude Code 用量").font(.system(size: 14, weight: .semibold))
            Text("官方").font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.white.opacity(0.16)).clipShape(Capsule()).foregroundColor(.white.opacity(0.85))
            Spacer()
            if state.loading {
                ProgressView().controlSize(.small).colorScheme(.dark)
            } else {
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundColor(.white.opacity(0.7))
            }
        }
    }

    private func window(icon: String, title: String, util: Double?, reset: Date?) -> some View {
        let u = util ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11)).foregroundColor(.white.opacity(0.7))
                Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.85))
                Spacer()
                Text(fmtCountdown(reset) + " 后重置").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.7))
            }
            Bar(ratio: u)
            HStack {
                Text("已用 \(fmtPct(util)) · 剩 \(fmtPct(util == nil ? nil : 1 - u))")
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.72))
                Spacer()
                Text(fmtResetClock(reset)).font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
            }
        }
    }

    private var noTokenHint: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("⚙︎ 未配置 token").font(.system(size: 12, weight: .medium)).foregroundColor(.orange.opacity(0.95))
            Text("终端运行 claude setup-token，把 token 存到\n~/.claude/ccmenubar/claude-token")
                .font(.system(size: 10)).foregroundColor(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tasksSection: some View {
        let done = state.tasks.filter { $0.status == "completed" }.count
        let total = state.tasks.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checklist").font(.system(size: 11)).foregroundColor(.white.opacity(0.7))
                Text("当前任务").font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.85))
                Spacer()
                if total > 0 { Text("\(done)/\(total) 完成").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.7)) }
            }
            if total == 0 {
                Text("暂无进行中的任务").font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
            } else {
                ForEach(Array(state.tasks.prefix(6))) { t in
                    HStack(spacing: 7) {
                        Text(icon(for: t.status)).font(.system(size: 11))
                        Text(label(for: t)).font(.system(size: 11))
                            .foregroundColor(.white.opacity(t.status == "completed" ? 0.4 : 0.85))
                            .strikethrough(t.status == "completed", color: .white.opacity(0.3))
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                }
                if total > 6 { Text("…还有 \(total - 6) 条").font(.system(size: 10)).foregroundColor(.white.opacity(0.4)) }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let e = state.errorMsg { Text("⚠︎ \(e)").font(.system(size: 10)).foregroundColor(.orange.opacity(0.9)).fixedSize(horizontal: false, vertical: true) }
            Divider().overlay(Color.white.opacity(0.12))
            HStack {
                Button {
                    let target = !launchAtLogin
                    do { if target { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; launchAtLogin = target }
                    catch { launchAtLogin = (SMAppService.mainApp.status == .enabled) }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(launchAtLogin ? Color(red: 0.30, green: 0.85, blue: 0.46) : Color.white.opacity(0.22)).frame(width: 7, height: 7)
                        Text("开机自启").font(.system(size: 10))
                    }.foregroundColor(.white.opacity(0.6))
                }.buttonStyle(.plain)
                Spacer()
                Text("更新 \(fmtClock(state.lastUpdate))").font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
                Button(action: onQuit) { Image(systemName: "power").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundColor(.white.opacity(0.6))
            }
        }
    }

    private func icon(for status: String?) -> String {
        switch status { case "completed": return "✅"; case "in_progress": return "🔵"; default: return "⚪️" }
    }
    private func label(for t: TaskItem) -> String {
        if t.status == "in_progress", let a = t.activeForm, !a.isEmpty { return a }
        return t.subject ?? t.activeForm ?? "任务 \(t.id)"
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
        // 数据刷新：每 120s 发一次极小请求读官方限额
        dataTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.refresh() }
        // 仅刷新倒计时显示，不发请求
        uiTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.state.tick += 1
            self?.updateStatusTitle()
        }
        if ProcessInfo.processInfo.environment["CCMETER_SHOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in self?.togglePanel() }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.title = "⏳ Claude"
            b.action = #selector(togglePanel); b.target = self
        }
    }

    private func setupPanel() {
        let root = PanelView(state: state, onRefresh: { [weak self] in self?.refresh() }, onQuit: { NSApp.terminate(nil) })
        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 304, height: 360),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        else { refitPanel(); positionPanel(); panel.makeKeyAndOrderFront(nil); refresh() }
    }

    private func positionPanel() {
        guard let button = statusItem.button, let bw = button.window else { return }
        let bf = bw.frame; let size = panel.frame.size
        var x = bf.midX - size.width / 2; var y = bf.minY - size.height - 6
        if let screen = NSScreen.main {
            let vis = screen.visibleFrame
            x = min(max(vis.minX + 8, x), vis.maxX - size.width - 8)
            y = max(vis.minY + 8, y)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func refitPanel() {
        guard let hosting = panel.contentView as? NSHostingView<PanelView> else { return }
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        if fit.height > 1 { panel.setContentSize(fit); panel.invalidateShadow() }
    }

    func refresh() {
        if state.loading { return }
        state.loading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Fetcher.fetchAll()
            DispatchQueue.main.async {
                guard let self else { return }
                self.apply(result); self.state.loading = false
            }
        }
    }

    private func apply(_ r: FetchResult) {
        state.hasToken = !r.noToken
        state.fiveUtil = r.official.fiveUtil; state.fiveReset = r.official.fiveReset
        state.weekUtil = r.official.weekUtil; state.weekReset = r.official.weekReset
        state.overallStatus = r.official.overallStatus ?? ""
        state.tasks = r.tasks
        state.lastUpdate = Date()
        state.errorMsg = r.noToken ? nil : r.official.error
        updateStatusTitle()
        if panel.isVisible { refitPanel(); positionPanel() }
    }

    private func updateStatusTitle() {
        guard let b = statusItem.button else { return }
        if !state.hasToken { b.title = "⚙︎ 待配置"; return }
        let u5 = state.fiveUtil ?? 0, u7 = state.weekUtil ?? 0
        let worst = max(u5, u7)
        let dot: String
        if state.overallStatus == "rejected" { dot = "🔴" }
        else if state.overallStatus.contains("warning") || worst >= 0.8 { dot = "🟡" }
        else { dot = "🟢" }
        let p5 = Int((u5 * 100).rounded()), p7 = Int((u7 * 100).rounded())
        b.title = "\(dot) 5h \(p5)%·\(fmtCountdown(state.fiveReset)) · 周 \(p7)%·\(fmtCountdown(state.weekReset))"
    }
}

// MARK: - 渲染模式（无屏幕权限时导出浮窗 PNG）

enum RenderMode {
    @MainActor static func run(to path: String) {
        let res = Fetcher.fetchAll()
        let st = UsageState()
        st.hasToken = !res.noToken
        st.fiveUtil = res.official.fiveUtil; st.fiveReset = res.official.fiveReset
        st.weekUtil = res.official.weekUtil; st.weekReset = res.official.weekReset
        st.overallStatus = res.official.overallStatus ?? ""
        st.tasks = res.tasks; st.lastUpdate = Date(); st.errorMsg = res.official.error

        let content = ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.33, blue: 0.56), Color(red: 0.33, green: 0.18, blue: 0.46)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            PanelView(state: st, onRefresh: {}, onQuit: {}, preview: true).padding(40)
        }.frame(width: 384, height: 470)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

// MARK: - 入口

if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[i + 1]
    _ = NSApplication.shared
    MainActor.assumeIsolated { RenderMode.run(to: path) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
