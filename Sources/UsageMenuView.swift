import SwiftUI

/// The top of the status item's menu, styled like the battery and Wi-Fi menus:
/// menu-sized text, section headers, thin progress bars, no backgrounds.
struct UsageMenuView: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.source == nil {
                SetupText()
            } else if store.windows.isEmpty, case .loading = store.state {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading usage…").foregroundStyle(.secondary)
                }
            } else {
                if case .error(let message) = store.state {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let session = store.session {
                    UsageRow(title: "Current Session", window: session, emphasized: true)
                }
                if !store.weekly.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader("Weekly Limits")
                        ForEach(store.weekly) { UsageRow(title: $0.title, window: $0, emphasized: false) }
                    }
                }
                if let account = store.account {
                    Text(footer(account))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .frame(width: 280, alignment: .leading)
    }

    private func footer(_ account: String) -> String {
        guard let date = store.lastUpdated else { return account }
        let secs = Int(Date().timeIntervalSince(date))
        let updated = secs < 45 ? "updated just now" : "updated \(max(1, secs / 60)) min ago"
        return "\(account) · \(updated)"
    }
}

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

private struct UsageRow: View {
    let title: String
    let window: UsageWindow
    let emphasized: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .fontWeight(emphasized ? .semibold : .regular)
                Spacer()
                Text("\(Int(window.percent.rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(Level.tint(window.percent) == nil ? Color.secondary : Level.color(window.percent))
            }
            ProgressView(value: min(window.percent, 100), total: 100)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(Level.color(window.percent))
            if let reset = window.resetsAt {
                Text("Resets \(Format.relative(reset)) · \(Format.clock(reset))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SetupText: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Connect Your Claude Account")
                .fontWeight(.semibold)
            Text("Choose one way below. Claude Code, claude.ai and the Claude apps share the same limits, so you only need one.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = store.setupMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }
}
