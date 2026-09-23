import AppKit
import NetworkExtension
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var loginManager = LaunchAtLoginManager()
    @StateObject private var dnsManager = DNSProxyController()
    @StateObject private var encryptedDNS = EncryptedDNSController()
    @StateObject private var vpnManager = VPNController()
    @State private var selection: SettingsSection = .general
    @State private var vpnPassword = ""
    @State private var showResetConfirmation = false
    @AppStorage("dnsProvider") private var dnsProvider = "Systemowy"

    var body: some View {
        VStack(spacing: 0) {
            settingsToolbar
            Divider().overlay(Color.primary.opacity(0.12))
            ScrollView {
                Group {
                    switch selection {
                    case .general: generalView
                    case .filters: filtersView
                    case .dns: dnsView
                    case .vpn: vpnView
                    case .privacy: privacyView
                    case .security: securityView
                    case .safari: safariView
                    case .network: networkView
                    case .advanced: advancedView
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(settingsBackground)
        .task { model.refreshSafariStatus(); await dnsManager.refresh(); await vpnManager.load() }
    }

    private var settingsToolbar: some View {
        HStack(spacing: 8) {
            ForEach(SettingsSection.allCases) { section in
                Button { selection = section } label: {
                    VStack(spacing: 5) {
                        Image(systemName: section.icon).font(.system(size: 21, weight: .semibold))
                        Text(section.title).font(.caption2).lineLimit(1)
                    }
                    .foregroundStyle(selection == section ? SentinelTheme.control : Color.primary.opacity(0.55))
                    .frame(width: 88, height: 58)
                    .background(Color.primary.opacity(selection == section ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var generalView: some View {
        SettingsPage(title: L("Ogólne"), subtitle: L("Podstawowe zachowanie MacAdBlock")) {
            Picker(L("Wygląd"), selection: Binding(get: { model.appearance }, set: { model.setAppearance($0) })) {
                ForEach(AppAppearance.allCases) { appearance in
                    Label(appearance.title, systemImage: appearance.icon).tag(appearance)
                }
            }
            .pickerStyle(.segmented)
            .tint(SentinelTheme.control)
            settingsToggle(L("Uruchamiaj po zalogowaniu"), L("MacAdBlock uruchomi ochronę razem z systemem."), Binding(get: { loginManager.isEnabled }, set: { loginManager.setEnabled($0) }))
            settingsToggle(L("Automatycznie stosuj listy hosts"), L("Po aktualizacji helper bezpiecznie odświeży zarządzaną sekcję /etc/hosts."), $model.automaticallyApplyHosts)
            Picker(L("Automatyczne aktualizacje"), selection: Binding(get: { model.autoUpdateIntervalHours }, set: { model.setAutoUpdateInterval(hours: $0) })) {
                Text(L("Wyłączone")).tag(0)
                Text(L("Co 6 godzin")).tag(6)
                Text(L("Co 12 godzin")).tag(12)
                Text(L("Codziennie")).tag(24)
                Text(L("Co tydzień")).tag(168)
            }
            .pickerStyle(.segmented)
            .tint(SentinelTheme.control)
            scheduleSection
            actionRow("Uruchom kreator konfiguracji", "Ponownie wybierz profil, kraje i kategorie.", icon: "wand.and.stars") { model.showOnboarding = true }
            destructiveActionRow(L("Przywróć ustawienia fabryczne"), L("Usuwa własne listy, wyjątki i wybory kategorii, po czym ponownie otwiera kreator konfiguracji."), icon: "arrow.counterclockwise.circle") { showResetConfirmation = true }
            if let error = loginManager.errorMessage { Text(error).foregroundStyle(.red).font(.caption) }
        }
        .confirmationDialog(
            L("Przywrócić ustawienia fabryczne?"),
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(L("Przywróć ustawienia fabryczne"), role: .destructive) { model.resetToFactoryDefaults() }
            Button(L("Anuluj"), role: .cancel) {}
        } message: {
            Text(L("Własne listy, wyjątki i reguły zostaną usunięte, a wybór list wróci do domyślnego zestawu. Tej operacji nie można cofnąć."))
        }
    }

    /// Ciche godziny: wybór przedziału i dni tygodnia, w które ochrona sama się wstrzymuje i wznawia.
    /// Loguje logikę w AppModel.evaluateProtectionWindowStart(); tu tylko UI i dwie konwersje Date<->minuty.
    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsToggle(
                L("Harmonogram ochrony (ciche godziny)"),
                L("Automatycznie wstrzymuje ochronę w wybranych godzinach i dniach — np. na noc — i sama ją wznawia."),
                Binding(get: { model.scheduleEnabled }, set: { model.setScheduleEnabled($0) })
            )
            if model.scheduleEnabled {
                HStack(spacing: 20) {
                    DatePicker(L("Od"), selection: scheduleStartBinding, displayedComponents: .hourAndMinute)
                    DatePicker(L("Do"), selection: scheduleEndBinding, displayedComponents: .hourAndMinute)
                    Spacer()
                }
                HStack(spacing: 6) {
                    ForEach(Self.weekdayOrder, id: \.self) { weekday in
                        Button(Self.weekdayShortLabel(weekday)) { model.toggleScheduleWeekday(weekday) }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(
                                model.scheduleWeekdays.contains(weekday) ? SentinelTheme.control : Color.primary.opacity(0.08),
                                in: Capsule()
                            )
                            .foregroundStyle(model.scheduleWeekdays.contains(weekday) ? Color.white : Color.primary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var scheduleStartBinding: Binding<Date> {
        Binding(
            get: { AppModel.time(fromMinutes: model.scheduleStartMinutes) },
            set: { model.setScheduleWindow(startMinutes: AppModel.minutes(from: $0), endMinutes: model.scheduleEndMinutes) }
        )
    }

    private var scheduleEndBinding: Binding<Date> {
        Binding(
            get: { AppModel.time(fromMinutes: model.scheduleEndMinutes) },
            set: { model.setScheduleWindow(startMinutes: model.scheduleStartMinutes, endMinutes: AppModel.minutes(from: $0)) }
        )
    }

    /// Poniedziałek → niedziela w interfejsie, mimo że `Calendar.weekday` liczy od niedzieli (1).
    private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    private static func weekdayShortLabel(_ weekday: Int) -> String {
        switch weekday {
        case 1: L("Nd")
        case 2: L("Pn")
        case 3: L("Wt")
        case 4: L("Śr")
        case 5: L("Cz")
        case 6: L("Pt")
        case 7: L("So")
        default: "?"
        }
    }

    private var filtersView: some View {
        SettingsPage(title: L("Filtry"), subtitle: L("Kategorie list reklam i elementów stron")) {
            categoryToggle(.ads, L("Podstawowe blokowanie reklam"))
            categoryToggle(.privacy, L("Trackery i analityka"))
            categoryToggle(.annoyances, L("Popupy, cookies i irytujące elementy"))
            categoryToggle(.social, L("Widżety mediów społecznościowych"))
            actionRow(L("Aktualizuj wszystkie aktywne listy"), L("Pobierz najnowsze wersje i przeładuj Safari."), icon: "arrow.clockwise") { model.updateFilters() }
        }
    }

    private var dnsView: some View {
        SettingsPage(title: "DNS", subtitle: L("Opcjonalny moduł Network Extension")) {
            Picker(L("Preferowany dostawca"), selection: $dnsProvider) {
                Text(L("Systemowy")).tag("Systemowy")
                Text(L("Cloudflare 1.1.1.1")).tag("Cloudflare")
                Text("Quad9").tag("Quad9")
                Text(L("AdGuard DNS")).tag("AdGuard DNS")
            }
            .pickerStyle(.segmented)
            .tint(SentinelTheme.control)
            settingsToggle(L("Włącz filtrowanie DNS"), L("Blokuje domeny z aktywnych list dla wszystkich aplikacji."), Binding(
                get: { dnsManager.isEnabled },
                set: { enabled in Task { await dnsManager.setEnabled(enabled, provider: dnsProvider) } }
            ))
            .disabled(dnsProvider == "Systemowy")
            statusRow(L("Stan DNS Proxy"), dnsManager.status, active: dnsManager.isEnabled)
            settingsToggle(L("Szyfruj DNS (DNS-over-HTTPS)"), L("Zapytania DNS całego systemu idą szyfrowanym kanałem do wybranego dostawcy, więc sieć ani dostawca internetu ich nie podejrzy."), Binding(
                get: { encryptedDNS.isEnabled },
                set: { enabled in Task { await encryptedDNS.setEnabled(enabled, provider: dnsProvider) } }
            ))
            .disabled(dnsProvider == "Systemowy")
            statusRow(L("Stan szyfrowanego DNS"), encryptedDNS.status, active: encryptedDNS.isEnabled)
            infoCard(L("DoH działa niezależnie od filtrowania DNS powyżej. AdGuard DNS dodatkowo blokuje reklamy po stronie serwera. Szyfrowany DNS wymaga podpisanej aplikacji z uprawnieniem Network Extensions (DNS Settings)."), icon: "lock.icloud")
            infoCard("DNS Proxy wymaga podpisanego targetu DNSProxy i capability Network Extensions. Wybrany dostawca otrzymuje zapytania DNS; ustawienie Systemowy pozostawia DNS bez zmian.", icon: "network.badge.shield.half.filled")
        }
    }

    private var privacyView: some View {
        SettingsPage(title: L("Prywatność"), subtitle: L("Ogranicz śledzenie i elementy profilujące")) {
            categoryToggle(.privacy, L("Ochrona przed śledzeniem"))
            categoryToggle(.social, L("Blokowanie widżetów społecznościowych"))
            categoryToggle(.annoyances, L("Usuwanie komunikatów i nakładek"))
        }
    }

    private var vpnView: some View {
        SettingsPage(title: "VPN", subtitle: L("Prywatny tunel IKEv2 obsługiwany bezpośrednio przez macOS")) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(vpnManager.isConnected ? SentinelTheme.accent.opacity(0.18) : Color.secondary.opacity(0.1))
                    Image(systemName: vpnManager.isConnected ? "lock.shield.fill" : "lock.shield")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(vpnManager.isConnected ? SentinelTheme.accent : .secondary)
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 3) {
                    Text(vpnManager.status)
                        .font(.title3.bold())
                    if let connectedSince = vpnManager.connectedSince {
                        HStack(spacing: 4) {
                            Text(L("Połączono przez"))
                            Text(connectedSince, style: .timer).monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text(vpnManager.isConfigured ? vpnManager.serverAddress : L("Skonfiguruj operatora i serwer"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()

                if vpnManager.isConnected {
                    Button(L("Rozłącz")) { vpnManager.disconnect() }
                        .buttonStyle(.bordered)
                        .disabled(vpnManager.isBusy)
                } else {
                    Button(L("Połącz")) { Task { await vpnManager.connect() } }
                        .buttonStyle(.borderedProminent)
                        .tint(SentinelTheme.accent)
                        .disabled(!vpnManager.isConfigured || vpnManager.isBusy)
                }
            }
            .padding(16)
            .glassCard()

            VStack(alignment: .leading, spacing: 14) {
                Label(L("Serwer i konto"), systemImage: "server.rack")
                    .font(.headline)
                    .foregroundStyle(SentinelTheme.accent)

                Picker(L("Operator"), selection: Binding(
                    get: { vpnManager.provider },
                    set: { vpnManager.selectProvider($0) }
                )) {
                    ForEach(VPNProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .tint(SentinelTheme.accent)

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "info.circle.fill").foregroundStyle(SentinelTheme.accent)
                    Text(vpnManager.provider.guidance).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if let setupURL = vpnManager.provider.setupURL {
                        Button(L("Instrukcja")) { NSWorkspace.shared.open(setupURL) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(12)
                .background(SentinelTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    if vpnManager.provider != .custom {
                        GridRow {
                            Text(L("Lokalizacja")).foregroundStyle(.secondary)
                            Picker(L("Lokalizacja"), selection: Binding(
                                get: { vpnManager.selectedServerID },
                                set: { vpnManager.selectServer($0) }
                            )) {
                                ForEach(vpnManager.availableServers) { server in
                                    Text("\(server.title) · \(server.access)").tag(server.id)
                                }
                                Divider()
                                Text(L("Inny serwer z konta…")).tag(VPNController.manualServerID)
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    GridRow {
                        Text(L("Serwer")).foregroundStyle(.secondary)
                        if vpnManager.usesManualServerAddress {
                            TextField(vpnManager.provider.serverPlaceholder, text: $vpnManager.serverAddress)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: vpnManager.serverAddress) { _, _ in vpnManager.serverAddressDidChange() }
                        } else {
                            HStack {
                                Text(vpnManager.serverAddress)
                                    .font(.body.monospaced())
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(SentinelTheme.accent)
                            }
                            .padding(.horizontal, 10)
                            .frame(minHeight: 30)
                            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    GridRow {
                        Text(L("Remote ID")).foregroundStyle(.secondary)
                        TextField(L("Identyfikator certyfikatu serwera"), text: $vpnManager.remoteIdentifier)
                            .textFieldStyle(.roundedBorder)
                            .disabled(vpnManager.isRemoteIdentifierManaged)
                    }
                    GridRow {
                        Text(L("Użytkownik")).foregroundStyle(.secondary)
                        TextField(L("Nazwa użytkownika IKEv2"), text: $vpnManager.username)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text(L("Hasło")).foregroundStyle(.secondary)
                        SecureField(vpnManager.isConfigured ? L("Pozostaw puste, aby zachować") : L("Hasło IKEv2"), text: $vpnPassword)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                if vpnManager.provider != .custom {
                    Label(L("Adres serwera i Remote ID są uzupełniane automatycznie. Login i hasło operatora podajesz raz — hasło zostaje w Pęku kluczy."), systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .glassCard()

            VStack(alignment: .leading, spacing: 14) {
                Label(L("Automatyczne łączenie"), systemImage: "bolt.horizontal.circle.fill")
                    .font(.headline)
                    .foregroundStyle(SentinelTheme.accent)

                Picker(L("Uruchamiaj VPN"), selection: $vpnManager.onDemandPolicy) {
                    ForEach(VPNOnDemandPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .pickerStyle(.segmented)
                .tint(SentinelTheme.accent)

                if vpnManager.onDemandPolicy == .untrustedWiFi {
                    TextField(L("Zaufane sieci Wi‑Fi, oddzielone przecinkami"), text: $vpnManager.trustedWiFiSSIDs)
                        .textFieldStyle(.roundedBorder)
                    Text(L("Na pozostałych sieciach Wi‑Fi oraz Ethernet VPN połączy się automatycznie. Rozpoznano \(vpnManager.trustedNetworkCount) zaufanych sieci."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .glassCard()

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L("Profil kryptograficzny"), selection: $vpnManager.securityProfile) {
                        ForEach(VPNSecurityProfile.allCases) { profile in
                            Text(profile.title).tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(SentinelTheme.accent)
                    .disabled(vpnManager.provider != .custom)

                    Text(vpnManager.securityProfile.details)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    settingsToggle(L("Pełny tunel"), L("Wymusza prowadzenie całego ruchu internetowego przez VPN."), $vpnManager.fullTunnel)
                    settingsToggle(L("Dostęp do sieci lokalnej"), L("Pozwala nadal korzystać z drukarek, NAS i innych urządzeń LAN."), $vpnManager.allowLocalNetworks)
                        .disabled(!vpnManager.fullTunnel)
                    settingsToggle(L("Nie rozłączaj podczas uśpienia"), L("Po wybudzeniu macOS spróbuje utrzymać lub odtworzyć bezpieczny tunel."), Binding(
                        get: { !vpnManager.disconnectOnSleep },
                        set: { vpnManager.disconnectOnSleep = !$0 }
                    ))
                    settingsToggle(L("Blokuj przekierowanie serwera"), L("Nie pozwala serwerowi IKEv2 przenieść połączenia na inny adres."), $vpnManager.preventServerRedirects)
                }
                .padding(.top, 12)
            } label: {
                Label(L("Bezpieczeństwo i trasy"), systemImage: "checkmark.shield.fill")
                    .font(.headline)
                    .foregroundStyle(SentinelTheme.accent)
            }
            .padding(16)
            .glassCard()

            HStack {
                Button(L("Zapisz profil")) {
                    Task {
                        await vpnManager.save(password: vpnPassword)
                        if vpnManager.errorMessage == nil { vpnPassword = "" }
                    }
                }
                .buttonStyle(.bordered)

                Button(L("Zapisz i połącz")) {
                    Task {
                        await vpnManager.saveAndConnect(password: vpnPassword)
                        if vpnManager.errorMessage == nil { vpnPassword = "" }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(vpnManager.isBusy)

                Spacer()

                Button(L("Usuń profil"), role: .destructive) { Task { await vpnManager.remove() } }
                    .buttonStyle(.bordered)
                    .disabled(!vpnManager.isConfigured || vpnManager.isBusy)
            }
            .tint(SentinelTheme.accent)

            if let error = vpnManager.errorMessage {
                VPNMessageCard(title: L("Nie udało się wykonać operacji"), message: error, icon: "exclamationmark.triangle.fill", color: .orange) {
                    vpnManager.clearError()
                }
            } else if let reason = vpnManager.lastDisconnectReason {
                VPNMessageCard(title: L("Ostatnie rozłączenie"), message: reason, icon: "bolt.slash.fill", color: .orange) {
                    vpnManager.clearError()
                }
            }

            infoCard(L("Gotowe pozycje to oficjalnie udokumentowane adresy Surfshark i hide.me — MacAdBlock nie uruchamia własnej sieci VPN. Operator nadal wymaga aktywnego konta i danych IKEv2. Hasło trafia do Pęku kluczy, a profil wymaga podpisanej aplikacji z capability Personal VPN i zatwierdzenia przez macOS."), icon: "hand.raised.fill")
        }
    }

    private var securityView: some View {
        SettingsPage(title: L("Bezpieczeństwo"), subtitle: L("Phishing, oszustwa i złośliwe domeny")) {
            categoryToggle(.security, L("Ochrona przed phishingiem i oszustwami"))
            categoryToggle(.malware, L("Listy domen malware"))
            infoCard("MacAdBlock blokuje znane domeny, ale nie zastępuje programu antywirusowego.", icon: "exclamationmark.shield")
        }
    }

    private var safariView: some View {
        SettingsPage(title: "Safari", subtitle: L("Rozszerzenia i reguły Content Blocker")) {
            statusRow(L("Safari Content Blocker"), model.contentBlockerEnabled == true ? L("Włączony") : L("Wymaga włączenia"), active: model.contentBlockerEnabled == true)
            statusRow(L("Safari Web Extension"), model.webExtensionEnabled == true ? L("Włączone") : L("Wymaga włączenia"), active: model.webExtensionEnabled == true)
            statusRow(L("Pełna ochrona Safari"), model.safariExtensionStatus, active: model.safariProtectionEnabled == true)
            statusRow(L("Reguły Content Blocker"), model.statistics.contentBlockerRuleCount.formatted(), active: model.statistics.contentBlockerRuleCount > 0)
            statusRow(L("Reguły Web Extension"), model.statistics.webExtensionRuleCount.formatted(), active: model.statistics.webExtensionRuleCount > 0)
            actionRow(L("Dokończ włączenie w Safari"), L("MacAdBlock otworzy właściwy panel. Zaznacz oba rozszerzenia i zezwól na dostęp do witryn."), icon: "safari") { model.openSafariExtensionSettings() }
            infoCard(L("Rozszerzenia są już dołączone do aplikacji i instalują się razem z nią. Ze względów bezpieczeństwa macOS nie pozwala aplikacji samodzielnie zaznaczyć zgody w Safari — tę jedną czynność musi wykonać użytkownik."), icon: "hand.raised.fill")
        }
    }

    private var networkView: some View {
        SettingsPage(title: L("Sieć i hosts"), subtitle: L("Ochrona wszystkich aplikacji przez /etc/hosts")) {
            statusRow(L("Helper systemowy"), model.helperMessage ?? L("Sprawdzanie"), active: model.helperStatus == .enabled)
            statusRow(L("Sekcja MacAdBlock w hosts"), model.hostsEnabled ? L("Aktywna") : L("Nieaktywna"), active: model.hostsEnabled)
            statusRow(L("Zablokowane domeny"), model.statistics.hostDomainCount.formatted(), active: model.statistics.hostDomainCount > 0)
            HStack {
                Button(L("Zastosuj hosts")) { model.applyHosts() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canManageHosts || model.statistics.hostDomainCount == 0)
                Button(L("Usuń sekcję hosts"), role: .destructive) { model.removeHosts() }
                    .buttonStyle(.bordered)
                    .disabled(!model.canManageHosts || !model.hostsEnabled)
                Button(L("Sprawdź helper")) { model.prepareHostsHelper(openApprovalSettings: true) }.buttonStyle(.bordered)
            }
        }
    }

    private var advancedView: some View {
        SettingsPage(title: L("Zaawansowane"), subtitle: L("Diagnostyka i operacje konserwacyjne")) {
            statusRow(L("Wersja MacAdBlock"), versionDescription, active: true)
            statusRow(
                L("Integracje systemowe"),
                model.systemIntegrationStatus,
                active: model.systemIntegrationStatus == "Pakiet jest poprawnie zainstalowany i podpisany"
            )
            actionRow(L("Sprawdź aktualizacje aplikacji"), model.applicationUpdateStatus, icon: "arrow.down.app") {
                Task { await model.checkApplicationInstallationAndUpdates(force: true) }
            }
            actionRow(L("Aktualizuj ochronę teraz"), model.statusMessage, icon: "arrow.clockwise") { model.updateFilters() }
            actionRow(L("Wyczyść statystyki"), L("Usuwa zapisane liczniki aktualizacji i reguł."), icon: "trash") { model.clearStatistics() }
            infoCard(L("App Group: \(SharedStorage.appGroupIdentifier)\n\(model.storage.rootURL.path)"), icon: "externaldrive")
            systemHealthSection
            diagnosticsLogSection
        }
    }

    /// Zbiorczy podgląd stanu mechanizmów, które ochronę faktycznie wykonują (helper hosts, oba
    /// rozszerzenia Safari, firewall) — w jednym miejscu, zamiast rozproszone po zakładkach Sieć/
    /// Firewall/Filtry. Ma pomóc szybko zobaczyć, co realnie wymaga uwagi, zanim zacznie się szukać
    /// przyczyny po omacku (tak jak trzeba było przy dublujących się rozszerzeniach w Safari).
    private var systemHealthSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("Kondycja systemu")).font(.headline)
                Spacer()
                Button(L("Odśwież")) {
                    model.refreshSafariStatus()
                    model.firewall.refreshNativeStatus()
                    Task { await model.firewall.refreshStatus() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            statusRow(L("Helper hosts"), helperStatusDescription, active: model.helperStatus == .enabled)
            statusRow(L("Content Blocker (Safari)"), safariComponentDescription(model.contentBlockerEnabled), active: model.contentBlockerEnabled == true)
            statusRow(L("Web Extension (Safari)"), safariComponentDescription(model.webExtensionEnabled), active: model.webExtensionEnabled == true)
            if model.hostsEnabled {
                statusRow(L("Sekcja hosts aktualna"), model.hostsAreCurrent ? L("Tak") : L("Wymaga zastosowania"), active: model.hostsAreCurrent)
            }
            if model.firewall.config.enabled {
                statusRow(
                    L("Firewall (PF)"),
                    model.firewall.statusKnown ? (model.firewall.pfActive ? L("Aktywny") : L("Włączony, ale nieaktywny")) : L("Sprawdzanie…"),
                    active: model.firewall.statusKnown && model.firewall.pfActive
                )
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    private var helperStatusDescription: String {
        switch model.helperStatus {
        case .enabled: L("Gotowy")
        case .requiresApproval: L("Wymaga zgody w Ustawieniach systemowych")
        case .notRegistered: L("Nieskonfigurowany")
        case .notFound: L("Niedostępny")
        @unknown default: L("Nieznany")
        }
    }

    private func safariComponentDescription(_ enabled: Bool?) -> String {
        switch enabled {
        case true: L("Włączone")
        case false: L("Wyłączone — włącz w Safari")
        case nil: L("Sprawdzanie…")
        }
    }

    /// Log diagnostyczny (JSON Lines) zapisywany przez `SharedStorage.appendDiagnostic` z miejsc, gdzie
    /// wcześniej błędy potrafiły zawieść po cichu (helper XPC, /etc/hosts, aktualizacje list). Czytany
    /// bezpośrednio z pliku przy każdym otwarciu tej sekcji — bez oddzielnego stanu do odświeżania.
    private var diagnosticsLogSection: some View {
        let entries = model.storage.readDiagnostics(limit: 30)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Diagnostyka")).font(.headline)
                Spacer()
                if !entries.isEmpty {
                    Button(L("Eksportuj log")) { model.exportDiagnosticsLog() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Button(L("Wyczyść log")) { model.storage.clearDiagnostics() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            if entries.isEmpty {
                infoCard(L("Brak zarejestrowanych błędów. Ta sekcja wypełni się automatycznie, jeśli coś zawiedzie w warstwach systemowych (helper, hosts, aktualizacje list)."), icon: "checkmark.circle")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        diagnosticsRow(entry)
                    }
                }
            }
        }
    }

    private func diagnosticsRow(_ entry: DiagnosticEntry) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(entry.subsystem) · \(entry.operation)").font(.subheadline.weight(.semibold))
                Text(entry.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary.opacity(0.7))
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return L("\(version) (build \(build))")
    }

    private func categoryToggle(_ category: FilterCategory, _ title: String) -> some View {
        settingsToggle(title, category.displayName, Binding(get: { model.isCategoryEnabled(category) }, set: { model.setCategory(category, enabled: $0) }))
    }

    private func settingsToggle(_ title: String, _ subtitle: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 3) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
        .toggleStyle(.switch).tint(SentinelTheme.accent).padding(.vertical, 6)
    }

    private func actionRow(_ title: String, _ subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Image(systemName: icon).frame(width: 26).foregroundStyle(.green); VStack(alignment: .leading) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                .padding(12).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }

    private func destructiveActionRow(_ title: String, _ subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Image(systemName: icon).frame(width: 26).foregroundStyle(.red); VStack(alignment: .leading) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                .padding(12).background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }

    private func statusRow(_ title: String, _ value: String, active: Bool) -> some View {
        HStack { Circle().fill(active ? Color.green : Color.orange).frame(width: 8, height: 8); Text(title); Spacer(); Text(value).foregroundStyle(.secondary) }
            .padding(.vertical, 7)
    }

    private func infoCard(_ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) { Image(systemName: icon).font(.title2).foregroundStyle(.green); Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled); Spacer() }
            .padding(16).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    private var settingsBackground: LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.008, green: 0.015, blue: 0.018), Color(red: 0.04, green: 0.08, blue: 0.068)]
                : [Color(red: 0.99, green: 0.992, blue: 0.985), Color(red: 0.91, green: 0.975, blue: 0.94)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

}

@MainActor
private final class DNSProxyController: ObservableObject {
    @Published var isEnabled = false
    @Published var status = L("Wyłączony")

    private let manager = NEDNSProxyManager.shared()

    func refresh() async {
        do {
            try await load()
            isEnabled = manager.isEnabled
            status = isEnabled ? L("Aktywny") : L("Wyłączony")
        } catch {
            isEnabled = false
            status = friendlyMessage(for: error)
        }
    }

    func setEnabled(_ enabled: Bool, provider: String) async {
        do {
            try await load()
            if enabled {
                guard let host = Self.providerHosts[provider] else {
                    status = L("Wybierz dostawcę DNS")
                    isEnabled = false
                    return
                }
                let providerProtocol = NEDNSProxyProviderProtocol()
                providerProtocol.providerBundleIdentifier = "com.italiano88.MacAdBlock.DNSProxy"
                providerProtocol.providerConfiguration = ["upstreamHost": host, "upstreamPort": 53]
                manager.providerProtocol = providerProtocol
                manager.localizedDescription = L("MacAdBlock DNS")
            }
            manager.isEnabled = enabled
            try await save()
            await refresh()
        } catch {
            isEnabled = manager.isEnabled
            status = friendlyMessage(for: error)
        }
    }

    private func load() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func save() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        if (error as NSError).domain.hasPrefix("NE") {
            return L("Wymaga podpisania i capability Network Extension")
        }
        return error.localizedDescription
    }

    private static let providerHosts = [
        "Cloudflare": "1.1.1.1",
        "Quad9": "9.9.9.9",
        L("AdGuard DNS"): "94.140.14.14"
    ]
}

@MainActor
private final class EncryptedDNSController: ObservableObject {
    @Published var isEnabled = false
    @Published var status = L("Wyłączony")

    private let manager = NEDNSSettingsManager.shared()

    init() {
        Task { await refresh() }
    }

    func refresh() async {
        do {
            try await load()
            isEnabled = manager.isEnabled
            status = isEnabled ? L("Aktywny") : L("Wyłączony")
        } catch {
            isEnabled = false
            status = Self.message(for: error)
        }
    }

    func setEnabled(_ enabled: Bool, provider: String) async {
        do {
            try await load()
            if enabled {
                guard let endpoint = Self.endpoints[provider] else {
                    status = L("Wybierz dostawcę DNS")
                    isEnabled = false
                    return
                }
                let settings = NEDNSOverHTTPSSettings(servers: endpoint.addresses)
                settings.serverURL = URL(string: endpoint.url)
                manager.dnsSettings = settings
                manager.localizedDescription = L("MacAdBlock — \(provider) (DoH)")
                try await save()
            } else {
                try await remove()
            }
            await refresh()
        } catch {
            isEnabled = manager.isEnabled
            status = Self.message(for: error)
        }
    }

    private func load() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func save() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func remove() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.removeFromPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func message(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NEDNSSettingsErrorDomain {
            return L("Zatwierdź w Ustawieniach systemowych → Sieć → Filtry i serwery proxy DNS")
        }
        if nsError.domain.hasPrefix("NE") {
            return L("Wymaga podpisania i uprawnienia Network Extension")
        }
        return error.localizedDescription
    }

    private static let endpoints: [String: (url: String, addresses: [String])] = [
        "Cloudflare": ("https://cloudflare-dns.com/dns-query", ["1.1.1.1", "1.0.0.1"]),
        "Quad9": ("https://dns.quad9.net/dns-query", ["9.9.9.9", "149.112.112.112"]),
        L("AdGuard DNS"): ("https://dns.adguard-dns.com/dns-query", ["94.140.14.14", "94.140.15.15"])
    ]
}

private struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.largeTitle.bold()); Text(subtitle).foregroundStyle(.secondary) }
            content
        }
        .frame(maxWidth: 760, alignment: .leading)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, filters, dns, vpn, privacy, security, safari, network, advanced
    var id: String { rawValue }
    var title: String { switch self { case .general: L("Ogólne"); case .filters: L("Filtry"); case .dns: "DNS"; case .vpn: "VPN"; case .privacy: L("Prywatność"); case .security: L("Bezpieczeństwo"); case .safari: "Safari"; case .network: L("Sieć"); case .advanced: L("Zaawansowane") } }
    var icon: String { switch self { case .general: "gearshape.fill"; case .filters: "shield.fill"; case .dns: "server.rack"; case .vpn: "lock.shield.fill"; case .privacy: "eye.slash.fill"; case .security: "exclamationmark.shield.fill"; case .safari: "safari.fill"; case .network: "network"; case .advanced: "slider.horizontal.3" } }
}

private struct VPNMessageCard: View {
    let title: String
    let message: String
    let icon: String
    let color: Color
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(13)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.25)) }
    }
}
