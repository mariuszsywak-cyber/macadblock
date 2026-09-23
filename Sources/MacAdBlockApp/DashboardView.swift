import AppKit
import Charts
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: SidebarItem? = .dashboard

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                SidebarProtectionToggle()
                    .environmentObject(model)
                    .padding(12)

                List(SidebarItem.allCases) { item in
                    Button {
                        selection = item
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(selection == item ? SentinelTheme.sidebarSelectedIcon : SentinelTheme.accent)
                                .frame(width: 24)
                            Text(item.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(selection == item ? SentinelTheme.sidebarSelectedText : Color.primary)
                            Spacer(minLength: 0)
                            if let badge = item.badge(model) {
                                Text(badge)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(selection == item ? .white.opacity(0.8) : .secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background {
                            if selection == item {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(SentinelTheme.sidebarSelection(for: colorScheme))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(SentinelTheme.accent.opacity(0.55), lineWidth: 1)
                                    }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 8) {
                        SidebarStatusView()
                            .environmentObject(model)
                        SettingsLink {
                            Label(L("Ustawienia"), systemImage: "gearshape")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                    .padding(10)
                }
            }
            .background(SentinelTheme.sidebarBackground(for: colorScheme))
            .navigationTitle("MacAdBlock")
            .navigationSplitViewColumnWidth(min: 184, ideal: 198, max: 224)
        } detail: {
            ZStack {
                SentinelTheme.background(for: colorScheme).ignoresSafeArea()
                Group {
                    switch selection ?? .dashboard {
                    case .dashboard: OverviewView()
                    case .sources: FilterSourcesView()
                    case .hosts: HostsView()
                    case .firewall: FirewallView(firewall: model.firewall)
                    case .vpn: VPNDashboardView()
                    case .statistics: StatisticsView()
                    }
                }
                .environmentObject(model)
            }
        }
        .tint(SentinelTheme.accent)
        .toolbar {
            VersionToolbarItem(model: model)
        }
        .alert("MacAdBlock", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
        .sheet(item: $model.applicationNotice) { notice in
            ApplicationNoticeView(notice: notice)
                .environmentObject(model)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshSafariStatus()
        }
    }
}

/// Element paska narzędzi bez systemowej „szklanej” otoczki (macOS 26 rysuje ją pod każdym elementem,
/// przez co wokół naszej plakietki powstawała druga, biała kapsuła).
private struct VersionToolbarItem: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .automatic) {
                VersionPill().environmentObject(model)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .automatic) {
                VersionPill().environmentObject(model)
            }
        }
    }
}

/// Plakietka wersji w pasku narzędzi. Kliknięcie otwiera panel aktualizatora: stan, sprawdzenie i instalacja.
private struct VersionPill: View {
    @EnvironmentObject private var model: AppModel
    @State private var showPopover = false

    private var updateReady: Bool {
        guard let notice = model.availableUpdate else { return false }
        if case .openInstalled = notice.kind { return false }
        return true
    }

    var body: some View {
        Button { showPopover.toggle() } label: {
            HStack(spacing: 5) {
                if model.isCheckingApplicationUpdate {
                    ProgressView().controlSize(.mini)
                } else if updateReady {
                    Image(systemName: "arrow.down.circle.fill")
                }
                Text(labelText)
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
            }
            .foregroundStyle(updateReady ? Color.white : SentinelTheme.accent)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 72, minHeight: 16)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(Color(nsColor: .windowBackgroundColor))
                Capsule().fill(updateReady ? SentinelTheme.accent : SentinelTheme.accent.opacity(0.14))
            }
            .overlay { Capsule().stroke(SentinelTheme.accent.opacity(updateReady ? 0 : 0.28), lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L("Wersja MacAdBlock i aktualizacje"))
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VersionPopover(close: { showPopover = false }).environmentObject(model)
        }
    }

    private var labelText: String {
        if model.isCheckingApplicationUpdate { return L("Sprawdzanie…") }
        if updateReady { return L("Aktualizuj") }
        return model.displayedApplicationVersion
    }
}

private struct VersionPopover: View {
    @EnvironmentObject private var model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image("MacAdBlockShield").resizable().scaledToFit().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacAdBlock").font(.headline)
                    Text(model.displayedApplicationVersion)
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 8) {
                if model.isCheckingApplicationUpdate {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: statusIcon).foregroundStyle(statusColor)
                }
                Text(statusText).font(.callout).fixedSize(horizontal: false, vertical: true)
            }

            if let notice = model.availableUpdate {
                Text(notice.message)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    close()
                    model.performApplicationNoticeAction(notice)
                } label: {
                    Text(notice.actionTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(SentinelTheme.accent)
                .disabled(model.isCheckingApplicationUpdate)
            }

            Button {
                Task { await model.checkApplicationInstallationAndUpdates(force: true) }
            } label: {
                Text(L("Sprawdź aktualizacje")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.isCheckingApplicationUpdate)
        }
        .padding(18)
        .frame(width: 300)
    }

    private var statusText: String {
        model.isCheckingApplicationUpdate ? L("Sprawdzanie aktualizacji…") : model.applicationUpdateStatus
    }

    private var statusIcon: String {
        model.availableUpdate == nil ? "checkmark.circle.fill" : "arrow.down.circle.fill"
    }

    private var statusColor: Color {
        model.availableUpdate == nil ? SentinelTheme.accent : .orange
    }
}

private struct ApplicationNoticeView: View {
    @EnvironmentObject private var model: AppModel
    let notice: ApplicationNotice

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(SentinelTheme.accent.opacity(0.12))
                Image("MacAdBlockShield")
                    .resizable()
                    .scaledToFit()
                    .padding(7)
            }
            .frame(width: 72, height: 72)

            VStack(spacing: 8) {
                Text(notice.title).font(.title2.bold())
                Text(notice.message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 390)
            }

            HStack {
                Button(L("Później")) { model.applicationNotice = nil }
                    .buttonStyle(.bordered)
                Button(notice.actionTitle) { model.performApplicationNoticeAction() }
                    .buttonStyle(.borderedProminent)
                    .tint(SentinelTheme.accent)
            }
        }
        .padding(32)
        .frame(width: 470)
        .presentationBackground(.ultraThinMaterial)
    }
}

private enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard, sources, hosts, firewall, vpn, statistics
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: L("Ochrona")
        case .sources: L("Filtry")
        case .hosts: L("Ochrona systemowa")
        case .firewall: L("Firewall")
        case .vpn: "VPN"
        case .statistics: L("Aktywność")
        }
    }
    var icon: String {
        switch self {
        case .dashboard: "shield.lefthalf.filled"
        case .sources: "line.3.horizontal.decrease.circle"
        case .hosts: "network.badge.shield.half.filled"
        case .firewall: "flame.fill"
        case .vpn: "lock.shield.fill"
        case .statistics: "waveform.path.ecg"
        }
    }

    @MainActor func badge(_ model: AppModel) -> String? {
        switch self {
        case .dashboard: nil
        case .sources: "\(model.enabledSourceIDs.count)"
        case .hosts: model.hostsEnabled ? "ON" : nil
        case .firewall: model.firewall.config.enabled ? "ON" : nil
        case .vpn: nil
        case .statistics: model.statistics.lastUpdated == nil ? nil : "LIVE"
        }
    }
}

private struct VPNDashboardView: View {
    @StateObject private var vpn = VPNController()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            SentinelTheme.background(for: colorScheme).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Prywatny tunel"))
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                        Text(L("Systemowy VPN IKEv2 z bezpiecznym przechowywaniem danych"))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 24) {
                        ZStack {
                            Circle().fill(vpn.isConnected ? SentinelTheme.accent.opacity(0.14) : Color.secondary.opacity(0.08))
                            Circle().stroke(vpn.isConnected ? SentinelTheme.accent.opacity(0.34) : Color.secondary.opacity(0.16), lineWidth: 8)
                            Image(systemName: vpn.isConnected ? "lock.shield.fill" : "lock.shield")
                                .font(.system(size: 42, weight: .semibold))
                                .foregroundStyle(vpn.isConnected ? SentinelTheme.accent : .secondary)
                        }
                        .frame(width: 128, height: 128)

                        VStack(alignment: .leading, spacing: 7) {
                            Text(vpn.status)
                                .font(.system(size: 23, weight: .bold, design: .rounded))
                            Text(vpn.isConfigured ? vpn.serverAddress : L("Najpierw skonfiguruj serwer i konto"))
                                .foregroundStyle(.secondary)
                            if let connectedSince = vpn.connectedSince {
                                HStack(spacing: 4) {
                                    Text(L("Czas połączenia"))
                                    Text(connectedSince, style: .timer).monospacedDigit()
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 9) {
                                if vpn.isConnected {
                                    Button(L("Rozłącz"), systemImage: "stop.fill") { vpn.disconnect() }
                                        .buttonStyle(.borderedProminent)
                                } else {
                                    Button(L("Połącz"), systemImage: "play.fill") { Task { await vpn.connect() } }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(!vpn.isConfigured || vpn.isBusy)
                                }
                                SettingsLink {
                                    Label(vpn.isConfigured ? L("Ustawienia VPN") : L("Skonfiguruj VPN"), systemImage: "gearshape")
                                }
                                .buttonStyle(.bordered)
                            }
                            .tint(SentinelTheme.accent)
                        }
                        Spacer()
                    }
                    .padding(22)
                    .glassCard()

                    HStack(spacing: 10) {
                        VPNFeatureCard(title: L("Protokół"), value: "IKEv2", icon: "lock.fill", active: vpn.isConfigured)
                        VPNFeatureCard(title: L("Operator"), value: vpn.provider.title, icon: "server.rack", active: vpn.isConfigured)
                        VPNFeatureCard(title: L("Autołączenie"), value: vpn.onDemandPolicy.title, icon: "bolt.horizontal.fill", active: vpn.connectOnDemand)
                        VPNFeatureCard(title: L("Trasa"), value: vpn.fullTunnel ? L("Pełny tunel") : L("Serwer"), icon: "arrow.triangle.branch", active: vpn.fullTunnel)
                    }

                    if let reason = vpn.errorMessage ?? vpn.lastDisconnectReason {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(reason).font(.callout)
                            Spacer()
                        }
                        .padding(14)
                        .glassCard()
                    }

                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: "checkmark.shield.fill").foregroundStyle(SentinelTheme.accent)
                        Text(L("MacAdBlock używa klienta VPN wbudowanego w macOS. Pełne działanie wymaga podpisanej aplikacji z capability Personal VPN oraz profilu zatwierdzonego przez użytkownika."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(16)
                    .glassCard()
                }
                .padding(20)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
            }
        }
        .task { await vpn.load() }
    }
}

private struct VPNFeatureCard: View {
    let title: String
    let value: String
    let icon: String
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: icon).foregroundStyle(active ? SentinelTheme.accent : .secondary)
                Spacer()
                Circle().fill(active ? SentinelTheme.accent : Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
            }
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .glassCard()
    }
}

private struct SidebarProtectionToggle: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image("MacAdBlockShield").resizable().scaledToFit().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Ochrona")).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                Text(model.protectionEnabled ? L("Włączona") : L("Wyłączona"))
                    .font(.caption).foregroundStyle(model.protectionEnabled ? SentinelTheme.accent : .secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { model.protectionEnabled },
                set: { model.setProtectionEnabled($0) }
            ))
            .labelsHidden()
            .tint(SentinelTheme.accent)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(SentinelTheme.accent.opacity(0.16)) }
    }
}

private struct SidebarStatusView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Image("MacAdBlockShield")
                    .resizable()
                    .scaledToFit()
                if model.isUpdating {
                    Circle().fill(.black.opacity(0.48))
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(SentinelTheme.accent)
                }
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.isUpdating ? "Aktualizowanie" : L("Ochrona gotowa"))
                    .font(.caption.weight(.semibold))
                Text(L("\(model.enabledSourceIDs.count) aktywnych źródeł"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    private var chartValues: [(String, Int)] {
        [
            (L("Sieciowe"), model.statistics.networkRuleCount),
            (L("Kosmetyczne"), model.statistics.cosmeticRuleCount),
            (L("Domeny"), model.statistics.hostDomainCount)
        ]
    }

    var body: some View {
        ZStack {
            SentinelTheme.background(for: colorScheme).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    HeaderView().environmentObject(model)

                    ProtectionHeroView()
                        .environmentObject(model)

                    QuickActionsCard()
                        .environmentObject(model)

                    ProtectionLayersView()
                        .environmentObject(model)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        ProtectionModule(
                            title: "Safari",
                            subtitle: L("Reklamy i trackery"),
                            value: model.statistics.contentBlockerRuleCount,
                            unit: L("reguł"),
                            icon: "safari",
                                active: model.safariProtectionEnabled == true
                        )
                        ProtectionModule(
                            title: "System",
                            subtitle: L("Sekcja hosts"),
                            value: model.statistics.hostDomainCount,
                            unit: L("domen"),
                            icon: "desktopcomputer",
                            active: model.hostsEnabled
                        )
                        ProtectionModule(
                            title: L("Rozszerzenie"),
                            subtitle: L("Reguły zaawansowane"),
                            value: model.statistics.webExtensionRuleCount,
                            unit: L("reguł"),
                            icon: "puzzlepiece.extension.fill",
                            active: model.webExtensionEnabled == true
                        )
                    }

                    ActivityCard(values: chartValues)
                        .environmentObject(model)
                }
                .padding(20)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct HeaderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Centrum ochrony"))
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text(L("Safari i system zabezpieczone w jednym miejscu"))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.updateFilters()
            } label: {
                Label(model.isUpdating ? "Aktualizowanie…" : L("Aktualizuj ochronę"), systemImage: "arrow.clockwise")
                    .frame(minWidth: 138)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isUpdating || model.enabledSourceIDs.isEmpty)
        }
    }
}

private struct ProtectionHeroView: View {
    @EnvironmentObject private var model: AppModel

    private var ruleCount: Int {
        model.statistics.contentBlockerRuleCount + model.statistics.webExtensionRuleCount
    }

    var body: some View {
        HStack(spacing: 22) {
            ZStack {
                // Płaski pierścień: cieńsza kreska, jednolity kolor, bez poświaty i bez otoczki.
                Circle()
                    .stroke(Color.primary.opacity(0.10), lineWidth: 5)
                    .frame(width: 104, height: 104)
                Circle()
                    .trim(from: 0, to: model.isUpdating ? 0.72 : 0.94)
                    .stroke(SentinelTheme.control, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 104, height: 104)
                if model.isUpdating {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 34, weight: .medium))
                        .symbolEffect(.pulse, isActive: true)
                        .foregroundStyle(SentinelTheme.control)
                } else {
                    Image("MacAdBlockShield")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(protectionTitle)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(model.statusMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                if model.isUpdating {
                    ProgressView(value: model.updateProgress)
                        .progressViewStyle(.linear)
                        .tint(SentinelTheme.control)
                        .frame(maxWidth: 260)
                }
                HStack(spacing: 20) {
                    HeroMetric(value: ruleCount, label: L("reguł"))
                    Divider().frame(height: 30)
                    HeroMetric(value: model.enabledSourceIDs.count, label: L("źródeł"))
                    Divider().frame(height: 30)
                    HeroMetric(value: model.statistics.cacheHits, label: L("z cache"))
                }
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 10) {
                if let date = model.statistics.lastUpdated {
                    Label {
                        HStack(spacing: 4) {
                            Text(L("Aktualizacja"))
                            Text(date, style: .relative)
                        }
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Label(L("Wymaga aktualizacji"), systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.safariProtectionEnabled == false {
                    Button(L("Włącz Safari")) { model.openSafariExtensionSettings() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(18)
        .glassCard()
        .onAppear { model.refreshSafariStatus() }
    }

    private var protectionTitle: String {
        if model.isUpdating { return L("Wzmacniamy ochronę") }
        switch model.safariProtectionEnabled {
        case true: return L("Jesteś chroniony")
        case false: return L("Włącz ochronę w Safari")
        case nil: return L("Sprawdzanie ochrony")
        }
    }
}

private struct QuickActionsCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(nextTitle).font(.headline)
                Text(nextSubtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(actionTitle, systemImage: actionIcon, action: performPrimaryAction)
                .buttonStyle(.borderedProminent)
                .tint(SentinelTheme.accent)
                .disabled(model.isUpdating)
            Menu {
                Button(L("Wybierz listy"), systemImage: "line.3.horizontal.decrease.circle") { model.showOnboarding = true }
                Button(L("Ustawienia Safari"), systemImage: "safari") { model.openSafariExtensionSettings() }
                Button(L("Skonfiguruj hosts"), systemImage: "network.badge.shield.half.filled") { model.prepareHostsHelper(openApprovalSettings: true) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
        }
        .padding(14)
        .glassCard()
    }

    private var nextTitle: String {
        if model.enabledSourceIDs.isEmpty { return L("Wybierz źródła ochrony") }
        if model.safariProtectionEnabled == false { return L("Dokończ konfigurację Safari") }
        if model.statistics.lastUpdated == nil { return L("Pobierz pierwsze listy") }
        return model.isUpdating ? L("Aktualizujemy ochronę") : L("Ochrona jest gotowa")
    }

    private var nextSubtitle: String {
        if model.enabledSourceIDs.isEmpty { return L("Kreator dobierze bezpieczny zestaw filtrów.") }
        if model.safariProtectionEnabled == false { return L("MacAdBlock otworzy ustawienia; zaznacz oba rozszerzenia.") }
        if model.statistics.lastUpdated == nil { return L("Jedno kliknięcie pobierze i skompiluje reguły.") }
        return L("Możesz zaktualizować listy albo zmienić zakres ochrony.")
    }

    private var actionTitle: String {
        if model.enabledSourceIDs.isEmpty { return L("Otwórz kreator") }
        if model.safariProtectionEnabled == false { return L("Włącz w Safari") }
        return model.isUpdating ? "Aktualizowanie…" : L("Aktualizuj")
    }

    private var actionIcon: String {
        if model.enabledSourceIDs.isEmpty { return "wand.and.stars" }
        if model.safariProtectionEnabled == false { return "safari" }
        return "arrow.clockwise"
    }

    private func performPrimaryAction() {
        if model.enabledSourceIDs.isEmpty { model.showOnboarding = true }
        else if model.safariProtectionEnabled == false { model.openSafariExtensionSettings() }
        else { model.updateFilters() }
    }
}

private struct ProtectionLayersView: View {
    @EnvironmentObject private var model: AppModel

    private var layers: [ProtectionLayer] {
        [
            ProtectionLayer(title: L("Sieć"), subtitle: L("Żądania i zasoby"), icon: "point.3.connected.trianglepath.dotted", active: model.statistics.networkRuleCount > 0),
            ProtectionLayer(title: L("Trackery"), subtitle: L("Prywatność"), icon: "eye.slash.fill", active: model.statistics.networkRuleCount > 0),
            ProtectionLayer(title: L("Elementy"), subtitle: L("Puste pola i banery"), icon: "rectangle.slash", active: model.statistics.cosmeticRuleCount > 0),
            ProtectionLayer(title: L("Adresy URL"), subtitle: L("Parametry śledzące"), icon: "link.badge.plus", active: model.statistics.webExtensionRuleCount > 0),
            ProtectionLayer(title: "System", subtitle: L("Hosts i DNS"), icon: "network.badge.shield.half.filled", active: model.hostsEnabled)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Warstwy ochrony")).font(.headline)
                    Text(L("Każda warstwa zatrzymuje inny rodzaj reklamy i śledzenia"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(layers.filter(\.active).count)/\(layers.count)")
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(SentinelTheme.accent)
            }

            HStack(spacing: 8) {
                ForEach(layers) { layer in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: layer.icon)
                                .foregroundStyle(layer.active ? SentinelTheme.accent : .secondary)
                            Spacer()
                            Circle()
                                .fill(layer.active ? SentinelTheme.accent : Color.secondary.opacity(0.35))
                                .frame(width: 6, height: 6)
                        }
                        Text(layer.title)
                            .font(.caption.weight(.semibold))
                        Text(layer.subtitle)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(SentinelTheme.accent.opacity(layer.active ? 0.22 : 0.08)) }
                }
            }
        }
        .padding(14)
        .glassCard()
    }
}

private struct ProtectionLayer: Identifiable {
    let title: String
    let subtitle: String
    let icon: String
    let active: Bool
    var id: String { title }
}

private struct HeroMetric: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(spacing: 1) {
            Text(value.formatted())
                .font(.title3.bold())
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ProtectionModule: View {
    let title: String
    let subtitle: String
    let value: Int
    let unit: String
    let icon: String
    let active: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(active ? SentinelTheme.accent.opacity(0.14) : Color.secondary.opacity(0.1))
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(active ? SentinelTheme.accent : .secondary)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.headline).lineLimit(1).minimumScaleFactor(0.75)
                    Circle()
                        .fill(active ? SentinelTheme.accent : Color.secondary.opacity(0.45))
                        .frame(width: 6, height: 6)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(value.formatted())
                    .font(.headline.monospacedDigit())
                    .contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(unit).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(1)
        }
        .padding(12)
        .glassCard()
    }
}

private struct ActivityCard: View {
    @EnvironmentObject private var model: AppModel
    let values: [(String, Int)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Aktywność filtrów")).font(.headline)
                    Text(L("Aktualnie skompilowane zasoby ochrony"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(L("Cache: \(model.statistics.cacheHits)"), systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Chart(values, id: \.0) { item in
                BarMark(x: .value("Typ", item.0), y: .value(L("Liczba"), item.1))
                    .foregroundStyle(SentinelTheme.ring)
                    .cornerRadius(5)
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 110)
        }
        .padding(16)
        .glassCard()
    }
}

enum SentinelTheme {
    static let accent = Color(red: 0.31, green: 0.88, blue: 0.66)
    /// Zieleń elementów sterujących: przyciski, przełączniki i ikony list. Jedno źródło dla całej
    /// aplikacji — wcześniej ta sama wartość była wpisana osobno w sześciu plikach widoków.
    static let control = Color(red: 0.12, green: 0.72, blue: 0.44)
    static let deepAccent = Color(red: 0.04, green: 0.50, blue: 0.36)
    static let sidebarSelectedIcon = Color(red: 0.83, green: 1.0, blue: 0.93)
    static let sidebarSelectedText = Color.white
    static let ring = LinearGradient(
        colors: [Color(red: 0.36, green: 0.96, blue: 0.75), Color(red: 0.04, green: 0.55, blue: 0.40)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static func sidebarSelection(for scheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.12, green: 0.72, blue: 0.44).opacity(0.30), Color(red: 0.12, green: 0.72, blue: 0.44).opacity(0.24)]
                : [Color(red: 0.12, green: 0.72, blue: 0.44).opacity(0.18), Color(red: 0.12, green: 0.72, blue: 0.44).opacity(0.14)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
    /// Tła są celowo neutralne i niemal płaskie. Kolorowy gradient rywalizował z treścią;
    /// akcent pojawia się teraz tylko tam, gdzie oznacza stan ochrony.
    static func background(for scheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.063, green: 0.067, blue: 0.066), Color(red: 0.047, green: 0.051, blue: 0.050)]
                : [Color(red: 0.965, green: 0.965, blue: 0.970), Color(red: 0.945, green: 0.945, blue: 0.953)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static func sidebarBackground(for scheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.043, green: 0.047, blue: 0.046), Color(red: 0.043, green: 0.047, blue: 0.046)]
                : [Color(red: 0.925, green: 0.925, blue: 0.933), Color(red: 0.925, green: 0.925, blue: 0.933)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static func menuBackground(for scheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.086, green: 0.090, blue: 0.090), Color(red: 0.086, green: 0.090, blue: 0.090)]
                : [Color(red: 0.98, green: 0.98, blue: 0.985), Color(red: 0.98, green: 0.98, blue: 0.985)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

extension View {
    func glassCard() -> some View {
        modifier(GlassCardModifier())
    }
}

struct GlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        // Minimalistyczna karta: jednolita powierzchnia i włoskowa kreska, bez materiału,
        // kolorowej obwódki i poświaty. Zieleń zostaje dla stanu, nie dla dekoracji.
        content
            .background(
                colorScheme == .dark ? Color(white: 0.105) : Color.white,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.08), lineWidth: 1)
            }
    }
}
