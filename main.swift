import AppKit
import ServiceManagement
import SwiftUI

// Menu bar app: [gauge] 5h/2% 7d/17% | [clock] 5h/2h 7d/2d 19h, each small label stacked above its value.
// Reads the Claude Code login from the macOS Keychain and polls Anthropic's OAuth usage endpoint.
// When the menu bar has no room for the item, the stats move into an island at the top of every display.

struct Window {
    let utilization: Double?
    let resetsAt: Date?
}

struct Usage {
    let fiveHour: Window
    let sevenDay: Window
}

enum UsageError: Error {
    case noCredentials
    case unauthorized
    case http(Int)
    case badResponse
}

final class UsageClient {
    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    func fetch() async throws -> Usage {
        let token = try await Task.detached { try Self.readAccessToken() }.value
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-usage-bar/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw UsageError.unauthorized }
        guard http.statusCode == 200 else { throw UsageError.http(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.badResponse
        }
        return Usage(fiveHour: Self.window(json["five_hour"]), sevenDay: Self.window(json["seven_day"]))
    }

    private static func window(_ value: Any?) -> Window {
        guard let dict = value as? [String: Any] else { return Window(utilization: nil, resetsAt: nil) }
        let utilization = (dict["utilization"] as? NSNumber)?.doubleValue
        let resetsAt = (dict["resets_at"] as? String).flatMap(parseDate)
        return Window(utilization: utilization, resetsAt: resetsAt)
    }

    private static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    // Claude Code stores its OAuth login in the Keychain (service "Claude Code-credentials"),
    // or in ~/.claude/.credentials.json on some setups.
    private static func readAccessToken() throws -> String {
        if let blob = keychainBlob() ?? fileBlob(), let token = accessToken(in: blob) { return token }
        throw UsageError.noCredentials
    }

    private static func keychainBlob() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    private static func fileBlob() -> Data? {
        let path = NSHomeDirectory() + "/.claude/.credentials.json"
        return FileManager.default.contents(atPath: path)
    }

    private static func accessToken(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }
}

enum UsageFormatter {
    static func titleText(_ usage: Usage, _ now: Date) -> String {
        "Limit: 5h \(percent(usage.fiveHour)) 7d \(percent(usage.sevenDay))"
            + "  |  Reset on: 5h \(countdown(usage.fiveHour, now)) 7d \(countdown(usage.sevenDay, now))"
    }

    static func fraction(_ window: Window) -> Double {
        min(max((window.utilization ?? 0) / 100, 0), 1)
    }

    static func percent(_ window: Window) -> String {
        guard let value = window.utilization else { return "0%" }
        return "\(Int(value.rounded()))%"
    }

    static func countdown(_ window: Window, _ now: Date) -> String {
        guard let reset = window.resetsAt else { return "–" }
        let minutes = max(0, Int(reset.timeIntervalSince(now) / 60))
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let mins = minutes % 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if days == 0 && mins > 0 { parts.append("\(mins)m") }
        return parts.isEmpty ? "0m" : parts.joined(separator: " ")
    }
}

struct UsageSnapshot {
    var usage: Usage?
    var error: String?
    var updated: Date?
    var now = Date()
}

// MARK: Shared views

enum Palette {
    static let limit = Color(nsColor: .systemGreen)
    static let reset = Color(nsColor: .systemYellow)
    static let limitSymbol = "gauge.with.dots.needle.33percent"
    static let resetSymbol = "clock.arrow.circlepath"
}

// A small label stacked above its value, like the system's own menu bar stats.
struct StackedStat: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: -2) {
            Text(label).font(.system(size: 8, weight: .semibold)).foregroundColor(.secondary)
            Text(value).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundColor(color)
        }
        .fixedSize()
    }
}

// MARK: Menu bar title

struct MenuBarView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: Palette.limitSymbol)
            if let usage = snapshot.usage {
                StackedStat(label: "5h", value: UsageFormatter.percent(usage.fiveHour), color: Palette.limit)
                StackedStat(label: "7d", value: UsageFormatter.percent(usage.sevenDay), color: Palette.limit)
                Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 1, height: 14).padding(.horizontal, 2)
                Image(systemName: Palette.resetSymbol)
                StackedStat(label: "5h", value: UsageFormatter.countdown(usage.fiveHour, snapshot.now), color: Palette.reset)
                StackedStat(label: "7d", value: UsageFormatter.countdown(usage.sevenDay, snapshot.now), color: Palette.reset)
                if snapshot.error != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                }
            } else {
                Text(snapshot.error ?? "…").font(.system(size: 12))
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 5)
        .frame(maxHeight: .infinity)
        .fixedSize(horizontal: true, vertical: false)
    }
}

// Draws SwiftUI inside the status item button but lets clicks reach the button so its menu still opens.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: Notch island

struct IslandMetrics: Equatable {
    var notch = CGSize(width: 0, height: 24)   // the hardware notch, or a stand-in on screens without one
    var midX: CGFloat = 0                      // notch center in screen coordinates
    var top: CGFloat = 0                       // top edge of the screen
    static let standInWidth: CGFloat = 100     // width of the stand-in notch on screens without one
    static let ear: CGFloat = 14               // widest top "ear" curve, outside the island body
    static let margin: CGFloat = 30            // room for the shadow

    init() {}

    init(screen: NSScreen) {
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = CGSize(width: frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
            midX = frame.minX + left.width + notch.width / 2
        } else {
            // No notch: hang a stand-in notch from the middle of the menu bar, so there is something to hover.
            let menuBar = frame.maxY - screen.visibleFrame.maxY
            notch = CGSize(width: Self.standInWidth, height: menuBar > 0 ? menuBar : 24)
            midX = frame.midX
        }
        top = frame.maxY
    }

    // Collapsed, the island is just the notch itself and shows nothing until hovered.
    var collapsed: CGSize { notch }
    var expanded: CGSize { CGSize(width: max(notch.width + 290, 340), height: notch.height + 160) }
    var panel: CGSize { CGSize(width: expanded.width + (Self.ear + Self.margin) * 2, height: expanded.height + Self.margin) }

    func rect(expanded isExpanded: Bool) -> NSRect {
        let size = isExpanded ? expanded : collapsed
        return NSRect(x: midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }
}

final class IslandModel: ObservableObject {
    @Published var snapshot = UsageSnapshot()
    @Published var expanded = false
    @Published var metrics = IslandMetrics()
    var onRefresh: () -> Void = {}
    var onMenu: () -> Void = {}
}

// Notch outline: concave "ears" where it meets the top edge, rounded corners at the bottom.
struct IslandShape: Shape {
    var ear: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, radius) }
        set { ear = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + ear, y: rect.minY + ear), control: CGPoint(x: rect.minX + ear, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + ear, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + ear + r, y: rect.maxY), control: CGPoint(x: rect.minX + ear, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - ear - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - ear, y: rect.maxY - r), control: CGPoint(x: rect.maxX - ear, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - ear, y: rect.minY + ear))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - ear, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel

    private var size: CGSize { model.expanded ? model.metrics.expanded : model.metrics.collapsed }
    private var ear: CGFloat { model.expanded ? IslandMetrics.ear : 0 }

    var body: some View {
        VStack(spacing: 0) {
            if model.expanded {
                expandedHeader.frame(height: model.metrics.notch.height).transition(.opacity)
                details.transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
            }
        }
        .padding(.horizontal, model.expanded ? 18 : 12)
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
        .background(
            IslandShape(ear: ear, radius: model.expanded ? 28 : 8)
                // Black at the top so it merges with the notch, fading slightly towards the bottom.
                .fill(LinearGradient(colors: [.black, .black.opacity(0.82)], startPoint: .top, endPoint: .bottom))
                .frame(width: size.width + ear * 2)
                .shadow(color: .black.opacity(model.expanded ? 0.45 : 0), radius: 14, y: 6)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: model.expanded)
    }

    private var expandedHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: Palette.limitSymbol).foregroundColor(Palette.limit)
            Text("Claude Usage").foregroundColor(.white)
            Spacer(minLength: model.metrics.notch.width)
            IslandButton(symbol: "arrow.clockwise", action: model.onRefresh)
            IslandButton(symbol: "ellipsis", action: model.onMenu)
        }
        .font(.system(size: 12, weight: .semibold))
    }

    private var details: some View {
        VStack(spacing: 12) {
            if let usage = model.snapshot.usage {
                UsageRow(title: "5-hour limit", window: usage.fiveHour, now: model.snapshot.now)
                UsageRow(title: "7-day limit", window: usage.sevenDay, now: model.snapshot.now)
            } else {
                Text(model.snapshot.error ?? "Loading…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(maxHeight: .infinity)
            }
            HStack(spacing: 4) {
                if let updated = model.snapshot.updated {
                    Text("Updated \(Text(updated, style: .time))")
                }
                if model.snapshot.usage != nil, let error = model.snapshot.error {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(error).lineLimit(1)
                }
                Spacer()
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(0.45))
        }
        .padding(.top, 12)
    }
}

struct UsageRow: View {
    let title: String
    let window: Window
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.7))
                Spacer()
                Text(UsageFormatter.percent(window))
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(Palette.limit)
            }
            ProgressCapsule(fraction: UsageFormatter.fraction(window))
            HStack(spacing: 4) {
                Image(systemName: Palette.resetSymbol)
                Text("Resets in \(Text(UsageFormatter.countdown(window, now)).foregroundColor(Palette.reset))")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(0.5))
        }
    }
}

struct ProgressCapsule: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(LinearGradient(colors: [Palette.limit.opacity(0.7), Palette.limit], startPoint: .leading, endPoint: .trailing))
                    .frame(width: fraction > 0 ? max(geo.size.width * fraction, 5) : 0)
            }
        }
        .frame(height: 5)
    }
}

struct IslandButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var onRightClick: () -> Void = {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { onRightClick() }
}

final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        ignoresMouseEvents = true
        // Above the menu bar and its status items, below menus.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    // Borderless windows are normally pushed below the menu bar; the island has to sit on top of it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// One island on one display: around the notch, or hanging from the middle of the menu bar.
final class IslandController {
    private let screen: NSScreen
    private let model = IslandModel()
    private let panel = IslandPanel()
    private var monitors: [Any] = []
    private var exitTimer: Timer?
    private var collapseWork: DispatchWorkItem?
    private(set) var isShown = false

    init(screen: NSScreen, onRefresh: @escaping () -> Void, onMenu: @escaping () -> Void) {
        self.screen = screen
        model.onRefresh = onRefresh
        model.onMenu = onMenu
        let host = IslandHostingView(rootView: IslandView(model: model))
        host.sizingOptions = []
        host.onRightClick = onMenu
        panel.contentView = host
    }

    func update(_ snapshot: UsageSnapshot) {
        model.snapshot = snapshot
    }

    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        if shown {
            layout()
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }
            startTracking()
        } else {
            stopTracking()
            setExpanded(false)
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }) { [weak self] in
                guard let self, !self.isShown else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    func close() {
        isShown = false
        stopTracking()
        exitTimer?.invalidate()
        collapseWork?.cancel()
        panel.orderOut(nil)
    }

    private func layout() {
        let metrics = IslandMetrics(screen: screen)
        model.metrics = metrics
        let size = metrics.panel
        panel.setFrame(NSRect(x: metrics.midX - size.width / 2, y: metrics.top - size.height,
                              width: size.width, height: size.height), display: true)
    }

    // Hover is tracked with event monitors because the panel ignores the mouse while collapsed,
    // so the menu bar under its transparent area keeps working.
    private func startTracking() {
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.mouseMoved() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { handler($0); return $0 }) {
            monitors.append(local)
        }
    }

    private func stopTracking() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func mouseMoved() {
        let inside = model.metrics.rect(expanded: model.expanded).insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
        if inside {
            collapseWork?.cancel()
            collapseWork = nil
            if !model.expanded { setExpanded(true) }
        } else if model.expanded && collapseWork == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.collapseWork = nil
                self?.setExpanded(false)
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard model.expanded != expanded else { return }
        model.expanded = expanded
        panel.ignoresMouseEvents = !expanded
        exitTimer?.invalidate()
        exitTimer = nil
        if expanded {
            // Mouse-moved events over our own non-key panel are not always delivered, so poll for the exit.
            exitTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.mouseMoved() }
        }
    }
}

enum IslandMode: String, CaseIterable {
    case automatic, always, never

    var title: String {
        switch self {
        case .automatic: return "When Icons Would Be Hidden"
        case .always: return "Always"
        case .never: return "Never"
        }
    }
}

// MARK: App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let client = UsageClient()
    private var timer: Timer?
    private var islandTimer: Timer?
    private var titleWidth: CGFloat = 0
    private var lastUsage: Usage?
    private var lastUpdated: Date?
    private var lastError: String?

    private let menu = NSMenu()
    private let updatedItem = NSMenuItem(title: "Not updated yet", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let islandMenu = NSMenu()
    private let titleView = ClickThroughHostingView(rootView: MenuBarView(snapshot: UsageSnapshot()))
    private var islands: [IslandController] = []
    private var snapshot = UsageSnapshot()
    private var islandCheck: DispatchWorkItem?

    private var islandMode: IslandMode {
        get { IslandMode(rawValue: UserDefaults.standard.string(forKey: "islandMode") ?? "") ?? .automatic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "islandMode") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            titleView.autoresizingMask = [.height]
            button.addSubview(titleView)
        }
        buildMenu()
        makeIslands()
        render()
        updateIsland()
        refresh()

        // Poll the API every minute; re-render every 30s so the countdowns stay current in between.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.tick()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh),
            name: NSWorkspace.didWakeNotification, object: nil)

        // Other apps add and remove menu bar icons without telling anyone, so re-check the space regularly
        // as well as on the events that usually change it.
        islandTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.updateIsland()
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowChanged(_:)), name: NSWindow.didMoveNotification, object: nil)
        center.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(scheduleIslandCheck),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    private func buildMenu() {
        updatedItem.isEnabled = false
        menu.addItem(updatedItem)
        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        loginItem.target = self
        menu.addItem(loginItem)
        for mode in IslandMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectIslandMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            islandMenu.addItem(item)
        }
        let islandItem = NSMenuItem(title: "Show in Notch", action: nil, keyEquivalent: "")
        islandItem.submenu = islandMenu
        menu.addItem(islandItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
        updateLoginItemState()
        updateIslandMenuState()
    }

    private func tick() {
        let stale = lastUpdated.map { Date().timeIntervalSince($0) >= 60 } ?? true
        if stale { refresh() } else { render() }
    }

    @objc private func refresh() {
        Task { @MainActor in
            do {
                lastUsage = try await client.fetch()
                lastUpdated = Date()
                lastError = nil
            } catch UsageError.noCredentials {
                lastError = "Not logged in to Claude Code"
            } catch UsageError.unauthorized {
                lastError = "Login expired — open Claude Code"
            } catch UsageError.http(let code) {
                lastError = "HTTP \(code)"
            } catch {
                lastError = "Offline"
            }
            render()
        }
    }

    private func render() {
        snapshot = UsageSnapshot(usage: lastUsage, error: lastError, updated: lastUpdated)
        titleView.rootView = MenuBarView(snapshot: snapshot)
        titleWidth = ceil(titleView.fittingSize.width)
        statusItem.length = titleWidth
        titleView.frame = NSRect(x: 0, y: 0, width: titleWidth,
                                 height: statusItem.button?.bounds.height ?? NSStatusBar.system.thickness)
        islands.forEach { $0.update(snapshot) }

        var status = lastUpdated.map { "Updated " + Self.timeFormatter.string(from: $0) } ?? "Not updated yet"
        if let error = lastError { status += " — \(error)" }
        updatedItem.title = status
        scheduleIslandCheck()
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        return f
    }()

    // MARK: Notch island

    @objc private func windowChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === statusItem.button?.window else { return }
        scheduleIslandCheck()
    }

    @objc private func screensChanged() {
        makeIslands()
        scheduleIslandCheck()
    }

    // The menu bar item can't be hidden on just one display, so when the stats leave the menu bar
    // every display gets an island; otherwise displays without a notch would show nothing.
    private func makeIslands() {
        islands.forEach { $0.close() }
        islands = NSScreen.screens.map { screen in
            let island = IslandController(
                screen: screen,
                onRefresh: { [weak self] in self?.refresh() },
                onMenu: { [weak self] in self?.menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) })
            island.update(snapshot)
            return island
        }
    }

    // Debounced, because the menu bar shuffles items around briefly while apps launch and switch.
    @objc private func scheduleIslandCheck() {
        islandCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateIsland() }
        islandCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // The stats live in exactly one place: the menu bar item or the island.
    private func updateIsland() {
        let showIsland: Bool
        switch islandMode {
        case .always: showIsland = true
        case .never: showIsland = false
        case .automatic: showIsland = statsWouldHideIcons()
        }
        if statusItem.isVisible == showIsland { statusItem.isVisible = !showIsland }
        islands.forEach { $0.setShown(showIsland) }
    }

    // Whether the stats plus every other menu bar icon are wider than the space right of the notch,
    // so macOS would have to hide some icons behind it. Icons macOS has hidden are still in the window
    // list, so the total is the same whether or not our own item is currently in the menu bar.
    private func statsWouldHideIcons() -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let space = screen.auxiliaryTopRightArea?.width,
              let primary = NSScreen.screens.first else { return false }
        // The window list uses top-left origin coordinates.
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        let menuBar = flipped(CGRect(x: screen.frame.minX, y: screen.frame.maxY - screen.safeAreaInsets.top,
                                     width: screen.frame.width, height: screen.safeAreaInsets.top))
        let own = statusItem.isVisible ? statusItem.button?.window : nil
        let ownFrame = own.map { flipped($0.frame) }

        let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var others: CGFloat = 0
        for info in windows where info[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.statusWindow)) {
            guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.height <= menuBar.height + 2,
                  menuBar.contains(CGPoint(x: bounds.midX, y: bounds.midY)) else { continue }
            if let own, info[kCGWindowNumber as String] as? Int == own.windowNumber { continue }
            if let ownFrame, abs(bounds.minX - ownFrame.minX) < 2, abs(bounds.width - ownFrame.width) < 2 { continue }
            others += bounds.width
        }
        // A little slack once the island is up, so a few points of change don't bounce the stats back and forth.
        let slack: CGFloat = islands.contains(where: \.isShown) ? 8 : 0
        return others + titleWidth > space - slack
    }

    @objc private func selectIslandMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = IslandMode(rawValue: raw) else { return }
        islandMode = mode
        updateIslandMenuState()
        updateIsland()
    }

    private func updateIslandMenuState() {
        for item in islandMenu.items {
            item.state = (item.representedObject as? String) == islandMode.rawValue ? .on : .off
        }
    }

    // MARK: Launch at login

    private func updateLoginItemState() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSSound.beep()
        }
        updateLoginItemState()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateLoginItemState()
        render()
    }
}

// `ClaudeUsageBar --print` writes the title text to stdout and exits (handy for debugging).
if CommandLine.arguments.contains("--print") {
    Task {
        do {
            let usage = try await UsageClient().fetch()
            print(UsageFormatter.titleText(usage, Date()))
            exit(0)
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
