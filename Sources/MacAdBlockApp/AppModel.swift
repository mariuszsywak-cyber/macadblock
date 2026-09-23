import AppKit
import Combine
import Foundation
import SafariServices
import UniformTypeIdentifiers
import UserNotifications
import Security
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    /// Ostatnio utworzony model — używany przez intencje Skrótów i Siri.
    static weak var current: AppModel?
    @Published var showOnboarding = false
    @Published var protectionEnabled = true
    @Published var pausedUntil: Date?
    @Published var showPaywall = false
    let firewall = FirewallController()
    private var childObservers: [AnyCancellable] = []
    let subscription = SubscriptionManager()
    /// 0 = wszystkie domeny; inaczej maksymalna liczba domen zapisywanych do /etc/hosts.
    @Published var hostsDomainLimit = 0 { didSet { defaults.set(hostsDomainLimit, forKey: "hostsDomainLimit") } }
    private var resumeTask: Task<Void, Never>?
    @Published var autoUpdateIntervalHours = 24
    @Published var appearance: AppAppearance = .automatic
    @Published var statistics: UpdateStatistics = .empty
    @Published var enabledSourceIDs: Set<String>
    @Published var isUpdating = false
    @Published var statusMessage = L("Gotowy")
    @Published var lastError: String?
    @Published var hostsEnabled = false
    @Published var installedHostDomainCount = 0
    @Published var helperOperational = false
    @Published var contentBlockerEnabled: Bool?
    @Published var webExtensionEnabled: Bool?
    @Published var helperStatus = SMAppService.daemon(plistName: HostsHelperConstants.daemonPlistName).status
    @Published var helperMessage: String?
    @Published var applicationNotice: ApplicationNotice? {
        didSet { if let applicationNotice { availableUpdate = applicationNotice } }
    }
    /// Ostatnia znaleziona aktualizacja/instalacja — zostaje po zamknięciu okna „Później”, żeby dało się ją uruchomić z plakietki wersji.
    @Published var availableUpdate: ApplicationNotice?
    @Published var diagnosis: DomainDiagnosis?
    @Published var isDiagnosing = false
    @Published var blockedLog: [BlockedLogEntry] = []
    @Published var dailyBlocks: [DailyBlockCount] = []
    @Published var applicationUpdateStatus = L("Nie sprawdzano")
    @Published var isCheckingApplicationUpdate = false
    @Published var automaticallyApplyHosts: Bool {
        didSet { defaults.set(automaticallyApplyHosts, forKey: "automaticallyApplyHosts") }
    }

    /// Wyjątki, własne reguły i własne listy. Plik w App Group jest wspólny z rozszerzeniami Safari.
    @Published var userSettings: UserFilterSettings
    /// Limit reguł Content Blockera. Safari odrzuca całą listę po przekroczeniu limitu, dlatego przy
    /// odmowie przeładowania budżet jest zmniejszany i lista kompilowana ponownie.
    @Published var contentBlockerRuleBudget: Int

    /// Katalog wbudowany powiększony o listy dodane przez użytkownika.
    var sources: [FilterSource] { FilterCatalog.all + userSettings.customSources }

    let storage: SharedStorage
    private var updater: FilterUpdateService
    private let hostsClient = HostsHelperClient()
    private var didAutoInstallThisLaunch = false
    private let applicationUpdateService = ApplicationUpdateService()
    private let defaults = UserDefaults(suiteName: SharedStorage.appGroupIdentifier) ?? .standard
    private var autoUpdateTask: Task<Void, Never>?
    private var userSettingsTask: Task<Void, Never>?
    private var userSettingsDate: Date?
    private var contentBlockerRetryCount = 0
    private var pendingRecompile = false
    private var consecutiveUpdateFailures = 0
    private var automaticSafariSetupRequested = false

    static let defaultContentBlockerRuleBudget = 150_000
    static let minimumContentBlockerRuleBudget = 40_000
    /// Safari dopuszcza znacznie mniej reguł dynamicznych niż Content Blocker, więc listy dla
    /// Web Extension nie ma sensu budować w rozmiarze Content Blockera.
    static let maximumDynamicRuleCount = 30_000
    private var safariSetupWatchTask: Task<Void, Never>?

    var canManageHosts: Bool {
        systemIntegrationReadiness == nil && helperStatus == .enabled
    }

    var hostsAreCurrent: Bool {
        hostsEnabled && statistics.hostDomainCount > 0 && installedHostDomainCount == statistics.hostDomainCount
    }

    var helperUsesAuthorizationFallback: Bool {
        hostsClient.usesAuthorizationFallback
    }

    var safariProtectionEnabled: Bool? {
        guard let contentBlockerEnabled, let webExtensionEnabled else { return nil }
        return contentBlockerEnabled && webExtensionEnabled
    }

    var safariExtensionStatus: String {
        switch (contentBlockerEnabled, webExtensionEnabled) {
        case (true, true): L("Oba rozszerzenia działają")
        case (false, false): L("Włącz oba rozszerzenia")
        case (true, false): L("Włącz Web Extension")
        case (false, true): L("Włącz Content Blocker")
        default: L("Sprawdzanie rozszerzeń…")
        }
    }

    var systemIntegrationStatus: String {
        systemIntegrationReadiness ?? L("Pakiet jest poprawnie zainstalowany i podpisany")
    }

    var displayedApplicationBuild: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return build
    }

    var displayedApplicationVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "v\(version) (\(build))"
    }

    init() {
        defer { Self.current = self }
        let storage = Self.makeStorage()
        self.storage = storage
        userSettings = storage.readUserSettings()
        userSettingsDate = storage.userSettingsModificationDate
        let budget = defaults.object(forKey: "contentBlockerRuleBudget") as? Int
        contentBlockerRuleBudget = budget ?? Self.defaultContentBlockerRuleBudget
        updater = Self.makeUpdater(storage: storage, budget: budget ?? Self.defaultContentBlockerRuleBudget)
        automaticallyApplyHosts = defaults.object(forKey: "automaticallyApplyHosts") as? Bool ?? true
        let stored = defaults.stringArray(forKey: "enabledSourceIDs")
        enabledSourceIDs = Set(stored ?? FilterCatalog.all.filter(\.enabledByDefault).map(\.id))
        showOnboarding = !defaults.bool(forKey: "didCompleteOnboarding")
        protectionEnabled = defaults.object(forKey: "protectionEnabled") as? Bool ?? true
        hostsDomainLimit = defaults.integer(forKey: "hostsDomainLimit")
        autoUpdateIntervalHours = defaults.object(forKey: "autoUpdateIntervalHours") as? Int ?? 24
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "automatic") ?? .automatic
        if let saved = try? storage.readJSON(UpdateStatistics.self, from: storage.statisticsURL) {
            statistics = saved
        }
        Task { prepareHostsHelper() }
        Task { await checkApplicationInstallationAndUpdates() }
        refreshSafariStatus(openSettingsIfNeeded: true)
        scheduleAutomaticUpdates()
        observeUserSettingsFile()
        if let until = defaults.object(forKey: "pausedUntil") as? Date, !protectionEnabled {
            pausedUntil = until
            scheduleResume()
        }
        checkSigningExpiry()
        firewall.reapplyAtLaunchIfPossible()
        childObservers = [
            firewall.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            subscription.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        ]
        subscription.onExpired = { [weak self] in
            guard let self, SubscriptionManager.enforcementEnabled else { return }
            self.showPaywall = true
            if self.protectionEnabled { self.setProtectionEnabled(false) }
        }
        if SubscriptionManager.enforcementEnabled, subscription.state == .expired {
            showPaywall = true
            if protectionEnabled { setProtectionEnabled(false) }
        }
    }

    private static func makeUpdater(storage: SharedStorage, budget: Int) -> FilterUpdateService {
        FilterUpdateService(
            storage: storage,
            compiler: SafariRuleCompiler(maximumRules: budget, maximumDynamicRules: maximumDynamicRuleCount)
        )
    }

    /// Kontener App Group → Application Support → katalog tymczasowy. Aplikacja nie kończy się awarią,
    /// gdy któryś z pierwszych dwóch jest niedostępny (np. podpis ad-hoc bez entitlementów).
    private static func makeStorage() -> SharedStorage {
        if let shared = try? SharedStorage() { return shared }
        if let fallback = try? SharedStorage.applicationFallback() { return fallback }
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MacAdBlock", isDirectory: true)
        if let temporary = try? SharedStorage(rootURL: temporaryRoot) { return temporary }
        fatalError(L("MacAdBlock nie może utworzyć żadnego katalogu roboczego."))
    }

    func setSource(_ source: FilterSource, enabled: Bool) {
        if enabled { enabledSourceIDs.insert(source.id) } else { enabledSourceIDs.remove(source.id) }
        defaults.set(Array(enabledSourceIDs).sorted(), forKey: "enabledSourceIDs")
    }

    func isCategoryEnabled(_ category: FilterCategory) -> Bool {
        sources.contains { $0.category == category && enabledSourceIDs.contains($0.id) }
    }

    func setCategory(_ category: FilterCategory, enabled: Bool) {
        for source in sources where source.category == category && (!enabled || !source.isExtra) {
            if enabled { enabledSourceIDs.insert(source.id) } else { enabledSourceIDs.remove(source.id) }
        }
        defaults.set(Array(enabledSourceIDs).sorted(), forKey: "enabledSourceIDs")
    }

    // MARK: - Wyjątki, własne reguły i własne listy

    /// Zapisuje ustawienia użytkownika w App Group i przebudowuje reguły we wszystkich warstwach.
    private func persistUserSettings(_ settings: UserFilterSettings, status: String) {
        userSettings = settings
        do {
            try storage.writeUserSettings(settings)
        } catch {
            lastError = L("Nie udało się zapisać własnych ustawień: \(error.localizedDescription)")
            return
        }
        userSettingsDate = storage.userSettingsModificationDate
        storage.invalidateCompiledFingerprint()
        statusMessage = status
        requestRecompile()
    }

    /// Aktualizacja może już trwać (np. przeładowanie Safari w jej trakcie), a `updateFilters()`
    /// pomija wtedy wywołanie. Żądanie jest więc kolejkowane i realizowane po zakończeniu bieżącej.
    private func requestRecompile() {
        if isUpdating { pendingRecompile = true } else { updateFilters() }
    }

    func allowDomain(_ domain: String) {
        var settings = userSettings
        settings.allow(domain)
        guard settings != userSettings else { return }
        persistUserSettings(settings, status: L("Dodano wyjątek — przebudowuję reguły"))
    }

    func disallowDomain(_ domain: String) {
        var settings = userSettings
        settings.disallow(domain)
        guard settings != userSettings else { return }
        persistUserSettings(settings, status: L("Usunięto wyjątek — przebudowuję reguły"))
    }

    func setCustomRules(_ rules: String) {
        guard rules != userSettings.customRules else { return }
        var settings = userSettings
        settings.customRules = rules
        persistUserSettings(settings, status: L("Zapisano własne reguły"))
    }

    /// Dodaje listę z adresu podanego przez użytkownika i od razu ją włącza.
    func addCustomSource(name: String, address: String, format: FilterFormat, category: FilterCategory) {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let source = UserFilterSettings.customSource(name: name, url: url, format: format, category: category) else {
            lastError = L("Podaj nazwę i poprawny adres HTTPS listy.")
            return
        }
        guard !sources.contains(where: { $0.id == source.id }) else {
            lastError = L("Ta lista jest już dodana.")
            return
        }
        var settings = userSettings
        settings.customSources.append(source)
        enabledSourceIDs.insert(source.id)
        defaults.set(Array(enabledSourceIDs).sorted(), forKey: "enabledSourceIDs")
        persistUserSettings(settings, status: L("Dodano listę \(source.name)"))
    }

    func removeCustomSource(_ source: FilterSource) {
        var settings = userSettings
        settings.customSources.removeAll { $0.id == source.id }
        guard settings != userSettings else { return }
        enabledSourceIDs.remove(source.id)
        defaults.set(Array(enabledSourceIDs).sorted(), forKey: "enabledSourceIDs")
        persistUserSettings(settings, status: L("Usunięto listę \(source.name)"))
    }

    /// Wyjątek dodany w popupie Safari zapisuje rozszerzenie, więc aplikacja sprawdza plik ustawień
    /// i przebudowuje reguły Content Blockera oraz sekcję hosts, gdy zmienił się poza aplikacją.
    private func observeUserSettingsFile() {
        userSettingsTask?.cancel()
        userSettingsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self else { return }
                self.reloadUserSettingsIfChanged()
            }
        }
    }

    func reloadUserSettingsIfChanged() {
        guard let modified = storage.userSettingsModificationDate else { return }
        guard modified != userSettingsDate else { return }
        userSettingsDate = modified
        let loaded = storage.readUserSettings()
        guard loaded != userSettings else { return }
        userSettings = loaded
        storage.invalidateCompiledFingerprint()
        statusMessage = L("Zmieniono wyjątki w Safari — przebudowuję reguły")
        requestRecompile()
    }

    // MARK: - Diagnostyka domeny

    /// Przeszukuje pobrane listy i wygenerowane pliki, żeby pokazać, co ochrona robi z daną domeną.
    /// Skanowanie plików cache idzie poza głównym wątkiem, bo obejmuje dziesiątki megabajtów tekstu.
    func refreshBlockedLog() {
        blockedLog = storage.readBlockLog()
        dailyBlocks = storage.readDailyBlocks(days: 30)
    }

    func clearBlockedLog() {
        storage.clearBlockLog()
        blockedLog = []
        dailyBlocks = storage.readDailyBlocks(days: 30)
    }

    func diagnoseDomain(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isDiagnosing else { return }
        isDiagnosing = true
        diagnosis = nil
        let storage = storage
        let selected = sources.filter { enabledSourceIDs.contains($0.id) }
        let settings = userSettings
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DomainDiagnostics(storage: storage).diagnose(query, sources: selected, settings: settings)
            }.value
            isDiagnosing = false
            guard let result else {
                lastError = L("To nie wygląda na poprawną nazwę domeny: \(query)")
                return
            }
            diagnosis = result
            statusMessage = result.isTouchedByProtection
                ? L("Ochrona dotyka \(result.domain)")
                : L("Żadna włączona reguła nie dotyczy \(result.domain)")
        }
    }

    func clearDiagnosis() {
        diagnosis = nil
    }

    // MARK: - Limit reguł Safari

    func setContentBlockerRuleBudget(_ budget: Int) {
        let clamped = min(Self.defaultContentBlockerRuleBudget, max(Self.minimumContentBlockerRuleBudget, budget))
        guard clamped != contentBlockerRuleBudget else { return }
        contentBlockerRuleBudget = clamped
        defaults.set(clamped, forKey: "contentBlockerRuleBudget")
        updater = Self.makeUpdater(storage: storage, budget: clamped)
        storage.invalidateCompiledFingerprint()
    }

    /// Safari nie podaje przyczyny odmowy, a najczęstszą jest zbyt duża lista. Budżet jest zmniejszany
    /// najwyżej trzy razy; przy każdym udanym przeładowaniu licznik wraca do zera.
    private func reduceContentBlockerBudget() -> Bool {
        guard contentBlockerRetryCount < 3 else { return false }
        let reduced = max(Self.minimumContentBlockerRuleBudget, Int(Double(contentBlockerRuleBudget) * 0.6))
        guard reduced < contentBlockerRuleBudget else { return false }
        contentBlockerRetryCount += 1
        setContentBlockerRuleBudget(reduced)
        requestRecompile()
        return true
    }

    /// Po udanym przeładowaniu spróbuj odzyskać część limitu zmniejszonego wcześniej przez
    /// reduceContentBlockerBudget() — np. po wyłączeniu ciężkich list filtrów limit sam wraca w górę
    /// zamiast trwale zostać przy niższej wartości aż do ręcznego resetu. Działa krokowo (odwrotność
    /// mnożnika 0.6) i dotyczy tylko kolejnej aktualizacji — nie wymusza natychmiastowego przeładowania,
    /// więc nie ryzykuje pętli odrzuceń.
    private func recoverContentBlockerBudgetIfNeeded() {
        guard contentBlockerRuleBudget < Self.defaultContentBlockerRuleBudget else { return }
        let recovered = min(Self.defaultContentBlockerRuleBudget, Int(Double(contentBlockerRuleBudget) / 0.6))
        guard recovered > contentBlockerRuleBudget else { return }
        setContentBlockerRuleBudget(recovered)
    }

    // MARK: - Konfiguracja

    func exportConfiguration() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MacAdBlock-konfiguracja.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let configuration = MacAdBlockConfiguration(
            enabledSourceIDs: enabledSourceIDs.sorted(),
            userSettings: userSettings,
            protectionEnabled: protectionEnabled,
            automaticallyApplyHosts: automaticallyApplyHosts,
            autoUpdateIntervalHours: autoUpdateIntervalHours,
            appearance: appearance.rawValue,
            contentBlockerRuleBudget: contentBlockerRuleBudget
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: url, options: .atomic)
            statusMessage = L("Konfiguracja została zapisana")
        } catch {
            lastError = L("Nie udało się zapisać konfiguracji: \(error.localizedDescription)")
        }
    }

    func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let configuration = try JSONDecoder().decode(MacAdBlockConfiguration.self, from: data)
            let known = Set((FilterCatalog.all + configuration.userSettings.customSources).map(\.id))
            enabledSourceIDs = Set(configuration.enabledSourceIDs).intersection(known)
            defaults.set(Array(enabledSourceIDs).sorted(), forKey: "enabledSourceIDs")
            automaticallyApplyHosts = configuration.automaticallyApplyHosts
            setAutoUpdateInterval(hours: configuration.autoUpdateIntervalHours)
            setAppearance(AppAppearance(rawValue: configuration.appearance) ?? .automatic)
            setContentBlockerRuleBudget(configuration.contentBlockerRuleBudget)
            protectionEnabled = configuration.protectionEnabled
            defaults.set(configuration.protectionEnabled, forKey: "protectionEnabled")
            persistUserSettings(configuration.userSettings, status: L("Konfiguracja została wczytana"))
        } catch {
            lastError = L("Nie udało się wczytać konfiguracji: \(error.localizedDescription)")
        }
    }

    func clearStatistics() {
        statistics = .empty
        try? storage.writeJSON(UpdateStatistics.empty, to: storage.statisticsURL)
        statusMessage = L("Statystyki zostały wyczyszczone")
    }

    func checkApplicationInstallationAndUpdates(force: Bool = false) async {
        guard !isCheckingApplicationUpdate else { return }
        isCheckingApplicationUpdate = true
        defer { isCheckingApplicationUpdate = false }
        availableUpdate = nil

        let currentURL = Bundle.main.bundleURL.standardizedFileURL
        let destinationURL = ApplicationUpdateService.destinationURL
        let currentVersion = applicationUpdateService.version(at: currentURL) ?? .init(version: "0", build: 0)

        if currentURL != destinationURL {
            let installedVersion = applicationUpdateService.version(at: destinationURL)
            if let installedVersion, installedVersion >= currentVersion {
                applicationNotice = ApplicationNotice(
                    kind: .openInstalled,
                    title: L("MacAdBlock jest już zainstalowany"),
                    message: L("W folderze Aplikacje znajduje się ta sama lub nowsza wersja. Uruchom zainstalowaną kopię, aby działały rozszerzenia Safari i ochrona hosts."),
                    actionTitle: L("Uruchom z Aplikacji")
                )
            } else {
                applicationNotice = ApplicationNotice(
                    kind: .installCurrent,
                    title: installedVersion == nil ? L("Zainstaluj MacAdBlock") : L("Zaktualizuj MacAdBlock"),
                    message: L("MacAdBlock zostanie automatycznie skopiowany do systemowego folderu Aplikacje. macOS poprosi o hasło administratora. Instalacja zachowa ustawienia i umożliwi rejestrację rozszerzeń oraz helpera."),
                    actionTitle: installedVersion == nil ? L("Zainstaluj automatycznie") : L("Zaktualizuj automatycznie")
                )
            }
            applicationUpdateStatus = L("Wymaga instalacji w /Applications")
            // Uruchomiona kopia ma wyższy build niż ta w /Applications (albo nic tam nie ma) — aktualizujemy sama,
            // raz na uruchomienie. Anulowanie okna hasła nie powoduje ponawiania w pętli.
            if let notice = applicationNotice, case .installCurrent = notice.kind, !didAutoInstallThisLaunch {
                didAutoInstallThisLaunch = true
                Task { @MainActor in performApplicationNoticeAction() }
            }
            return
        }

        guard let manifestURL = configuredUpdateManifestURL else {
            applicationUpdateStatus = L("Automatyczne aktualizacje czekają na adres manifestu")
            return
        }

        do {
            let release = try await applicationUpdateService.fetchRelease(from: manifestURL)
            let availableVersion = InstalledApplicationVersion(version: release.version, build: release.build)
            if currentVersion < availableVersion {
                applicationNotice = ApplicationNotice(
                    kind: .downloadUpdate(release),
                    title: L("Dostępna jest wersja \(release.version)"),
                    message: release.notes ?? L("Nowsza wersja MacAdBlock jest gotowa do pobrania i instalacji."),
                    actionTitle: L("Pobierz i zainstaluj")
                )
                applicationUpdateStatus = L("Dostępna wersja \(release.version)")
            } else {
                applicationUpdateStatus = L("MacAdBlock jest aktualny")
                if force { statusMessage = applicationUpdateStatus }
            }
        } catch {
            applicationUpdateStatus = L("Nie udało się sprawdzić aktualizacji")
            if force { lastError = error.localizedDescription }
        }
    }

    func performApplicationNoticeAction(_ explicitNotice: ApplicationNotice? = nil) {
        guard let notice = explicitNotice ?? applicationNotice else { return }
        applicationNotice = nil
        availableUpdate = nil

        switch notice.kind {
        case .openInstalled:
            applicationUpdateService.openApplicationAndTerminate(at: ApplicationUpdateService.destinationURL)
        case .installCurrent:
            // Kopiowanie i okno hasła administratora działają poza głównym wątkiem; interfejs pozostaje responsywny.
            guard !isCheckingApplicationUpdate else { applicationNotice = notice; return }
            isCheckingApplicationUpdate = true
            applicationUpdateStatus = L("Instalowanie MacAdBlock w folderze Aplikacje…")
            Task {
                defer { isCheckingApplicationUpdate = false }
                do {
                    let installedURL = try await applicationUpdateService.installCurrentApplication()
                    applicationUpdateStatus = L("MacAdBlock został zainstalowany")
                    applicationUpdateService.openApplicationAndTerminate(at: installedURL)
                } catch let error as ApplicationUpdateError {
                    if case .authorizationCancelled = error {
                        // Anulowanie okna hasła nie jest błędem — zostawiamy możliwość ponowienia.
                        applicationUpdateStatus = L("Instalacja anulowana")
                        applicationNotice = notice
                    } else {
                        applicationUpdateStatus = L("Instalacja nie powiodła się")
                        lastError = L("Nie udało się zaktualizować MacAdBlock w folderze Aplikacje. \(error.localizedDescription)")
                    }
                } catch {
                    applicationUpdateStatus = L("Instalacja nie powiodła się")
                    lastError = L("Nie udało się zaktualizować MacAdBlock w folderze Aplikacje. \(error.localizedDescription)")
                }
            }
        case .downloadUpdate(let release):
            isCheckingApplicationUpdate = true
            applicationUpdateStatus = L("Pobieranie wersji \(release.version)…")
            Task {
                defer { isCheckingApplicationUpdate = false }
                do {
                    let packageURL = try await applicationUpdateService.downloadVerifiedPackage(for: release)
                    applicationUpdateStatus = L("Instalator wersji \(release.version) jest gotowy")
                    applicationUpdateService.openInstaller(at: packageURL)
                } catch {
                    applicationUpdateStatus = L("Aktualizacja nie powiodła się")
                    lastError = error.localizedDescription
                }
            }
        }
    }

    private var configuredUpdateManifestURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "MacAdBlockUpdateManifestURL") as? String,
              !value.isEmpty else { return nil }
        return URL(string: value)
    }

    func setProtectionEnabled(_ enabled: Bool) {
        guard protectionEnabled != enabled else { return }
        if enabled, !subscription.isEntitled {
            showPaywall = true
            return
        }
        resumeTask?.cancel()
        pausedUntil = nil
        defaults.removeObject(forKey: "pausedUntil")
        protectionEnabled = enabled
        defaults.set(enabled, forKey: "protectionEnabled")

        if enabled {
            let restored = defaults.stringArray(forKey: "pausedSourceIDs")
            enabledSourceIDs = Set(restored ?? FilterCatalog.all.filter(\.enabledByDefault).map(\.id))
            defaults.set(Array(enabledSourceIDs).sorted(), forKey: "enabledSourceIDs")
            updateFilters()
        } else {
            defaults.set(Array(enabledSourceIDs).sorted(), forKey: "pausedSourceIDs")
            for slice in 0..<SharedStorage.maximumContentBlockerSliceCount {
                try? storage.write(Data("[]".utf8), to: storage.contentBlockerRulesURL(slice: slice))
            }
            try? storage.write(Data("[]".utf8), to: storage.webExtensionRulesURL)
            try? storage.write(Data(#"{"rules":[],"exemptDomains":[],"unsupportedRuleCount":0}"#.utf8), to: storage.webExtensionCosmeticRulesURL)
            try? storage.write(Data(), to: storage.hostsDomainsURL)
            storage.invalidateCompiledFingerprint()
            statistics = .empty
            reloadSafariContentBlocker()
            Task {
                try? await hostsClient.removeManagedSection()
                hostsEnabled = false
                installedHostDomainCount = 0
                statusMessage = L("Ochrona jest wyłączona")
            }
        }
    }

    /// Wyłącza ochronę na określony czas i sama ją wznawia.
    func pauseProtection(for interval: TimeInterval) {
        guard protectionEnabled else { return }
        setProtectionEnabled(false)
        let until = Date().addingTimeInterval(interval)
        pausedUntil = until
        defaults.set(until, forKey: "pausedUntil")
        scheduleResume()
    }

    func pauseProtectionUntilTomorrow() {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) ?? Date().addingTimeInterval(86_400)
        pauseProtection(for: max(60, tomorrow.timeIntervalSinceNow))
    }

    func resumeProtection() {
        setProtectionEnabled(true)
    }

    private func scheduleResume() {
        resumeTask?.cancel()
        guard let until = pausedUntil else { return }
        resumeTask = Task { @MainActor [weak self] in
            let delay = until.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, self.pausedUntil != nil else { return }
            self.resumeProtection()
        }
    }

    /// Data wygaśnięcia profilu podpisu (konto Personal Team ważne 7 dni); nil, gdy aplikacja nie ma wbudowanego profilu.
    var signingExpiry: Date? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile")
        guard let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }

    private func checkSigningExpiry() {
        guard let expiry = signingExpiry, expiry.timeIntervalSinceNow < 2 * 86_400 else { return }
        let today = Calendar.current.startOfDay(for: Date())
        guard (defaults.object(forKey: "signingExpiryNotifiedDay") as? Date) != today else { return }
        defaults.set(today, forKey: "signingExpiryNotifiedDay")
        let expired = expiry < Date()
        Task.detached {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = L("Podpis MacAdBlock wkrótce wygaśnie")
            content.body = expired
                ? L("Podpis wygasł. Zbuduj aplikację ponownie w Xcode, aby rozszerzenia Safari znów działały.")
                : L("Zbuduj aplikację ponownie w Xcode w ciągu 2 dni, aby rozszerzenia Safari nie przestały działać.")
            try? await center.add(UNNotificationRequest(identifier: "macadblock.signing.expiry", content: content, trigger: nil))
        }
    }

    func setAutoUpdateInterval(hours: Int) {
        autoUpdateIntervalHours = hours
        defaults.set(hours, forKey: "autoUpdateIntervalHours")
        scheduleAutomaticUpdates()
    }

    func setAppearance(_ appearance: AppAppearance) {
        self.appearance = appearance
        defaults.set(appearance.rawValue, forKey: "appearance")
    }

    private func scheduleAutomaticUpdates() {
        autoUpdateTask?.cancel()
        guard autoUpdateIntervalHours > 0 else { return }
        let interval = UInt64(autoUpdateIntervalHours) * 3_600_000_000_000
        autoUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                self?.updateFilters()
            }
        }
    }

    func completeOnboarding(
        profile: ProtectionProfile,
        countryCodes: Set<String>,
        includeHosts: Bool,
        includeAnnoyances: Bool,
        includeSocial: Bool
    ) {
        var selected = Set(["easylist", "easyprivacy"])

        for source in sources where !source.isExtra && countryCodes.contains(source.countryCode) && (includeHosts || source.format == .adblock) {
            selected.insert(source.id)
        }

        if includeHosts {
            selected.insert(profile == .maximum ? "hagezi-pro" : "stevenblack")
            if profile != .light { selected.insert("adaway") }
        }
        if includeAnnoyances { selected.insert("fanboy-annoyance") }
        if includeSocial { selected.insert("fanboy-social") }

        if profile == .maximum {
            for source in sources where !source.isExtra && source.countryCode == "INT" && (includeHosts || source.format == .adblock) {
                if source.category != .social || includeSocial { selected.insert(source.id) }
                if source.category != .annoyances || includeAnnoyances { selected.insert(source.id) }
            }
        }

        enabledSourceIDs = selected
        defaults.set(Array(selected).sorted(), forKey: "enabledSourceIDs")
        defaults.set(true, forKey: "didCompleteOnboarding")
        showOnboarding = false
        updateFilters()
    }

    func updateFilters() {
        guard protectionEnabled else {
            statusMessage = L("Ochrona jest wyłączona — włącz ją, aby aktualizować listy")
            return
        }
        guard !isUpdating else { return }
        isUpdating = true
        lastError = nil
        statusMessage = L("Pobieranie i kompilowanie list…")
        let selectedSources = sources.filter { enabledSourceIDs.contains($0.id) }
        Task {
            do {
                let result = try await updater.update(sources: selectedSources, userSettings: userSettings)
                statistics = result.statistics
                statusMessage = result.failures.isEmpty ? L("Listy są aktualne") : L("Zaktualizowano z \(result.failures.count) błędami")
                if !result.failures.isEmpty {
                    lastError = result.failures.map { "\($0.source.name): \($0.message)" }.joined(separator: "\n")
                }
                consecutiveUpdateFailures = 0
                contentBlockerRetryCount = 0
                reloadSafariContentBlocker()
                prepareHostsHelper()
                if automaticallyApplyHosts && helperStatus == .enabled && result.statistics.hostDomainCount > 0 {
                    try await installHostsFromCache()
                    hostsEnabled = true
                    installedHostDomainCount = result.statistics.hostDomainCount
                    helperOperational = true
                    statusMessage = L("Listy i ochrona hosts są aktualne")
                }
            } catch {
                statusMessage = L("Aktualizacja nie powiodła się")
                lastError = error.localizedDescription
                consecutiveUpdateFailures += 1
                notifyRepeatedUpdateFailures(message: error.localizedDescription)
            }
            isUpdating = false
            if pendingRecompile {
                pendingRecompile = false
                updateFilters()
            }
        }
    }

    /// Po trzech nieudanych próbach z rzędu ochrona działa na starych regułach — wtedy warto
    /// powiadomić użytkownika, bo aplikacja zwykle pracuje z zamkniętym oknem.
    private func notifyRepeatedUpdateFailures(message: String) {
        guard consecutiveUpdateFailures == 3 else { return }
        let body = L("Trzy kolejne próby nie powiodły się. Ochrona działa na wcześniej pobranych regułach. \(message)")
        Task.detached {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = L("MacAdBlock nie może zaktualizować list")
            content.body = body
            try? await center.add(
                UNNotificationRequest(identifier: "macadblock.update.failure", content: content, trigger: nil)
            )
        }
    }

    var hostsDomainsToApply: Int {
        hostsDomainLimit > 0 ? min(hostsDomainLimit, statistics.hostDomainCount) : statistics.hostDomainCount
    }

    func applyHosts() {
        guard canManageHosts else {
            lastError = helperMessage ?? L("Ochrona hosts wymaga uruchomienia MacAdBlock z folderu Aplikacje i aktywnego helpera.")
            return
        }
        Task {
            do {
                try await installHostsFromCache()
                hostsEnabled = true
                installedHostDomainCount = statistics.hostDomainCount
                helperOperational = true
                statusMessage = L("Ochrona hosts jest aktywna")
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func flushDNSCache() {
        Task {
            do {
                try await hostsClient.flushDNSCache()
                statusMessage = L("Pamięć podręczna DNS została odświeżona")
            } catch {
                // Anulowanie okna hasła (-128) nie jest błędem.
                if error.localizedDescription.contains("(-128)") { return }
                lastError = L("Nie udało się odświeżyć DNS: \(error.localizedDescription)")
            }
        }
    }

    func removeHosts() {
        guard canManageHosts else {
            lastError = helperMessage ?? L("Usunięcie sekcji hosts wymaga uruchomienia MacAdBlock z folderu Aplikacje i aktywnego helpera.")
            return
        }
        Task {
            do {
                try await hostsClient.removeManagedSection()
                hostsEnabled = false
                installedHostDomainCount = 0
                helperOperational = true
                statusMessage = L("Sekcja hosts została usunięta")
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func prepareHostsHelper(openApprovalSettings: Bool = false) {
        helperStatus = hostsClient.serviceStatus

        if let readinessMessage = systemIntegrationReadiness {
            helperOperational = false
            helperMessage = readinessMessage
            if openApprovalSettings {
                lastError = L("Helper hosts nie może zostać uruchomiony. \(readinessMessage)")
            }
            return
        }

        if helperStatus == .notRegistered {
            do {
                try hostsClient.register()
                helperStatus = hostsClient.serviceStatus
            } catch {
                // SMAppService odmawia rejestracji demona (typowe na koncie Personal Team bez Developer ID).
                // Zamiast pokazywać ślepy błąd, przełączamy się trwale na sprawdzony tryb lokalny (hasło
                // administratora raz, potem XPC bez pytania).
                hostsClient.markRegistrationFailed()
                helperStatus = hostsClient.serviceStatus
            }
        }

        if helperStatus != .enabled {
            helperOperational = false
        }

        switch helperStatus {
        case .enabled:
            if hostsClient.usesAuthorizationFallback && openApprovalSettings {
                hostsClient.installDaemonIfNeeded()
            }
            helperMessage = hostsClient.usesAuthorizationFallback && !hostsClient.installedDaemonIsCurrent
                ? L("Tryb lokalny jest gotowy. Przy zmianie /etc/hosts macOS poprosi o hasło administratora.")
                : L("Helper jest gotowy. Sekcja hosts będzie odświeżana razem z filtrami.")
            refreshHostsStatus()
        case .requiresApproval:
            helperMessage = L("macOS wymaga jednorazowego zatwierdzenia helpera w Rzeczach logowania.")
            if openApprovalSettings { SMAppService.openSystemSettingsLoginItems() }
        case .notFound:
            let bundle = Bundle.main.bundleURL
            let plistPath = bundle.appendingPathComponent("Contents/Library/LaunchDaemons/\(HostsHelperConstants.daemonPlistName)").path
            let helperPath = bundle.appendingPathComponent("Contents/Resources/\(HostsHelperConstants.machServiceName)").path
            let plistFound = FileManager.default.fileExists(atPath: plistPath)
            let helperFound = FileManager.default.isExecutableFile(atPath: helperPath)
            helperMessage = L("Helper nie został znaleziony w pakiecie aplikacji.")
                + " [plist: \(plistFound ? "jest" : "brak"), helper: \(helperFound ? "jest" : "brak"), \(bundle.path)]"
        case .notRegistered:
            helperMessage = L("Helper nie jest jeszcze zarejestrowany.")
        @unknown default:
            helperMessage = L("Nieznany stan helpera.")
        }
    }

    func repairHostsHelper() {
        guard systemIntegrationReadiness == nil else {
            prepareHostsHelper(openApprovalSettings: true)
            return
        }

        do {
            try hostsClient.repairRegistration()
            helperStatus = hostsClient.serviceStatus
            helperMessage = hostsClient.usesAuthorizationFallback
                ? L("Tryb lokalny jest gotowy. Przy zmianie /etc/hosts macOS poprosi o hasło administratora.")
                : helperStatus == .requiresApproval
                    ? L("macOS wymaga ponownego zatwierdzenia helpera w Rzeczach logowania.")
                    : L("Helper został ponownie zarejestrowany.")
            if helperStatus == .requiresApproval {
                hostsClient.openApprovalSettings()
            } else {
                refreshHostsStatus()
            }
        } catch {
            helperOperational = false
            lastError = L("Nie udało się naprawić helpera: \(error.localizedDescription)")
        }
    }

    func refreshSafariStatus(openSettingsIfNeeded: Bool = false) {
        if openSettingsIfNeeded {
            automaticSafariSetupRequested = true
        }

        MABSafariServicesBridge.getContentBlockerState(AppIdentifiers.contentBlocker) { [weak self] enabled in
            Task { @MainActor in
                self?.contentBlockerEnabled = enabled
                self?.finishSafariStatusRefresh()
            }
        }

        MABSafariServicesBridge.getWebExtensionState(AppIdentifiers.webExtension) { [weak self] enabled in
            Task { @MainActor in
                self?.webExtensionEnabled = enabled
                self?.finishSafariStatusRefresh()
            }
        }
    }

    func openSafariExtensionSettings(automatic: Bool = false) {
        if let readinessMessage = safariIntegrationReadiness {
            if !automatic { lastError = L("Rozszerzenia Safari nie są jeszcze gotowe. \(readinessMessage)") }
            return
        }

        let preferredExtension = webExtensionEnabled == true && contentBlockerEnabled != true
            ? AppIdentifiers.contentBlocker
            : AppIdentifiers.webExtension

        MABSafariServicesBridge.showPreferences(forExtension: preferredExtension) { [weak self] succeeded in
            Task { @MainActor in
                self?.watchSafariExtensionActivation()
                guard !succeeded else {
                    self?.refreshSafariStatus()
                    return
                }

                MABSafariServicesBridge.showPreferences(forExtension: AppIdentifiers.contentBlocker) { [weak self] fallbackSucceeded in
                    Task { @MainActor in
                        if !fallbackSucceeded {
                            NSWorkspace.shared.openApplication(
                                at: URL(fileURLWithPath: "/Applications/Safari.app"),
                                configuration: NSWorkspace.OpenConfiguration()
                            )
                            if !automatic { self?.lastError = self?.safariExtensionSetupMessage }
                        }
                        self?.refreshSafariStatus()
                    }
                }
            }
        }
    }

    private func finishSafariStatusRefresh() {
        guard let safariProtectionEnabled else { return }
        if safariProtectionEnabled {
            if !isUpdating { statusMessage = L("Rozszerzenia Safari działają") }
            automaticSafariSetupRequested = false
            return
        }

        if !isUpdating { statusMessage = safariExtensionStatus }
        guard automaticSafariSetupRequested else { return }
        automaticSafariSetupRequested = false
        guard safariIntegrationReadiness == nil else { return }

        // Apple nie pozwala aplikacji włączyć rozszerzeń samodzielnie — wymagana jest zgoda użytkownika.
        // Dlatego przy każdym uruchomieniu, dopóki któreś rozszerzenie jest wyłączone, otwieramy
        // od razu jego panel w Safari (bez szukania go w menu).
        // Tylko raz na wersję aplikacji — bez modalnego alertu przy każdym starcie.
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        guard UserDefaults.standard.string(forKey: "safariSetupPromptedBuild") != build else { return }
        UserDefaults.standard.set(build, forKey: "safariSetupPromptedBuild")
        openSafariExtensionSettings(automatic: true)
    }

    /// Po otwarciu ustawień Safari co kilka sekund sprawdza stan rozszerzeń: gdy użytkownik włączy jedno,
    /// otwiera panel drugiego, a gdy oba działają — przeładowuje Content Blocker i kończy.
    private func watchSafariExtensionActivation() {
        safariSetupWatchTask?.cancel()
        safariSetupWatchTask = Task { [weak self] in
            var previousCount = self?.enabledSafariExtensionCount ?? 0
            for _ in 0..<90 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.refreshSafariStatus()
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                let count = self.enabledSafariExtensionCount
                if count == 2 {
                    self.reloadSafariContentBlocker()
                    return
                }
                if count > previousCount {
                    self.openSafariExtensionSettings()
                    return
                }
                previousCount = count
            }
        }
    }

    private var enabledSafariExtensionCount: Int {
        [contentBlockerEnabled, webExtensionEnabled].filter { $0 == true }.count
    }

    private var isInstalledInSystemApplications: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix("/Applications/")
    }

    private var systemIntegrationReadiness: String? {
        guard isInstalledInSystemApplications else {
            return L("Przenieś MacAdBlock do systemowego folderu Aplikacje (/Applications) i uruchom tę kopię.")
        }
        guard hasValidApplicationSignature else {
            return L("Podpis tej kopii MacAdBlock jest nieważny lub niezaufany. W Xcode wybierz swój Team w Signing & Capabilities, przebuduj aplikację i zainstaluj ją ponownie.")
        }
        guard FileManager.default.fileExists(atPath: embeddedHelperURL.path) else {
            return L("W pakiecie aplikacji brakuje helpera hosts. Zbuduj cały schemat MacAdBlock, nie sam target aplikacji.")
        }
        return nil
    }

    private var safariIntegrationReadiness: String? {
        if let readinessMessage = systemIntegrationReadiness { return readinessMessage }
        guard FileManager.default.fileExists(atPath: embeddedContentBlockerURL.path),
              FileManager.default.fileExists(atPath: embeddedWebExtensionURL.path) else {
            return L("W pakiecie brakuje rozszerzeń Safari. Zbuduj cały schemat MacAdBlock i zainstaluj aplikację ponownie.")
        }
        guard applicationTeamIdentifier != nil else {
            return L("Ta kopia jest podpisana lokalnie bez Apple Team ID, dlatego Safari ukrywa oba rozszerzenia. Zaloguj Apple ID w Xcode i podpisz targety MacAdBlock, SafariBlocker oraz SafariWebExtension tym samym Teamem. Do krótkiego testu możesz też włączyć w Safari opcję Programowanie → Zezwalaj na niepodpisane rozszerzenia; Safari wyłącza ją po każdym zamknięciu.")
        }
        return nil
    }

    private var hasValidApplicationSignature: Bool {
        var staticCode: SecStaticCode?
        let creationStatus = SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode)
        guard creationStatus == errSecSuccess, let staticCode else { return false }
        let flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
        )
        return SecStaticCodeCheckValidity(staticCode, flags, nil) == errSecSuccess
    }

    private var applicationTeamIdentifier: String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
              let signingInformation else {
            return nil
        }

        let information = signingInformation as NSDictionary
        guard let teamIdentifier = information[kSecCodeInfoTeamIdentifier] as? String,
              !teamIdentifier.isEmpty else {
            return nil
        }
        return teamIdentifier
    }

    private var embeddedHelperURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
            .appendingPathComponent(HostsHelperConstants.machServiceName)
    }

    private var embeddedContentBlockerURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/PlugIns", isDirectory: true)
            .appendingPathComponent("SafariBlocker.appex", isDirectory: true)
    }

    private var embeddedWebExtensionURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/PlugIns", isDirectory: true)
            .appendingPathComponent("SafariWebExtension.appex", isDirectory: true)
    }

    private var safariExtensionSetupMessage: String {
        if !isInstalledInSystemApplications {
            return L("Safari nie może zarejestrować rozszerzeń z tej lokalizacji. Przenieś MacAdBlock do systemowego folderu Aplikacje (/Applications), uruchom go ponownie, a następnie w Safari wybierz Ustawienia → Rozszerzenia.")
        }
        if applicationTeamIdentifier == nil {
            return L("Rozszerzenia są w aplikacji, ale Safari ich nie pokazuje, ponieważ ta kopia nie ma podpisu Apple Team ID. Zaloguj Apple ID w Xcode i podpisz MacAdBlock oraz oba rozszerzenia tym samym Teamem. Safari nie pozwala aplikacji samodzielnie ominąć tego zabezpieczenia ani włączyć rozszerzeń bez Twojej zgody.")
        }
        return L("Safari nie odnalazło rozszerzeń MacAdBlock. Otwórz Safari → Ustawienia → Rozszerzenia i zaznacz MacAdBlock Content Blocker oraz MacAdBlock Web Extension. Apple wymaga tej jednorazowej zgody użytkownika. Jeśli rozszerzeń nie ma, uruchom ponownie MacAdBlock z folderu Aplikacje.")
    }

    private func reloadSafariContentBlocker() {
        guard safariIntegrationReadiness == nil else {
            contentBlockerEnabled = false
            statusMessage = L("Listy gotowe — dokończ konfigurację podpisu i rozszerzeń Safari")
            return
        }

        // Kolejne listy ładują się niezależnie; ich błędy nie mogą zatrzymać obsługi pierwszej.
        for identifier in AppIdentifiers.contentBlockers.dropFirst() {
            MABSafariServicesBridge.reloadContentBlocker(identifier) { _, _ in }
        }

        MABSafariServicesBridge.reloadContentBlocker(AppIdentifiers.contentBlocker) { [weak self] errorDomain, errorMessage in
            Task { @MainActor in
                guard let self else { return }
                if let errorDomain {
                    // Ta sama domena błędu oznacza i wyłączone rozszerzenie, i odrzuconą listę.
                    // Gdy rozszerzenie jest włączone, przyczyną jest zwykle przekroczony limit reguł.
                    if errorDomain == "SFErrorDomain", self.contentBlockerEnabled == true, self.reduceContentBlockerBudget() {
                        self.statusMessage = L("Safari odrzuciło listę — zmniejszam limit do \(self.contentBlockerRuleBudget.formatted()) reguł")
                    } else if errorDomain == "SFErrorDomain" {
                        self.statusMessage = L("Listy zaktualizowane — włącz rozszerzenia MacAdBlock w Safari")
                        self.contentBlockerEnabled = false
                    } else {
                        self.lastError = L("Safari nie przeładowało reguł. \(errorMessage ?? "Nieznany błąd")")
                    }
                } else {
                    self.statusMessage = L("Reguły Safari zostały przeładowane")
                    self.contentBlockerRetryCount = 0
                    self.recoverContentBlockerBudgetIfNeeded()
                }
                self.refreshSafariStatus()
            }
        }
    }

    private func installHostsFromCache() async throws {
        let text = try String(contentsOf: storage.hostsDomainsURL, encoding: .utf8)
        var domains = text.split(whereSeparator: \Character.isNewline).map(String.init)
        if hostsDomainLimit > 0 { domains = Array(domains.prefix(hostsDomainLimit)) }
        try await hostsClient.apply(domains: domains)
    }

    private func refreshHostsStatus() {
        Task {
            do {
                let status = try await hostsClient.status()
                hostsEnabled = status.enabled
                installedHostDomainCount = status.count
                helperOperational = true
            } catch {
                helperOperational = false
                installedHostDomainCount = 0
                helperMessage = L("Nie udało się odczytać stanu helpera: \(error.localizedDescription)")
            }
        }
    }
}

/// Kopia ustawień do przeniesienia na inny komputer. Nieznane identyfikatory list są pomijane przy wczytywaniu.
struct MacAdBlockConfiguration: Codable {
    var enabledSourceIDs: [String]
    var userSettings: UserFilterSettings
    var protectionEnabled: Bool
    var automaticallyApplyHosts: Bool
    var autoUpdateIntervalHours: Int
    var appearance: String
    var contentBlockerRuleBudget: Int
}

struct ApplicationNotice: Identifiable {
    enum Kind {
        case openInstalled
        case installCurrent
        case downloadUpdate(ApplicationRelease)
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let message: String
    let actionTitle: String
}

enum ProtectionProfile: String, CaseIterable, Identifiable {
    case light
    case balanced
    case maximum

    var id: String { rawValue }
    var title: String {
        switch self {
        case .light: L("Lekka")
        case .balanced: L("Zalecana")
        case .maximum: L("Maksymalna")
        }
    }
    var subtitle: String {
        switch self {
        case .light: L("Podstawowe reklamy i śledzenie")
        case .balanced: L("Reklamy, prywatność i bezpieczne hosts")
        case .maximum: L("Najwięcej list; może wymagać wyjątków")
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case automatic
    case light
    case dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: L("Automatyczny")
        case .light: L("Jasny")
        case .dark: L("Ciemny")
        }
    }
    var icon: String {
        switch self {
        case .automatic: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppIdentifiers {
    /// Cała pula Content Blockerów Safari wbudowanych w aplikację (pierwszy — bez numeru w nazwie —
    /// aż do ósmego). Safari liczy limit reguł osobno dla każdego rozszerzenia, więc trzymamy zapas
    /// uśpionych blokerów: SafariRuleCompiler sam decyduje, ilu z nich faktycznie użyć, więc kolejne
    /// listy filtrów "odpalają" kolejne blokery automatycznie, bez zmian w kodzie — aż do wyczerpania
    /// tej puli (wtedy trzeba dodać kolejny target w Xcode).
    static let contentBlockers: [String] = (0..<SharedStorage.maximumContentBlockerSliceCount).map { index in
        index == 0
            ? "com.italiano88.MacAdBlock.SafariBlocker"
            : "com.italiano88.MacAdBlock.SafariBlocker\(index + 1)"
    }
    static var contentBlocker: String { contentBlockers[0] }
    static let webExtension = "com.italiano88.MacAdBlock.SafariWebExtension"
}
