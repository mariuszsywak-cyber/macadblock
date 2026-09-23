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
                .sheet(isPresented: $model.showWhatsNew) {
                    WhatsNewView().environmentObject(model)
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

private struct WhatsNewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L("Co nowego"), systemImage: "sparkles")
                .font(.title2.bold())
            Text(model.displayedApplicationVersion).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(AppModel.whatsNewHighlights, id: \.self) { line in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(SentinelTheme.accent)
                        Text(line)
                    }
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button(L("Zamknij")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 420, height: 380)
    }
}

private struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var step = 0
    @State private var goals: Set<BlockingGoal> = BlockingGoal.recommended
    @State private var enableSafariFilters = true
    @State private var enableHostsProtection = true
    @State private var hostsIntensity: ProtectionProfile = .balanced
    @State private var countries: Set<String> = ["PL"]

    private let accent = SentinelTheme.accent
    private let totalSteps = 5
    private let availableCountries = [("PL", "Polska"), ("DE", "Niemcy"), ("FR", "Francja"), ("IT", L("Włochy")), ("ES", "Hiszpania"), ("NL", "Niderlandy")]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L("Konfiguracja ochrony"), systemImage: "checkmark.shield.fill")
                    .font(.title2.bold()).foregroundStyle(.primary)
                Spacer()
                Text("\(step + 1) z \(totalSteps)").foregroundStyle(.secondary)
            }
            .padding(24)

            ProgressView(value: Double(step + 1), total: Double(totalSteps)).tint(accent).padding(.horizontal, 24)

            ScrollView {
                Group {
                    switch step {
                    case 0: goalsStep
                    case 1: safariStep
                    case 2: hostsStep
                    case 3: countryStep
                    default: summaryStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                if step > 0 { Button(L("Wstecz")) { step -= 1 }.buttonStyle(.bordered) }
                Spacer()
                Button(step == totalSteps - 1 ? L("Włącz ochronę") : L("Dalej")) {
                    if step < totalSteps - 1 {
                        step += 1
                    } else {
                        model.completeOnboarding(
                            goals: goals,
                            enableSafariFilters: enableSafariFilters,
                            enableHostsProtection: enableHostsProtection,
                            hostsIntensity: hostsIntensity,
                            countryCodes: countries
                        )
                    }
                }
                .buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
                .disabled(step == 0 && goals.isEmpty)
            }
            .padding(24)
        }
        .frame(width: 650, height: 560)
        .background(onboardingBackground)
    }

    // MARK: - Krok 1: co blokować (wspólne dla Safari i hosts)

    private var goalsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Co chcesz blokować?")).font(.title.bold())
            Text(L("Na tej podstawie dobierzemy właściwe listy — osobno dla Safari i osobno dla ochrony hosts/DNS.")).foregroundStyle(.secondary)
            VStack(spacing: 10) {
                ForEach(BlockingGoal.universal) { goal in
                    goalRow(goal)
                }
            }
        }
    }

    private func goalRow(_ goal: BlockingGoal) -> some View {
        let isOn = goals.contains(goal)
        return Button {
            if isOn { goals.remove(goal) } else { goals.insert(goal) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: goal.systemImage).font(.title3).foregroundStyle(isOn ? accent : .secondary).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(goal.title).font(.headline)
                    Text(goal.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle").font(.title2).foregroundStyle(isOn ? accent : .secondary)
            }
            .padding(14).background(Color.primary.opacity(isOn ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain)
    }

    // MARK: - Krok 2: warstwa Safari

    private var safariStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Filtry w Safari")).font(.title.bold())
            Text(L("Blokują reklamy i elementy bezpośrednio na stronach — tylko w przeglądarce Safari.")).foregroundStyle(.secondary)
            Toggle(L("Włącz filtry Safari"), isOn: $enableSafariFilters).toggleStyle(.switch)
            if enableSafariFilters {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("Na podstawie wybranych celów włączymy")).font(.caption).foregroundStyle(.secondary)
                    Text(L("około \(previewCount(safariOnly: true).formatted()) reguł")).font(.title2.bold()).foregroundStyle(accent)
                    Text(safariGoals.isEmpty ? L("Nie wybrano żadnych celów — wróć do poprzedniego kroku.") : safariGoalSummary).foregroundStyle(.secondary)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            } else {
                Text(L("Ochrona Safari zostanie pominięta w tym kreatorze — możesz włączyć ją później w ustawieniach.")).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Krok 3: warstwa hosts/DNS

    private var hostsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Ochrona hosts/DNS")).font(.title.bold())
            Text(L("Blokuje połączenia na poziomie całego systemu — działa też poza Safari.")).foregroundStyle(.secondary)
            Toggle(L("Włącz ochronę hosts/DNS"), isOn: $enableHostsProtection).toggleStyle(.switch)
            if enableHostsProtection {
                Text(L("Intensywność ogólnej listy reklam i prywatności")).font(.subheadline.bold())
                ForEach(ProtectionProfile.allCases) { option in
                    Button { hostsIntensity = option } label: {
                        HStack(spacing: 14) {
                            Image(systemName: hostsIntensity == option ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(hostsIntensity == option ? accent : .secondary)
                            VStack(alignment: .leading) { Text(option.title).font(.subheadline); Text(option.subtitle).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                        }
                        .padding(12).background(Color.primary.opacity(hostsIntensity == option ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                }
                Text(L("Kategorie treści (tylko hosts/DNS — Safari tego nie blokuje)")).font(.subheadline.bold())
                VStack(spacing: 10) {
                    ForEach(BlockingGoal.hostsOnlyContent) { goal in
                        goalRow(goal)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("Na podstawie wybranych celów włączymy")).font(.caption).foregroundStyle(.secondary)
                    Text(L("około \(previewCount(safariOnly: false).formatted()) domen")).font(.title2.bold()).foregroundStyle(accent)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            } else {
                Text(L("Ochrona hosts/DNS zostanie pominięta w tym kreatorze — możesz włączyć ją później w ustawieniach.")).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Krok 4: kraje

    private var countryStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Wybierz kraje")).font(.title.bold())
            Text(L("Listy globalne są zawsze aktywne. Dodaj kraje stron, które odwiedzasz — dotyczy Safari i hosts.")).foregroundStyle(.secondary)
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

    // MARK: - Krok 5: podsumowanie

    private var summaryStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Podsumowanie")).font(.title.bold())
            VStack(alignment: .leading, spacing: 12) {
                summaryRow(icon: "target", title: L("Cele"), value: goals.isEmpty ? L("brak") : goalSummary)
                summaryRow(icon: "safari", title: L("Filtry Safari"), value: enableSafariFilters ? L("włączone") : L("wyłączone"))
                summaryRow(icon: "network", title: L("Hosts/DNS"), value: enableHostsProtection ? hostsIntensity.title : L("wyłączone"))
                summaryRow(icon: "globe", title: L("Kraje"), value: countries.isEmpty ? L("tylko globalne") : countries.sorted().joined(separator: ", "))
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 5) {
                Text(L("Łącznie włączymy")).font(.caption).foregroundStyle(.secondary)
                Text(L("około \(previewCount(safariOnly: nil).formatted()) wpisów")).font(.title.bold()).foregroundStyle(accent)
                Text(L("Nie usuniemy list, które masz już włączone ręcznie — kreator tylko dodaje.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func summaryRow(icon: String, title: String, value: String) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(accent).frame(width: 22)
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline.bold())
        }
    }

    private var goalSummary: String {
        goals.map(\.title).sorted().joined(separator: ", ")
    }

    /// Tylko cele, które faktycznie coś zmieniają w Safari (kategorie treści hosts/DNS tam nie działają).
    private var safariGoals: Set<BlockingGoal> {
        goals.intersection(BlockingGoal.universal)
    }

    private var safariGoalSummary: String {
        safariGoals.map(\.title).sorted().joined(separator: ", ")
    }

    /// `safariOnly: true` liczy tylko warstwę Safari, `false` tylko hosts/DNS, `nil` obie razem —
    /// licząc rzeczywisty, zdeduplikowany wybór, jaki zrobiłby kreator (patrz `previewOnboardingSelection`).
    private func previewCount(safariOnly: Bool?) -> Int {
        let ids = model.previewOnboardingSelection(
            goals: goals,
            enableSafariFilters: safariOnly != false && enableSafariFilters,
            enableHostsProtection: safariOnly != true && enableHostsProtection,
            hostsIntensity: hostsIntensity,
            countryCodes: countries
        )
        return model.sources.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.estimatedRuleCount }
    }

    private func flag(_ code: String) -> String {
        code.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(String.init).joined()
    }

    private var onboardingBackground: LinearGradient {
        SentinelTheme.background(for: colorScheme)
    }
}
