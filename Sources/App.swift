import AppKit
import Combine
import ServiceManagement
import SwiftUI

@main
struct ClaudeUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // A menu bar app has no main window; everything lives in the status item's menu.
        Settings { EmptyView() }
    }
}

enum Prefs {
    static let showWeekly = "showWeekly"
    static let alerts = "alerts"
}

/// Usage levels: amber when the session is getting close to its limit, red when it's nearly out.
enum Level {
    static func tint(_ percent: Double) -> NSColor? {
        if percent >= 90 { return .systemRed }
        if percent >= 75 { return .systemOrange }
        return nil
    }

    static func color(_ percent: Double) -> Color {
        tint(percent).map { Color(nsColor: $0) } ?? .accentColor
    }

    static func symbol(_ percent: Double?) -> String {
        guard let p = percent else { return "gauge.with.dots.needle.0percent" }
        switch p {
        case ..<20: return "gauge.with.dots.needle.0percent"
        case ..<45: return "gauge.with.dots.needle.33percent"
        case ..<60: return "gauge.with.dots.needle.50percent"
        case ..<85: return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.100percent"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = UsageStore()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var usageView: NSHostingView<AnyView>!
    private var bag = Set<AnyCancellable>()
    private var builtForSetup: Bool?
    private var builtExpired: Bool?
    private var builtWithData: Bool?

    private static let menuWidth: CGFloat = 280

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Prefs.showWeekly: true, Prefs.alerts: true])
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        usageView = NSHostingView(rootView: AnyView(UsageMenuView().environmentObject(store)))
        rebuildMenu()

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateButton()
                self.fitUsageView()
                if self.builtForSetup != (self.store.source == nil) || self.builtExpired != self.store.claudeCodeExpired
                    || self.builtWithData != !self.store.windows.isEmpty { self.rebuildMenu() }
            }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &bag)

        updateButton()
        store.start()

        // First launch: open the menu so the person can connect an account.
        if store.source == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.statusItem.button?.performClick(nil)
            }
        }
    }

    // MARK: Status item

    private func updateButton() {
        guard let button = statusItem?.button else { return }
        let percent = store.session?.percent
        let tint = percent.flatMap(Level.tint)

        var config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if let tint { config = config.applying(NSImage.SymbolConfiguration(paletteColors: [tint])) }
        let image = NSImage(systemSymbolName: Level.symbol(percent), accessibilityDescription: "Claude usage")?
            .withSymbolConfiguration(config)
        image?.isTemplate = tint == nil
        button.image = image

        // Text beside the gauge: session % always, weekly % when turned on ("42% · 18%"), each coloured by its own level.
        let defaults = UserDefaults.standard
        let weekly = store.windows.first { $0.id == "seven_day" }?.percent
        var parts: [(String, NSColor?)] = []
        if let percent { parts.append(("\(Int(percent.rounded()))%", tint)) }
        if defaults.bool(forKey: Prefs.showWeekly), let weekly { parts.append(("\(Int(weekly.rounded()))%", Level.tint(weekly))) }

        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        if parts.isEmpty {
            button.imagePosition = .imageOnly
            button.title = ""
        } else if parts.allSatisfy({ $0.1 == nil }) {
            // Plain title so macOS draws it like other menu bar text.
            button.imagePosition = .imageLeading
            button.font = font
            button.title = " " + parts.map { $0.0 }.joined(separator: " · ")
        } else {
            button.imagePosition = .imageLeading
            let title = NSMutableAttributedString(string: " ", attributes: [.font: font])
            for (i, part) in parts.enumerated() {
                if i > 0 {
                    title.append(NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
                }
                title.append(NSAttributedString(string: part.0, attributes: [.font: font, .foregroundColor: part.1 ?? NSColor.labelColor]))
            }
            button.attributedTitle = title
        }

        var tip: [String] = []
        if let percent { tip.append("Session \(Int(percent.rounded()))% used") }
        if let weekly { tip.append("Weekly \(Int(weekly.rounded()))% used") }
        button.toolTip = tip.isEmpty ? "Claude Usage" : tip.joined(separator: " · ")
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        store.refreshIfStale()
        fitUsageView()
    }

    private func fitUsageView() {
        guard let usageView else { return }
        usageView.frame = NSRect(x: 0, y: 0, width: Self.menuWidth, height: 10)
        let height = usageView.fittingSize.height
        usageView.frame = NSRect(x: 0, y: 0, width: Self.menuWidth, height: height)
    }

    private func rebuildMenu() {
        let setup = store.source == nil
        builtForSetup = setup
        builtExpired = store.claudeCodeExpired
        builtWithData = !store.windows.isEmpty
        menu.removeAllItems()

        let usageItem = NSMenuItem()
        usageItem.view = usageView
        menu.addItem(usageItem)
        fitUsageView()
        menu.addItem(.separator())

        if setup {
            // Three ways to connect, best first, each with a one-line explanation underneath.
            option("Sign In to claude.ai…",
                   detail: "Recommended. Opens claude.ai's sign-in page; use your email, as Google sign-in may not work there.",
                   #selector(signInWithClaudeAI))
            option("Use Claude Code on This Mac",
                   detail: "Best if you use Claude Code every day: its sign-in lapses when you don't. macOS asks once for keychain access; choose Always Allow.",
                   #selector(useClaudeCode))
            option("Paste Session Key…",
                   detail: "Advanced: copy the sessionKey cookie from claude.ai in your browser.",
                   #selector(pasteSessionKey))
        } else {
            add("Refresh", #selector(refresh), key: "r")
            if store.claudeCodeExpired {
                option("Renew in Terminal…",
                       detail: "Starts Claude Code in Terminal, which renews its sign-in. Type /exit once it has loaded.",
                       #selector(renewClaudeCode))
                option("Switch to claude.ai Sign-In…",
                       detail: "Doesn't lapse when you don't use Claude Code.",
                       #selector(switchToClaudeAI))
            } else if store.windows.isEmpty {
                // Nothing has loaded yet: offer a way out instead of leaving people stuck.
                option("Choose Another Way to Connect…",
                       detail: "Disconnects, so you can pick a different sign-in option.",
                       #selector(disconnect))
            }
        }
        menu.addItem(.separator())

        add("Open Claude", #selector(openClaude))
        add("Usage Settings", #selector(openUsageSettings))
        add("Plans & Billing", #selector(openBilling))
        menu.addItem(.separator())

        let options = NSMenuItem(title: "Options", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        add("Show Weekly % in Menu Bar", #selector(toggleShowWeekly), to: sub).state =
            UserDefaults.standard.bool(forKey: Prefs.showWeekly) ? .on : .off
        add("Alert at 80% and 95%", #selector(toggleAlerts), to: sub).state =
            UserDefaults.standard.bool(forKey: Prefs.alerts) ? .on : .off
        add("Open at Login", #selector(toggleOpenAtLogin), to: sub).state =
            SMAppService.mainApp.status == .enabled ? .on : .off
        if !setup {
            sub.addItem(.separator())
            add("Disconnect Account", #selector(disconnect), to: sub)
        }
        options.submenu = sub
        menu.addItem(options)
        menu.addItem(.separator())
        add("Quit Claude Usage", #selector(quit), key: "q")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.menu { rebuildMenu() }
    }

    /// A setup choice: the action, with a short explanation as the item's subtitle
    /// (macOS 14.4+) or as a dimmed line beneath it on older systems.
    private func option(_ title: String, detail: String, _ action: Selector) {
        let item = add(title, action)
        if #available(macOS 14.4, *) {
            item.subtitle = detail
        } else {
            let note = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
            note.isEnabled = false
            note.indentationLevel = 1
            menu.addItem(note)
        }
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, key: String = "", to target: NSMenu? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        (target ?? menu).addItem(item)
        return item
    }

    // MARK: Actions

    @objc private func refresh() { store.refreshNow() }
    @objc private func useClaudeCode() { store.useClaudeCode() }
    @objc private func renewClaudeCode() { store.renewClaudeCodeInTerminal() }
    @objc private func switchToClaudeAI() { store.switchToClaudeAI() }
    @objc private func signInWithClaudeAI() { store.signInWithClaudeAI() }
    @objc private func pasteSessionKey() {
        // Let the menu finish closing before the dialog appears.
        DispatchQueue.main.async { [weak self] in self?.store.pasteSessionKey() }
    }
    @objc private func disconnect() { store.signOut() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openClaude() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        } else {
            open("https://claude.ai")
        }
    }
    @objc private func openUsageSettings() { open("https://claude.ai/settings/usage") }
    @objc private func openBilling() { open("https://claude.ai/settings/billing") }
    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    @objc private func toggleShowWeekly() {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: Prefs.showWeekly), forKey: Prefs.showWeekly)
    }
    @objc private func toggleAlerts() {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: Prefs.alerts), forKey: Prefs.alerts)
    }
    @objc private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSSound.beep()
        }
    }
}
