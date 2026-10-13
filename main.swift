import AppKit
import ServiceManagement

// Menu bar app: "Limit: 5h 2% 7d 17%  |  Reset on: 5h 2h 7d 2d 19h"
// Reads the Claude Code login from the macOS Keychain and polls Anthropic's OAuth usage endpoint.

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
    enum Style { case plain, label, limit, reset, bar(Double) }

    static func segments(_ usage: Usage, _ now: Date) -> [(String, Style)] {
        [
            ("Limit: ", .plain),
            ("5h ", .label), (textBar(usage.fiveHour) + " ", .bar(fraction(usage.fiveHour))),
            (percent(usage.fiveHour) + " ", .limit),
            ("7d ", .label), (textBar(usage.sevenDay) + " ", .bar(fraction(usage.sevenDay))),
            (percent(usage.sevenDay), .limit),
            ("  |  Reset on: ", .plain),
            ("5h ", .label), (countdown(usage.fiveHour, now) + " ", .reset),
            ("7d ", .label), (countdown(usage.sevenDay, now), .reset),
        ]
    }

    static func titleText(_ usage: Usage, _ now: Date) -> String {
        segments(usage, now).map(\.0).joined()
    }

    static func attributedTitle(_ usage: Usage, _ now: Date, font: NSFont, suffix: String = "") -> NSAttributedString {
        func color(_ style: Style) -> NSColor? {
            switch style {
            case .plain: return nil
            case .label: return .systemGray
            case .limit: return .systemGreen
            case .reset: return .systemYellow
            case .bar: return nil
            }
        }
        let result = NSMutableAttributedString()
        for (text, style) in segments(usage, now) {
            if case .bar(let fraction) = style {
                let attachment = NSTextAttachment()
                attachment.image = barImage(fraction)
                attachment.bounds = CGRect(x: 0, y: -3, width: barSize.width, height: barSize.height)
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: " ", attributes: [.font: font]))
                continue
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if let c = color(style) { attributes[.foregroundColor] = c }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        if !suffix.isEmpty { result.append(NSAttributedString(string: suffix, attributes: [.font: font])) }
        return result
    }

    static let barSize = NSSize(width: 14, height: 14)

    static func fraction(_ window: Window) -> Double {
        min(max((window.utilization ?? 0) / 100, 0), 1)
    }

    // Plain-text fallback used by --print.
    static func textBar(_ window: Window) -> String {
        let filled = Int((fraction(window) * 8).rounded())
        return "[" + String(repeating: "█", count: filled) + String(repeating: "░", count: 8 - filled) + "]"
    }

    static func barImage(_ fraction: Double) -> NSImage {
        NSImage(size: barSize, flipped: false) { rect in
            let lineWidth: CGFloat = 2.5
            let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = inset.width / 2

            let track = NSBezierPath(ovalIn: inset)
            track.lineWidth = lineWidth
            NSColor.systemGray.withAlphaComponent(0.35).setStroke()
            track.stroke()

            if fraction > 0 {
                // Start at 12 o'clock and sweep clockwise.
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius,
                              startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                NSColor.systemGreen.setStroke()
                arc.stroke()
            }
            return true
        }
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let client = UsageClient()
    private var timer: Timer?
    private var lastUsage: Usage?
    private var lastUpdated: Date?
    private var lastError: String?

    private let updatedItem = NSMenuItem(title: "Not updated yet", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.font = Self.titleFont
        statusItem.button?.title = "Limit: …"
        buildMenu()
        refresh()

        // Poll the API every minute; re-render every 30s so the countdowns stay current in between.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.tick()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    private func buildMenu() {
        let menu = NSMenu()
        updatedItem.isEnabled = false
        menu.addItem(updatedItem)
        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
        updateLoginItemState()
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
        guard let usage = lastUsage else {
            statusItem.button?.title = "Limit: \(lastError ?? "…")"
            return
        }
        statusItem.button?.attributedTitle = UsageFormatter.attributedTitle(
            usage, Date(), font: Self.titleFont, suffix: lastError == nil ? "" : " ⚠︎")

        var status = lastUpdated.map { "Updated " + Self.timeFormatter.string(from: $0) } ?? "Not updated yet"
        if let error = lastError { status += " — \(error)" }
        updatedItem.title = status
    }

    private static let titleFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        return f
    }()

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
