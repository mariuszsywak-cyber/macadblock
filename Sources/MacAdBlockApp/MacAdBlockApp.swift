import AppKit
import Combine
import SwiftUI

@main
struct MacAdBlockApp: App {
    @NSApplicationDelegateAdaptor(MacAdBlockApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("MacAdBlock", id: "main") {
            DashboardView()
                .environmentObject(model)
                .preferredColorScheme(model.appearance.colorScheme)
                .tint(SentinelTheme.control)
                .frame(minWidth: 790, minHeight: 540)
                .sheet(isPresented: $model.showOnboarding) {
                    OnboardingView().environmentObject(model)
                }
                .sheet(isPresented: $model.showPaywall) {
                    SubscriptionView().environmentObject(model.subscription)
                }
                // Wyjątek dodany w popupie Safari zapisuje rozszerzenie — po powrocie do aplikacji
                // sprawdzamy plik ustawień od razu, bez czekania na cykliczne odświeżenie.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.reloadUserSettingsIfChanged()
                }
        }
        .windowStyle(.hiddenTitleBar)

        Window(L("Diagnostyka i własne reguły"), id: "user-rules") {
            UserRulesView()
                .environmentObject(model)
                .preferredColorScheme(model.appearance.colorScheme)
                .tint(SentinelTheme.control)
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
                .preferredColorScheme(model.appearance.colorScheme)
        } label: {
            // Ikona z SF Symbols: system sam dobiera grubość, rozmiar i barwę pod pasek menu,
            // dzięki czemu stoi równo z ikonami systemowymi. Stan ochrony niesie sam symbol.
            Image(systemName: model.protectionEnabled ? "checkmark.shield" : "shield.slash")
                .font(.system(size: 19, weight: .medium))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .preferredColorScheme(model.appearance.colorScheme)
                .frame(width: 900, height: 620)
        }

        .commands {
            CommandMenu(L("Ochrona")) {
                Button(L("Aktualizuj filtry")) { model.updateFilters() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button(L("Otwórz kreator konfiguracji")) { model.showOnboarding = true }
                Button(L("Subskrypcja…")) { model.showPaywall = true }
                Divider()
                Button(L("Otwórz rozszerzenia Safari")) { model.openSafariExtensionSettings() }
                Button(L("Sprawdź helper hosts")) { model.prepareHostsHelper(openApprovalSettings: true) }
                Button(L("Sprawdź aktualizacje aplikacji")) {
                    Task { await model.checkApplicationInstallationAndUpdates(force: true) }
                }
                Divider()
                OpenUserRulesButton()
                Button(L("Eksportuj konfigurację…")) { model.exportConfiguration() }
                Button(L("Wczytaj konfigurację…")) { model.importConfiguration() }
                Divider()
                Button(L("Wyczyść statystyki")) { model.clearStatistics() }
            }
        }
    }
}

/// Otwarcie okna wymaga środowiska widoku, dlatego polecenie menu jest osobnym, małym widokiem.
private struct OpenUserRulesButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L("Diagnostyka i własne reguły…")) { openWindow(id: "user-rules") }
            .keyboardShortcut("u", modifiers: [.command, .shift])
    }
}

private struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var step = 0
    @State private var profile: ProtectionProfile = .balanced
    @State private var countries: Set<String> = ["PL"]
    @State private var includeHosts = true
    @State private var includeAnnoyances = true
    @State private var includeSocial = false

    private let accent = SentinelTheme.accent
    private let availableCountries = [("PL", "Polska"), ("DE", "Niemcy"), ("FR", "Francja"), ("IT", L("Włochy")), ("ES", "Hiszpania"), ("NL", "Niderlandy")]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L("Konfiguracja ochrony"), systemImage: "checkmark.shield.fill")
                    .font(.title2.bold()).foregroundStyle(.primary)
                Spacer()
                Text("\(step + 1) z 3").foregroundStyle(.secondary)
            }
            .padding(24)

            ProgressView(value: Double(step + 1), total: 3).tint(accent).padding(.horizontal, 24)

            Group {
                switch step {
                case 0: profileStep
                case 1: countryStep
                default: categoryStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)

            HStack {
                if step > 0 { Button(L("Wstecz")) { step -= 1 }.buttonStyle(.bordered) }
                Spacer()
                Button(step == 2 ? L("Włącz ochronę") : "Dalej") {
                    if step < 2 {
                        step += 1
                    } else {
                        model.completeOnboarding(profile: profile, countryCodes: countries, includeHosts: includeHosts, includeAnnoyances: includeAnnoyances, includeSocial: includeSocial)
                    }
                }
                .buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
            }
            .padding(24)
        }
        .frame(width: 650, height: 520)
        .background(onboardingBackground)
    }

    private var profileStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Jak mocno blokować?")).font(.title.bold())
            Text(L("W każdej chwili zmienisz pojedyncze listy.")).foregroundStyle(.secondary)
            ForEach(ProtectionProfile.allCases) { option in
                Button { profile = option } label: {
                    HStack(spacing: 14) {
                        Image(systemName: profile == option ? "checkmark.circle.fill" : "circle").font(.title2).foregroundStyle(profile == option ? accent : .secondary)
                        VStack(alignment: .leading) { Text(option.title).font(.headline); Text(option.subtitle).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text(profileEstimate(option).formatted()).font(.headline.monospacedDigit())
                        Text(L("wpisów")).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(14).background(Color.primary.opacity(profile == option ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain)
            }
        }
    }

    private var countryStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Wybierz kraje")).font(.title.bold())
            Text(L("Listy globalne są zawsze aktywne. Dodaj języki stron, które odwiedzasz.")).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(availableCountries, id: \.0) { code, name in
                    Button {
                        if countries.contains(code) { countries.remove(code) } else { countries.insert(code) }
                    } label: {
                        HStack { Text(flag(code)).font(.title2); Text(name); Spacer(); Image(systemName: countries.contains(code) ? "checkmark.circle.fill" : "circle").foregroundStyle(countries.contains(code) ? accent : .secondary) }
                            .padding(14).background(Color.primary.opacity(countries.contains(code) ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 14))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var categoryStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Kategorie ochrony")).font(.title.bold())
            Toggle(L("Ochrona systemowa hosts"), isOn: $includeHosts)
            Toggle(L("Banery cookies, popupy i irytujące elementy"), isOn: $includeAnnoyances)
            Toggle(L("Przyciski i widżety mediów społecznościowych"), isOn: $includeSocial)
            VStack(alignment: .leading, spacing: 5) {
                Text(L("Szacowana ochrona")).font(.caption).foregroundStyle(.secondary)
                Text(L("około \(estimatedSelection.formatted()) reguł i domen")).font(.title2.bold()).foregroundStyle(accent)
                Text(includeHosts ? L("Obejmuje Safari oraz połączenia całego systemu.") : L("Obejmuje tylko strony otwierane w Safari.")).foregroundStyle(.secondary)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var estimatedSelection: Int {
        var total = profileEstimate(profile)
        total += model.sources.filter { countries.contains($0.countryCode) }.reduce(0) { $0 + $1.estimatedRuleCount }
        if includeAnnoyances { total += 35_000 }
        if includeSocial { total += 20_000 }
        return total
    }

    private func profileEstimate(_ option: ProtectionProfile) -> Int {
        switch option { case .light: 140_000; case .balanced: 228_000; case .maximum: 460_000 }
    }

    private func flag(_ code: String) -> String {
        code.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(String.init).joined()
    }

    private var onboardingBackground: LinearGradient {
        SentinelTheme.background(for: colorScheme)
    }
}
