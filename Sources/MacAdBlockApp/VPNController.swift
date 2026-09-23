import Foundation
import NetworkExtension
import Security

enum VPNProvider: String, CaseIterable, Identifiable {
    case custom
    case surfshark
    case hideMe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .custom: L("Własny IKEv2")
        case .surfshark: "Surfshark"
        case .hideMe: "hide.me"
        }
    }

    var serverPlaceholder: String {
        switch self {
        case .custom: L("Adres serwera, np. vpn.example.com")
        case .surfshark: L("Hostname lokalizacji z konta Surfshark")
        case .hideMe: L("Serwer z panelu hide.me, np. nl.hide.me")
        }
    }

    var guidance: String {
        switch self {
        case .custom:
            L("Użyj danych administratora własnego serwera IKEv2. Serwer musi obsługiwać uwierzytelnianie EAP nazwą użytkownika i hasłem.")
        case .surfshark:
            L("Wybierz gotową lokalizację poniżej. Surfshark nadal wymaga osobnych danych ręcznej konfiguracji IKEv2 oraz własnego certyfikatu; wpisujesz je tylko przy pierwszym zapisie.")
        case .hideMe:
            L("Wybierz gotową lokalizację poniżej. Dane konta IKEv2 wpisujesz tylko przy pierwszym zapisie, a identyfikator zdalny zostanie ustawiony automatycznie.")
        }
    }

    var setupURL: URL? {
        switch self {
        case .custom: nil
        case .surfshark: URL(string: "https://support.surfshark.com/hc/en-us/articles/360006636013-How-to-set-up-IKEv2-manual-connection-on-macOS")
        case .hideMe: URL(string: "https://hide.me/en/help/setup-macos-ikev2/")
        }
    }

    var serverPresets: [VPNServerPreset] {
        switch self {
        case .custom:
            []
        case .surfshark:
            [
                VPNServerPreset(
                    provider: self,
                    location: L("Francja — Bordeaux"),
                    flag: "🇫🇷",
                    serverAddress: "fr-bod.prod.surfshark.com",
                    access: L("Konto Surfshark")
                )
            ]
        case .hideMe:
            [
                VPNServerPreset(
                    provider: self,
                    location: L("Niderlandy — bezpłatny"),
                    flag: "🇳🇱",
                    serverAddress: "free-nl.hide.me",
                    access: L("Konto bezpłatne")
                ),
                VPNServerPreset(
                    provider: self,
                    location: "Niderlandy",
                    flag: "🇳🇱",
                    serverAddress: "nl.hide.me",
                    access: L("Konto Premium")
                ),
                VPNServerPreset(
                    provider: self,
                    location: L("USA — serwer 1"),
                    flag: "🇺🇸",
                    serverAddress: "us-1.hide.me",
                    access: L("Konto Premium")
                )
            ]
        }
    }

    func remoteIdentifier(for serverAddress: String) -> String? {
        switch self {
        case .custom: nil
        case .surfshark: serverAddress
        case .hideMe: "hide.me"
        }
    }
}

struct VPNServerPreset: Identifiable, Hashable {
    let provider: VPNProvider
    let location: String
    let flag: String
    let serverAddress: String
    let access: String

    var id: String { "\(provider.rawValue):\(serverAddress)" }
    var title: String { "\(flag) \(location)" }
}

enum VPNSecurityProfile: String, CaseIterable, Identifiable {
    case compatible
    case modern
    case hardened

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compatible: L("Zgodny")
        case .modern: L("Nowoczesny")
        case .hardened: L("Wzmocniony")
        }
    }

    var details: String {
        switch self {
        case .compatible: L("Ustawienia systemowe Apple — najlepsza zgodność z operatorami.")
        case .modern: L("AES-256-GCM, SHA-384 i grupa DH 20. Zalecany dla własnego serwera.")
        case .hardened: L("AES-256-GCM, SHA-512 i grupa DH 21. Może nie działać ze starszym serwerem.")
        }
    }
}

enum VPNOnDemandPolicy: String, CaseIterable, Identifiable {
    case off
    case everyNetwork
    case untrustedWiFi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: L("Ręcznie")
        case .everyNetwork: L("Każda sieć")
        case .untrustedWiFi: L("Poza zaufanym Wi‑Fi")
        }
    }
}

enum VPNConfigurationError: LocalizedError {
    case incompleteConfiguration
    case invalidServerAddress
    case invalidRemoteIdentifier
    case passwordRequired
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .incompleteConfiguration:
            L("Wpisz adres serwera, identyfikator zdalny i nazwę użytkownika.")
        case .invalidServerAddress:
            L("Wpisz poprawny hostname lub adres IP serwera, bez protokołu, ścieżki, portu i spacji.")
        case .invalidRemoteIdentifier:
            L("Identyfikator zdalny nie może zawierać protokołu, ścieżki ani spacji.")
        case .passwordRequired:
            L("Wpisz hasło do serwera VPN.")
        case .keychain(let status):
            L("Pęk kluczy odrzucił operację (kod \(status)).")
        }
    }
}

@MainActor
final class VPNController: NSObject, ObservableObject {
    static let manualServerID = "manual-server"

    @Published var provider: VPNProvider = .custom
    @Published private(set) var selectedServerID = ""
    @Published var serverAddress = ""
    @Published var remoteIdentifier = ""
    @Published var username = ""
    @Published var onDemandPolicy: VPNOnDemandPolicy = .off
    @Published var trustedWiFiSSIDs = ""
    @Published var fullTunnel = true
    @Published var allowLocalNetworks = true
    @Published var disconnectOnSleep = false
    @Published var preventServerRedirects = true
    @Published var securityProfile: VPNSecurityProfile = .compatible
    @Published private(set) var isConfigured = false
    @Published private(set) var status = L("Nieskonfigurowany")
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastDisconnectReason: String?
    @Published private(set) var connectedSince: Date?

    private let manager = NEVPNManager.shared()

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vpnStatusDidChange),
            name: .NEVPNStatusDidChange,
            object: manager.connection
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var isConnected: Bool {
        manager.connection.status == .connected || manager.connection.status == .connecting || manager.connection.status == .reasserting
    }

    var isBusy: Bool {
        manager.connection.status == .connecting || manager.connection.status == .disconnecting || manager.connection.status == .reasserting
    }

    var isRemoteIdentifierManaged: Bool { provider != .custom }
    var connectOnDemand: Bool { onDemandPolicy != .off }
    var availableServers: [VPNServerPreset] { provider.serverPresets }
    var usesManualServerAddress: Bool { provider == .custom || selectedServerID == Self.manualServerID }

    var selectedServerPreset: VPNServerPreset? {
        availableServers.first { $0.id == selectedServerID }
    }

    var trustedNetworkCount: Int {
        Self.parseSSIDs(trustedWiFiSSIDs).count
    }

    func selectProvider(_ selectedProvider: VPNProvider) {
        provider = selectedProvider
        if selectedProvider != .custom, securityProfile != .compatible {
            securityProfile = .compatible
        }
        if let existingPreset = selectedProvider.serverPresets.first(where: {
            $0.serverAddress.caseInsensitiveCompare(serverAddress) == .orderedSame
        }) {
            selectServer(existingPreset.id)
        } else if let recommendedPreset = selectedProvider.serverPresets.first {
            selectServer(recommendedPreset.id)
        } else {
            selectedServerID = ""
            applyProviderDefaults()
        }
        errorMessage = nil
    }

    func selectServer(_ serverID: String) {
        selectedServerID = serverID
        guard let preset = availableServers.first(where: { $0.id == serverID }) else {
            if serverID == Self.manualServerID,
               availableServers.contains(where: { $0.serverAddress.caseInsensitiveCompare(serverAddress) == .orderedSame }) {
                serverAddress = ""
            }
            applyProviderDefaults()
            return
        }
        serverAddress = preset.serverAddress
        applyProviderDefaults()
        errorMessage = nil
    }

    func serverAddressDidChange() {
        applyProviderDefaults()
    }

    func load() async {
        do {
            try await loadPreferences()
            hydrateFromManager()
            await refreshLastDisconnectReason()
            errorMessage = nil
        } catch {
            errorMessage = friendlyMessage(for: error)
            refreshStatus()
        }
    }

    func save(password: String) async {
        do {
            try await saveConfiguration(password: password)
        } catch {
            errorMessage = friendlyMessage(for: error)
            refreshStatus()
        }
    }

    func saveAndConnect(password: String) async {
        do {
            try await saveConfiguration(password: password)
            try manager.connection.startVPNTunnel()
            lastDisconnectReason = nil
            AppModel.current?.vpnKillSwitch.arm()
            refreshStatus()
        } catch {
            errorMessage = friendlyMessage(for: error)
            refreshStatus()
        }
    }

    func connect() async {
        do {
            try await loadPreferences()
            guard manager.isEnabled, manager.protocolConfiguration != nil else {
                throw VPNConfigurationError.incompleteConfiguration
            }
            try manager.connection.startVPNTunnel()
            lastDisconnectReason = nil
            AppModel.current?.vpnKillSwitch.arm()
            refreshStatus()
        } catch {
            errorMessage = friendlyMessage(for: error)
            refreshStatus()
        }
    }

    func disconnect() {
        AppModel.current?.vpnKillSwitch.disarm()
        manager.connection.stopVPNTunnel()
        refreshStatus()
    }

    func remove() async {
        do {
            AppModel.current?.vpnKillSwitch.disarm()
            manager.connection.stopVPNTunnel()
            try await removePreferences()
            VPNKeychain.deletePassword()
            resetFields()
            refreshStatus()
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    func clearError() {
        errorMessage = nil
        lastDisconnectReason = nil
    }

    @objc private func vpnStatusDidChange() {
        refreshStatus()
        if manager.connection.status == .disconnected || manager.connection.status == .invalid {
            Task { await refreshLastDisconnectReason() }
        }
    }

    private func saveConfiguration(password: String) async throws {
        applyProviderDefaults()
        let trimmedServer = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedRemoteIdentifier = remoteIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedServer.isEmpty, !trimmedRemoteIdentifier.isEmpty, !trimmedUsername.isEmpty else {
            throw VPNConfigurationError.incompleteConfiguration
        }
        guard Self.isValidServerAddress(trimmedServer) else {
            throw VPNConfigurationError.invalidServerAddress
        }
        guard Self.isValidRemoteIdentifier(trimmedRemoteIdentifier) else {
            throw VPNConfigurationError.invalidRemoteIdentifier
        }

        try await loadPreferences()
        let passwordReference = try VPNKeychain.passwordReference(
            password: password,
            account: trimmedUsername,
            allowExisting: isConfigured
        )

        let configuration = NEVPNProtocolIKEv2()
        configuration.serverAddress = trimmedServer
        configuration.remoteIdentifier = trimmedRemoteIdentifier
        configuration.username = trimmedUsername
        configuration.authenticationMethod = .none
        configuration.useExtendedAuthentication = true
        configuration.passwordReference = passwordReference
        configuration.disconnectOnSleep = disconnectOnSleep
        configuration.enablePFS = true
        configuration.enableRevocationCheck = true
        configuration.strictRevocationCheck = false
        configuration.deadPeerDetectionRate = .high
        configuration.disableMOBIKE = false
        configuration.disableRedirect = preventServerRedirects
        configuration.includeAllNetworks = fullTunnel
        configuration.excludeLocalNetworks = fullTunnel && allowLocalNetworks
        configuration.enforceRoutes = fullTunnel
        applySecurityProfile(to: configuration)

        manager.localizedDescription = L("MacAdBlock VPN")
        manager.protocolConfiguration = configuration
        manager.isEnabled = true
        configureOnDemandRules()

        try await savePreferences()
        try await loadPreferences()
        hydrateFromManager()
        lastDisconnectReason = nil
        errorMessage = nil
    }

    private func configureOnDemandRules() {
        manager.isOnDemandEnabled = onDemandPolicy != .off
        switch onDemandPolicy {
        case .off:
            manager.onDemandRules = nil
        case .everyNetwork:
            let connect = NEOnDemandRuleConnect()
            connect.interfaceTypeMatch = .any
            manager.onDemandRules = [connect]
        case .untrustedWiFi:
            var rules: [NEOnDemandRule] = []
            let trustedSSIDs = Self.parseSSIDs(trustedWiFiSSIDs)
            if !trustedSSIDs.isEmpty {
                let trusted = NEOnDemandRuleDisconnect()
                trusted.interfaceTypeMatch = .wiFi
                trusted.ssidMatch = trustedSSIDs
                rules.append(trusted)
            }
            let wifi = NEOnDemandRuleConnect()
            wifi.interfaceTypeMatch = .wiFi
            rules.append(wifi)
            let ethernet = NEOnDemandRuleConnect()
            ethernet.interfaceTypeMatch = .ethernet
            rules.append(ethernet)
            manager.onDemandRules = rules
        }
    }

    private func applySecurityProfile(to configuration: NEVPNProtocolIKEv2) {
        guard securityProfile != .compatible else { return }
        let ike = configuration.ikeSecurityAssociationParameters
        let child = configuration.childSecurityAssociationParameters
        for parameters in [ike, child] {
            parameters.encryptionAlgorithm = .algorithmAES256GCM
            parameters.integrityAlgorithm = securityProfile == .hardened ? .SHA512 : .SHA384
            parameters.diffieHellmanGroup = securityProfile == .hardened ? .group21 : .group20
        }
    }

    private func hydrateFromManager() {
        if let configuration = manager.protocolConfiguration as? NEVPNProtocolIKEv2 {
            serverAddress = configuration.serverAddress ?? ""
            remoteIdentifier = configuration.remoteIdentifier ?? ""
            username = configuration.username ?? ""
            provider = Self.detectProvider(serverAddress: serverAddress, remoteIdentifier: remoteIdentifier)
            selectedServerID = provider.serverPresets.first(where: {
                $0.serverAddress.caseInsensitiveCompare(serverAddress) == .orderedSame
            })?.id ?? (provider == .custom ? "" : Self.manualServerID)
            fullTunnel = configuration.includeAllNetworks
            allowLocalNetworks = configuration.excludeLocalNetworks
            disconnectOnSleep = configuration.disconnectOnSleep
            preventServerRedirects = configuration.disableRedirect
            securityProfile = Self.detectSecurityProfile(configuration)
            isConfigured = !serverAddress.isEmpty
        } else {
            isConfigured = false
        }
        hydrateOnDemandRules()
        connectedSince = manager.connection.connectedDate
        refreshStatus()
    }

    private func hydrateOnDemandRules() {
        guard manager.isOnDemandEnabled else {
            onDemandPolicy = .off
            trustedWiFiSSIDs = ""
            return
        }
        let disconnectRule = manager.onDemandRules?.compactMap { $0 as? NEOnDemandRuleDisconnect }.first
        if let trusted = disconnectRule?.ssidMatch, !trusted.isEmpty {
            onDemandPolicy = .untrustedWiFi
            trustedWiFiSSIDs = trusted.joined(separator: ", ")
        } else {
            onDemandPolicy = .everyNetwork
            trustedWiFiSSIDs = ""
        }
    }

    private func applyProviderDefaults() {
        let trimmedServer = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let managedIdentifier = provider.remoteIdentifier(for: trimmedServer) {
            remoteIdentifier = managedIdentifier
        }
    }

    private static func detectProvider(serverAddress: String, remoteIdentifier: String) -> VPNProvider {
        if remoteIdentifier.caseInsensitiveCompare("hide.me") == .orderedSame { return .hideMe }
        if !serverAddress.isEmpty,
           remoteIdentifier.caseInsensitiveCompare(serverAddress) == .orderedSame,
           serverAddress.localizedCaseInsensitiveContains("surfshark") {
            return .surfshark
        }
        return .custom
    }

    private static func detectSecurityProfile(_ configuration: NEVPNProtocolIKEv2) -> VPNSecurityProfile {
        let parameters = configuration.ikeSecurityAssociationParameters
        guard parameters.encryptionAlgorithm == .algorithmAES256GCM else { return .compatible }
        if parameters.integrityAlgorithm == .SHA512, parameters.diffieHellmanGroup == .group21 { return .hardened }
        if parameters.integrityAlgorithm == .SHA384, parameters.diffieHellmanGroup == .group20 { return .modern }
        return .compatible
    }

    private static func isValidServerAddress(_ address: String) -> Bool {
        guard !address.isEmpty,
              address.count <= 253,
              !address.contains("://"),
              !address.contains("/"),
              !address.contains("@"),
              !address.contains(where: { $0.isWhitespace }) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-:")
        return address.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isValidRemoteIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier.count <= 253 && !identifier.contains("://") && !identifier.contains("/") && !identifier.contains(where: { $0.isWhitespace })
    }

    private static func parseSSIDs(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 32 && seen.insert($0).inserted }
            .prefix(50)
            .map { $0 }
    }

    private func resetFields() {
        serverAddress = ""
        remoteIdentifier = ""
        username = ""
        provider = .custom
        selectedServerID = ""
        onDemandPolicy = .off
        trustedWiFiSSIDs = ""
        fullTunnel = true
        allowLocalNetworks = true
        disconnectOnSleep = false
        preventServerRedirects = true
        securityProfile = .compatible
        isConfigured = false
        errorMessage = nil
        lastDisconnectReason = nil
        connectedSince = nil
    }

    private func refreshStatus() {
        status = switch manager.connection.status {
        case .invalid: isConfigured ? L("Profil wymaga naprawy") : L("Nieskonfigurowany")
        case .disconnected: isConfigured ? L("Rozłączony") : L("Nieskonfigurowany")
        case .connecting: L("Łączenie…")
        case .connected: L("Połączony")
        case .reasserting: L("Ponowne łączenie…")
        case .disconnecting: L("Rozłączanie…")
        @unknown default: L("Nieznany stan")
        }
        connectedSince = manager.connection.connectedDate
        objectWillChange.send()
    }

    private func refreshLastDisconnectReason() async {
        guard manager.connection.status == .disconnected || manager.connection.status == .invalid else { return }
        let error = await withCheckedContinuation { continuation in
            manager.connection.fetchLastDisconnectError { continuation.resume(returning: $0) }
        }
        lastDisconnectReason = error.map { friendlyDisconnectMessage(for: $0) }
    }

    private func friendlyDisconnectMessage(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NEVPNConnectionErrorDomain else { return nsError.localizedDescription }
        return switch nsError.code {
        case 1: L("Nieprawidłowy adres serwera.")
        case 2: L("Sieć lokalna jest niedostępna.")
        case 3: L("Połączenie z internetem jest niedostępne.")
        case 5: L("Nie udało się odnaleźć adresu serwera.")
        case 6: L("Serwer VPN nie odpowiada.")
        case 7: L("Serwer VPN przestał działać.")
        case 8: L("Serwer odrzucił nazwę użytkownika lub hasło.")
        case 15: L("Serwer nie zaakceptował ustawień szyfrowania. Wybierz profil Zgodny.")
        case 16: L("Serwer zakończył połączenie.")
        case 17...19: L("Certyfikat serwera jest nieprawidłowy lub nieważny.")
        default: nsError.localizedDescription
        }
    }

    private func loadPreferences() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func savePreferences() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func removePreferences() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.removeFromPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NEVPNErrorDomain || nsError.domain.hasPrefix("NE") {
            return L("VPN wymaga podpisania aplikacji i capability Personal VPN. Po zapisaniu zaakceptuj profil w oknie macOS.")
        }
        return error.localizedDescription
    }
}

private enum VPNKeychain {
    private static let service = "com.italiano88.MacAdBlock.vpn"

    static func passwordReference(password: String, account: String, allowExisting: Bool) throws -> Data {
        if !password.isEmpty {
            deletePassword()
            var result: CFTypeRef?
            let status = SecItemAdd([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
                kSecValueData: Data(password.utf8),
                kSecReturnPersistentRef: true
            ] as CFDictionary, &result)
            guard status == errSecSuccess, let reference = result as? Data else {
                throw VPNConfigurationError.keychain(status)
            }
            return reference
        }

        guard allowExisting else { throw VPNConfigurationError.passwordRequired }
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnPersistentRef: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let reference = result as? Data else {
            throw VPNConfigurationError.passwordRequired
        }
        return reference
    }

    static func deletePassword() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service
        ] as CFDictionary)
    }
}
