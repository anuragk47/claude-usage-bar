import AppKit
import Security
import SwiftUI
import UserNotifications
import WebKit

struct UsageWindow: Identifiable, Equatable {
    let id: String
    let title: String
    let percent: Double
    let resetsAt: Date?
}

enum LoadState: Equatable {
    case idle
    case loading
    case needsSetup
    case ok
    case error(String)
}

/// Where the numbers come from.
/// - claudeCode: Claude Code's sign-in from the macOS keychain, sent to Anthropic's usage endpoint.
/// - web: a claude.ai login kept in a hidden web view, reading the same data as Settings → Usage.
enum Source: String {
    case claudeCode
    case web
}

@MainActor
final class UsageStore: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var windows: [UsageWindow] = []
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var account: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    /// Claude Code's saved sign-in has lapsed (it only renews while Claude Code is used).
    @Published private(set) var claudeCodeExpired = false
    @Published var setupMessage: String?

    var source: Source? {
        get { UserDefaults.standard.string(forKey: "source").flatMap(Source.init) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue?.rawValue, forKey: "source")
        }
    }

    var session: UsageWindow? { windows.first { $0.id == "five_hour" } }
    var weekly: [UsageWindow] { windows.filter { $0.id != "five_hour" } }

    private var timer: Timer?
    private var backoffUntil: Date?
    private var backoffStep: TimeInterval = 0
    private var credentials: ClaudeCodeCredentials?
    private var webView: WKWebView?
    private var webReady = false
    private let login = LoginController()

    static let browserUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    override init() {
        super.init()
        login.store = self
    }

    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        refresh()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common) // keeps ticking while the menu is open
        self.timer = timer
    }

    /// Opening the menu only refreshes if the numbers are more than 30 seconds old.
    func refreshIfStale() {
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < 30 { return }
        refresh()
    }

    /// The Refresh menu item: try now even if we're backing off.
    func refreshNow() {
        backoffUntil = nil
        refresh()
    }

    func refresh() {
        guard !isRefreshing else { return }
        if let backoffUntil, backoffUntil > Date(), source != nil { return }
        guard let source else { state = .needsSetup; return }
        if windows.isEmpty { state = .loading }
        switch source {
        case .claudeCode:
            isRefreshing = true
            Task { await refreshFromClaudeCode() }
        case .web:
            refreshFromWeb()
        }
    }

    // MARK: Connecting

    func useClaudeCode() {
        setupMessage = nil
        credentials = nil
        source = .claudeCode
        refresh()
    }

    /// Opens Terminal running `claude`. Starting Claude Code renews its saved sign-in; this app
    /// re-reads it on its next refresh (within a minute), so nothing else is needed.
    func renewClaudeCodeInTerminal() {
        let script = """
        #!/bin/zsh -il
        clear
        if ! command -v claude >/dev/null 2>&1; then
          echo "Claude Code isn't installed on this Mac, so there's nothing to renew."
          echo "Use \"Switch to claude.ai Sign-In\" in the Claude Usage menu instead."
          exit 0
        fi
        echo "Starting Claude Code to renew its sign-in for Claude Usage."
        echo "Once it has loaded, type /exit and press Return. You can then close this window."
        echo
        claude
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Renew Claude Code sign-in.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: .init())
            } else {
                NSWorkspace.shared.open(url)
            }
        } catch {
            NSSound.beep()
        }
    }

    /// Leaves the Claude Code sign-in and connects with claude.ai instead.
    func switchToClaudeAI() {
        signOut()
        signInWithClaudeAI()
    }

    func signInWithClaudeAI() {
        setupMessage = nil
        source = .web
        login.show()
    }

    func pasteSessionKey() {
        let alert = NSAlert()
        alert.messageText = "Paste your claude.ai session key"
        alert.informativeText = "In your browser on claude.ai, open Developer Tools → Application (Chrome) or Storage (Safari) → Cookies → claude.ai, and copy the value of “sessionKey”. It's stored only on this Mac."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        field.placeholderString = "sk-ant-sid01-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let cookie = HTTPCookie(properties: [
                  .name: "sessionKey", .value: value, .domain: ".claude.ai", .path: "/",
                  .secure: "TRUE", .expires: Date().addingTimeInterval(60 * 60 * 24 * 30),
              ]) else { return }
        setupMessage = nil
        source = .web
        state = .loading
        WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie) { [weak self] in
            Task { @MainActor in self?.reloadWeb() }
        }
    }

    func signOut() {
        claudeCodeExpired = false
        credentials = nil
        windows = []
        account = nil
        lastUpdated = nil
        let wasWeb = source == .web
        source = nil
        state = .needsSetup
        if wasWeb {
            let store = WKWebsiteDataStore.default()
            store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                let claude = records.filter { $0.displayName.contains("claude.ai") || $0.displayName.contains("anthropic") }
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: claude) {}
            }
            webView = nil
            webReady = false
        }
    }

    /// Problems that need the person to act (signed out, keychain declined) always show.
    private func fail(_ message: String) {
        state = .error(message)
    }

    /// A refresh that failed but may work next time (rate limit, server hiccup, network).
    /// While the numbers on screen are less than 15 minutes old, keep showing them quietly
    /// and back off; only warn once they're genuinely out of date.
    private func softFail(_ message: String, retryAfter: TimeInterval? = nil) {
        backoffStep = min(max(backoffStep * 2, 60), 600)
        backoffUntil = Date().addingTimeInterval(retryAfter ?? backoffStep)
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < 15 * 60, !windows.isEmpty {
            if case .error = state { state = .ok }
            return
        }
        state = .error(message)
    }

    // MARK: Claude Code

    private func refreshFromClaudeCode() async {
        defer { isRefreshing = false }
        do {
            if credentials == nil || credentials!.isExpired {
                credentials = try await Task.detached { try ClaudeCodeCredentials.read() }.value
            }
            guard let creds = credentials else { return }
            if creds.isExpired {
                credentials = nil
                claudeCodeExpired = true
                fail(windows.isEmpty ? "Claude Code's sign-in has expired. It renews itself only when you use Claude Code." : "Claude Code's sign-in has expired. It renews itself only when you use Claude Code. Showing your last numbers.")
                return
            }
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 {
                credentials = nil
                claudeCodeExpired = true
                fail(windows.isEmpty ? "Claude Code's sign-in has expired. It renews itself only when you use Claude Code." : "Claude Code's sign-in has expired. It renews itself only when you use Claude Code. Showing your last numbers.")
                return
            }
            guard code == 200, let usage = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                if code == 429 {
                    let retry = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                    softFail("Anthropic is limiting how often usage can be checked. Retrying shortly.", retryAfter: retry)
                } else {
                    softFail("The usage request failed (HTTP \(code)). Retrying shortly.")
                }
                return
            }
            apply(usage, account: creds.plan.map { "\($0) plan · via Claude Code" } ?? "Via Claude Code")
        } catch let failure as ClaudeCodeCredentials.Failure {
            if windows.isEmpty {
                // First connection didn't work (not signed in, or keychain declined):
                // go back to the choices and say why, instead of leaving a dead end.
                signOut()
                setupMessage = failure.message
            } else {
                fail(failure.message)
            }
        } catch {
            softFail(error.localizedDescription)
        }
    }

    // MARK: claude.ai

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        view.customUserAgent = Self.browserUA
        view.navigationDelegate = self
        return view
    }

    func reloadWeb() {
        webReady = false
        if webView == nil { webView = makeWebView() }
        webView?.load(URLRequest(url: URL(string: "https://claude.ai/")!))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webReady = true
        refresh()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error.localizedDescription)
    }

    private func refreshFromWeb() {
        guard let webView, webReady else {
            if webView == nil { reloadWeb() }
            return
        }
        isRefreshing = true
        Task {
            defer { isRefreshing = false }
            let js = """
            const o = await fetch('/api/organizations', {credentials: 'include'});
            if (o.status === 401 || o.status === 403) return JSON.stringify({signedOut: true});
            if (!o.ok) return JSON.stringify({error: 'claude.ai answered HTTP ' + o.status});
            const orgs = await o.json();
            if (!Array.isArray(orgs) || orgs.length === 0) return JSON.stringify({signedOut: true});
            const org = orgs.find(x => (x.capabilities || []).includes('chat')) || orgs[0];
            const u = await fetch('/api/organizations/' + org.uuid + '/usage', {credentials: 'include'});
            if (u.status === 401 || u.status === 403) return JSON.stringify({signedOut: true});
            if (!u.ok) return JSON.stringify({error: 'The usage request failed (HTTP ' + u.status + ')'});
            return JSON.stringify({org: org.name, usage: await u.json()});
            """
            do {
                let raw = try await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .defaultClient)
                guard let text = raw as? String, let data = text.data(using: .utf8),
                      let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { fail("claude.ai sent an unexpected response."); return }
                if obj["signedOut"] as? Bool == true {
                    if login.isOpen { return } // still signing in
                    signOut()
                    setupMessage = "You're signed out of claude.ai. Connect again below."
                    return
                }
                if let error = obj["error"] as? String { softFail(error + ". Retrying shortly."); return }
                apply(obj["usage"] as? [String: Any] ?? [:], account: obj["org"] as? String)
            } catch {
                softFail(error.localizedDescription)
            }
        }
    }

    // MARK: Parsing

    private func apply(_ usage: [String: Any], account: String?) {
        windows = Self.parse(usage)
        self.account = account
        lastUpdated = Date()
        backoffUntil = nil
        backoffStep = 0
        state = .ok
        claudeCodeExpired = false
        setupMessage = nil
        login.close()
        notifyIfNeeded()
    }

    private static let titles: [String: String] = [
        "five_hour": "Current session",
        "seven_day": "All models",
        "seven_day_opus": "Opus",
        "seven_day_sonnet": "Sonnet",
        "seven_day_oauth_apps": "Apps",
    ]
    private static let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]

    static func parse(_ usage: [String: Any]) -> [UsageWindow] {
        var result: [UsageWindow] = []
        for (key, value) in usage {
            guard let dict = value as? [String: Any],
                  let utilization = (dict["utilization"] as? NSNumber)?.doubleValue else { continue }
            let title = titles[key] ?? key.replacingOccurrences(of: "seven_day_", with: "")
                .replacingOccurrences(of: "_", with: " ").capitalized
            result.append(UsageWindow(id: key, title: title, percent: utilization,
                                      resetsAt: parseDate(dict["resets_at"] as? String)))
        }
        return result.sorted {
            let a = order.firstIndex(of: $0.id) ?? 99, b = order.firstIndex(of: $1.id) ?? 99
            return a == b ? $0.id < $1.id : a < b
        }
    }

    static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    // MARK: Alerts at 80% and 95%

    private func notifyIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Prefs.alerts) else { return }
        var sent = Set(defaults.stringArray(forKey: "sentAlerts") ?? [])
        for w in windows where w.id == "five_hour" || w.id == "seven_day" {
            for threshold in [80.0, 95.0] where w.percent >= threshold {
                let key = "\(w.id)-\(Int(threshold))-\(Int(w.resetsAt?.timeIntervalSince1970 ?? 0))"
                guard !sent.contains(key) else { continue }
                sent.insert(key)
                let content = UNMutableNotificationContent()
                content.title = w.id == "five_hour" ? "Claude session at \(Int(w.percent.rounded()))%"
                                                    : "Claude weekly limit at \(Int(w.percent.rounded()))%"
                if let reset = w.resetsAt { content.body = "Resets \(Format.relative(reset))." }
                content.sound = .default
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
            }
        }
        defaults.set(Array(sent.suffix(50)), forKey: "sentAlerts")
    }
}

/// Claude Code keeps its sign-in in the login keychain under "Claude Code-credentials".
/// Reading it makes macOS ask once; "Always Allow" stops the question coming back.
struct ClaudeCodeCredentials: Sendable {
    let token: String
    let expiresAt: Date?
    let plan: String?

    var isExpired: Bool { expiresAt.map { $0 < Date().addingTimeInterval(30) } ?? false }

    struct Failure: Error, Sendable { let message: String }

    static func read() throws -> ClaudeCodeCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw Failure(message: "Claude Code isn't signed in on this Mac. Sign in to Claude Code first, or pick another option below.")
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw Failure(message: "Keychain access wasn't allowed. Try again and choose Always Allow when macOS asks, or pick another option below.")
        default:
            throw Failure(message: "Couldn't read Claude Code's sign-in (keychain error \(status)).")
        }
        guard let data = item as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { throw Failure(message: "Claude Code's sign-in isn't in a format this app understands.") }
        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        let plan = (oauth["subscriptionType"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return ClaudeCodeCredentials(token: token, expiresAt: expires, plan: plan)
    }
}

enum Format {
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let secs = Int(date.timeIntervalSince(now))
        if secs <= 0 { return "now" }
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "in \(d)d \(h)h" }
        if h > 0 { return "in \(h)h \(m)m" }
        return "in \(max(m, 1))m"
    }

    static func clock(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// The one window this app ever shows: claude.ai's own sign-in page.
@MainActor
final class LoginController: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    weak var store: UsageStore?
    private var window: NSWindow?
    var isOpen: Bool { window != nil }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = UsageStore.browserUA
        web.navigationDelegate = self
        web.uiDelegate = self
        web.load(URLRequest(url: URL(string: "https://claude.ai/login")!))

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 700),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "Sign in to Claude"
        win.contentView = web
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let path = webView.url?.path, !path.hasPrefix("/login"), !path.hasPrefix("/magic-link") {
            store?.reloadWeb()
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        store?.reloadWeb()
    }
}
