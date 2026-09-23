import AppKit
import SwiftUI

/// Okienko paska menu w układzie natywnym dla macOS: tytuł, jeden przełącznik, kilka wierszy
/// stanu i skróty na dole. Bez kart, ramek i kafelków ze statystykami — te są w oknie aplikacji.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title
            protectionRow
            Divider().padding(.vertical, 6)
            statusRows
            Divider().padding(.vertical, 6)
            actions
        }
        .padding(.vertical, 8)
        .frame(width: 260)
    }

    private var title: some View {
        HStack(spacing: 6) {
            Text("MacAdBlock")
                .font(.system(size: 12, weight: .semibold))
            Text(appVersion)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var protectionRow: some View {
        Toggle(isOn: Binding(
            get: { model.protectionEnabled },
            set: { model.setProtectionEnabled($0) }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.protectionEnabled ? L("Ochrona aktywna") : L("Ochrona wyłączona"))
                    .font(.system(size: 13, weight: .medium))
                Text(model.isUpdating ? L("Aktualizowanie list…") : pauseSummary ?? sourceSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .tint(SentinelTheme.control)
        .padding(.horizontal, 14)
    }

    private var statusRows: some View {
        VStack(spacing: 5) {
            MenuStatusRow(title: L("Rozszerzenia Safari"), value: model.safariExtensionStatus, active: model.safariProtectionEnabled == true)
            MenuStatusRow(title: L("Ochrona systemowa"), value: model.hostsEnabled ? L("Aktywna") : helperStatusText, active: model.hostsEnabled)
            MenuStatusRow(title: L("Aktualizacja"), value: lastUpdateText, active: model.statistics.lastUpdated != nil)
        }
        .padding(.horizontal, 14)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.pausedUntil != nil {
                MenuActionRow(title: L("Wznów ochronę teraz"), shortcut: nil) { model.resumeProtection() }
            } else if model.protectionEnabled {
                MenuActionRow(title: L("Wstrzymaj na 5 minut"), shortcut: nil) { model.pauseProtection(for: 300) }
                MenuActionRow(title: L("Wstrzymaj na 1 godzinę"), shortcut: nil) { model.pauseProtection(for: 3_600) }
                MenuActionRow(title: L("Wstrzymaj do jutra"), shortcut: nil) { model.pauseProtectionUntilTomorrow() }
            }
            Divider().padding(.vertical, 6)

            MenuActionRow(title: model.isUpdating ? "Aktualizowanie…" : L("Aktualizuj listy"), shortcut: nil) {
                model.updateFilters()
            }
            .disabled(model.isUpdating || model.enabledSourceIDs.isEmpty)

            MenuActionRow(title: L("Subskrypcja: \(model.subscription.statusText)"), shortcut: nil) {
                model.showPaywall = true
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }

            MenuActionRow(title: L("Otwórz MacAdBlock"), shortcut: nil) {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }

            MenuActionRow(title: L("Diagnostyka i własne reguły"), shortcut: nil) {
                openWindow(id: "user-rules")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }

            SettingsLink {
                MenuRowLabel(title: L("Ustawienia…"), shortcut: nil)
            }
            .buttonStyle(.plain)

            MenuActionRow(title: L("Zakończ"), shortcut: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var pauseSummary: String? {
        guard let until = model.pausedUntil else { return nil }
        return L("Wstrzymana do \(until.formatted(date: .omitted, time: .shortened))")
    }

    private var sourceSummary: String {
        let count = model.enabledSourceIDs.count
        let rules = model.statistics.contentBlockerRuleCount + model.statistics.hostDomainCount
        guard rules > 0 else { return L("\(count) list") }
        return L("\(count) list · \(rules.formatted(.number.notation(.compactName))) reguł")
    }

    private var helperStatusText: String {
        switch model.helperStatus {
        case .enabled: L("Gotowa")
        case .requiresApproval: L("Wymaga zgody")
        case .notRegistered: L("Konfiguracja")
        case .notFound: L("Niedostępna")
        @unknown default: L("Nieznana")
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private var lastUpdateText: String {
        guard let date = model.statistics.lastUpdated else { return L("Brak") }
        return date.formatted(.relative(presentation: .named))
    }
}

/// Wiersz stanu: nazwa, wartość i kropka, która jest jedynym miejscem na kolor.
private struct MenuStatusRow: View {
    let title: String
    let value: String
    let active: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(active ? SentinelTheme.control : Color.orange)
                .frame(width: 5, height: 5)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

private struct MenuRowLabel: View {
    let title: String
    let shortcut: String?

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            if let shortcut {
                Text(shortcut).font(.system(size: 12)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

/// Wiersz zachowujący się jak pozycja menu systemowego: podświetla się pod kursorem.
private struct MenuActionRow: View {
    let title: String
    let shortcut: String?
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            MenuRowLabel(title: title, shortcut: shortcut)
                .background(
                    isHovering && isEnabled ? SentinelTheme.control.opacity(0.9) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .foregroundStyle(isHovering && isEnabled ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { isHovering = $0 }
    }
}
