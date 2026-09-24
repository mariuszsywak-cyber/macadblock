import Foundation
import SwiftUI

/// Stan i operacje firewalla: reguły pf zarządzane przez helpera oraz przełączniki wbudowanego firewalla macOS.
@MainActor
final class FirewallController: ObservableObject {
    @Published var config: FirewallConfig {
        didSet { save() }
    }
    @Published private(set) var appliedConfig: FirewallConfig
    @Published private(set) var isBusy = false
    @Published var message: String?
    @Published var errorMessage: String?
    @Published private(set) var pfActive = false
    @Published private(set) var activeRuleCount = 0
    @Published private(set) var statusKnown = false
    @Published private(set) var nativeEnabled: Bool?
    @Published private(set) var nativeStealth: Bool?
    /// Koniec czasu na potwierdzenie ustawień; po jego upływie firewall wraca do wyłączonego.
    @Published private(set) var confirmationDeadline: Date?

    private let client = HostsHelperClient()
    private let defaults = UserDefaults.standard
    private var confirmationTask: Task<Void, Never>?
    static let confirmationSeconds: TimeInterval = 20

    init() {
        let stored = defaults.data(forKey: "firewallConfig").flatMap { try? JSONDecoder().decode(FirewallConfig.self, from: $0) }
        let initial = stored ?? .disabled
        config = initial
        appliedConfig = initial
        Task {
            // Rozgrzewamy cache stanu helpera poza głównym wątkiem, zanim ktokolwiek wejdzie w ekran
            // Firewall — bez tego porównanie buildów helpera blokowało UI przy każdym onAppear.
            await client.prefetchDaemonStatus()
            await refreshStatus()
        }
        refreshNativeStatus()
    }

    var hasUnappliedChanges: Bool { config.enabled && config != appliedConfig }

    var statusText: String {
        if !config.enabled { return L("Wyłączony") }
        if statusKnown { return pfActive ? L("Aktywny · \(activeRuleCount) reguł") : L("Włączony, ale reguły nie są wczytane") }
        return L("Włączony")
    }

    // MARK: - Reguły

    func addRule(_ rule: FirewallRule) -> String? {
        guard PFRulesetBuilder.normalizedRemote(rule.remote) != nil else {
            return L("Nieprawidłowy adres lub domena.")
        }
        guard PFRulesetBuilder.normalizedPort(rule.port) != nil else {
            return L("Nieprawidłowy port. Wpisz np. 443 albo 8000:8100.")
        }
        var normalized = rule
        normalized.remote = PFRulesetBuilder.normalizedRemote(rule.remote).map { $0 == "any" ? "" : $0 } ?? ""
        normalized.port = PFRulesetBuilder.normalizedPort(rule.port) ?? ""
        guard config.rules.count < PFRulesetBuilder.maximumRules else {
            return L("Osiągnięto limit reguł.")
        }
        config.rules.append(normalized)
        return nil
    }

    func removeRule(_ rule: FirewallRule) {
        config.rules.removeAll { $0.id == rule.id }
    }

    func toggleRule(_ rule: FirewallRule) {
        guard let index = config.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        config.rules[index].enabled.toggle()
    }

    // MARK: - Zastosowanie

    func setEnabled(_ enabled: Bool) {
        guard config.enabled != enabled else { return }
        config.enabled = enabled
        apply(startConfirmation: enabled)
    }

    func applyChanges() {
        apply(startConfirmation: true)
    }

    private var isRisky: Bool {
        config.lockdown || config.blockInbound || config.rules.contains { $0.enabled && $0.action == .block }
    }

    private func apply(startConfirmation: Bool) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        let target = config
        Task {
            defer { isBusy = false }
            do {
                try await client.applyFirewall(target)
                appliedConfig = target
                message = target.enabled ? L("Firewall został zastosowany.") : L("Firewall został wyłączony.")
                if target.enabled, startConfirmation, isRisky { beginConfirmation() } else { cancelConfirmation() }
            } catch {
                // Anulowanie okna hasła nie jest błędem. Reguły użytkownika zostają, cofamy tylko przełącznik.
                if !error.localizedDescription.contains("(-128)") { errorMessage = error.localizedDescription }
                config.enabled = appliedConfig.enabled
            }
            await refreshStatus()
        }
    }

    /// Po starcie aplikacji przywraca reguły (pf nie przetrwa restartu), ale tylko gdy helper nie zapyta o hasło.
    func reapplyAtLaunchIfPossible() {
        guard config.enabled, client.canRunWithoutPrompt else { return }
        let target = config
        Task {
            try? await client.applyFirewall(target)
            appliedConfig = target
            await refreshStatus()
        }
    }

    // MARK: - Potwierdzenie (zabezpieczenie przed odcięciem od sieci)

    private func beginConfirmation() {
        confirmationTask?.cancel()
        let deadline = Date().addingTimeInterval(Self.confirmationSeconds)
        confirmationDeadline = deadline
        confirmationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.confirmationSeconds))
            guard !Task.isCancelled, let self, self.confirmationDeadline == deadline else { return }
            self.confirmationDeadline = nil
            self.message = L("Nie potwierdzono ustawień — firewall został wyłączony.")
            self.config.enabled = false
            self.apply(startConfirmation: false)
        }
    }

    func confirmSettings() {
        cancelConfirmation()
        message = L("Ustawienia firewalla zostały zachowane.")
    }

    private func cancelConfirmation() {
        confirmationTask?.cancel()
        confirmationTask = nil
        confirmationDeadline = nil
    }

    // MARK: - Stan

    func refreshStatus() async {
        if let status = await client.firewallStatus() {
            pfActive = status.active
            activeRuleCount = status.rules
            statusKnown = true
        } else {
            statusKnown = false
        }
    }

    func refreshNativeStatus() {
        Task {
            let result = await Task.detached(priority: .utility) { () -> (Bool?, Bool?) in
                (Self.run(["--getglobalstate"]).map { $0.contains("enabled") },
                 Self.run(["--getstealthmode"]).map { $0.contains("enabled") })
            }.value
            nativeEnabled = result.0
            nativeStealth = result.1
        }
    }

    func setNative(enabled: Bool, stealth: Bool) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        Task {
            defer { isBusy = false }
            do {
                try await client.setNativeFirewall(enabled: enabled, stealth: stealth)
                message = L("Zmieniono ustawienia firewalla macOS.")
            } catch {
                if !error.localizedDescription.contains("(-128)") { errorMessage = error.localizedDescription }
            }
            refreshNativeStatus()
        }
    }

    private nonisolated static func run(_ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/ApplicationFirewall/socketfilterfw")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).lowercased()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: "firewallConfig")
        }
    }
}
