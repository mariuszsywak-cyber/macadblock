import AppKit
import Foundation
import Security
import ServiceManagement

enum HostsClientError: LocalizedError {
    case helper(String)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .helper(let message): message
        case .unavailable: L("Helper hosts jest niedostępny. Zarejestruj go i zatwierdź w Ustawieniach systemowych.")
        }
    }
}

@MainActor
final class HostsHelperClient {
    private var service: SMAppService { .daemon(plistName: HostsHelperConstants.daemonPlistName) }
    private var connection: NSXPCConnection?

    /// Bez Team ID, gdy system nie widzi demona (`notFound` — zdarza się przy podpisie kontem Personal Team,
    /// bez Developer ID), albo gdy wcześniejsza próba `register()` się nie powiodła, używamy wbudowanego
    /// helpera uruchamianego z hasłem administratora zamiast SMAppService.
    var usesAuthorizationFallback: Bool {
        signingTeamIdentifier == nil || service.status == .notFound || forcedAuthorizationFallback
    }

    private static let forcedFallbackDefaultsKey = "hostsHelperForcedAuthorizationFallback"

    private var forcedAuthorizationFallback: Bool {
        get { UserDefaults.standard.bool(forKey: Self.forcedFallbackDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.forcedFallbackDefaultsKey) }
    }

    /// Wywoływane, gdy SMAppService odmówi rejestracji demona (typowe na koncie Personal Team bez
    /// Developer ID) — od tej pory zamiast pokazywać ślepy błąd, korzystamy z trybu lokalnego na stałe.
    func markRegistrationFailed() {
        forcedAuthorizationFallback = true
    }

    /// Czy zainstalowany w systemie demon (jednorazowo, hasłem administratora) jest aktualny i można z nim
    /// rozmawiać przez XPC bez pytania o hasło.
    var installedDaemonIsCurrent: Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: HostsHelperConstants.installedHelperPath),
              fm.fileExists(atPath: HostsHelperConstants.installedPlistPath) else { return false }
        guard let installed = Self.helperBuild(at: HostsHelperConstants.installedHelperPath),
              let embedded = Self.helperBuild(at: embeddedHelperURL.path) else { return false }
        return installed == embedded
    }

    /// Czy helper przyjmie polecenie bez okna z hasłem (zainstalowany demon albo podpis z płatnego konta).
    var canRunWithoutPrompt: Bool { usesXPC }

    /// Rozmowa z demonem jest bezpieczna tylko z aktualnym demonem: stary nie zna nowych metod XPC.
    private var usesXPC: Bool {
        installedDaemonIsCurrent
            || (!usesAuthorizationFallback && !FileManager.default.fileExists(atPath: HostsHelperConstants.installedPlistPath))
    }

    private nonisolated static func helperBuild(at path: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--build"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Instaluje helpera jako LaunchDaemon systemowy (jedno okno z hasłem). Kolejne operacje na /etc/hosts
    /// idą już przez XPC bez hasła. Zwraca true, gdy demon jest gotowy.
    @discardableResult
    func installDaemonIfNeeded() -> Bool {
        // Także przy podpisie z płatnego konta: jeśli w systemie została nasza starsza kopia demona, trzeba ją odświeżyć,
        // bo stary demon nie zna nowych metod XPC i przy ich wywołaniu kończy pracę.
        guard usesAuthorizationFallback || FileManager.default.fileExists(atPath: HostsHelperConstants.installedPlistPath) else { return true }
        if installedDaemonIsCurrent { return true }
        guard FileManager.default.isExecutableFile(atPath: embeddedHelperURL.path) else { return false }
        let label = HostsHelperConstants.machServiceName
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key><array><string>\(HostsHelperConstants.installedHelperPath)</string></array>
            <key>MachServices</key><dict><key>\(label)</key><true/></dict>
            <key>RunAtLoad</key><false/>
        </dict></plist>
        """
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAdBlock-daemon-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        do { try plist.write(to: temporaryURL, atomically: true, encoding: .utf8) } catch { return false }
        let helper = HostsHelperConstants.installedHelperPath
        let daemonPlist = HostsHelperConstants.installedPlistPath
        let steps = [
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/bin/launchctl bootout system/\(label) 2>/dev/null; true",
            "/bin/cp \(shellQuoted(embeddedHelperURL.path)) \(shellQuoted(helper))",
            "/usr/sbin/chown root:wheel \(shellQuoted(helper))",
            "/bin/chmod 755 \(shellQuoted(helper))",
            "/bin/cp \(shellQuoted(temporaryURL.path)) \(shellQuoted(daemonPlist))",
            "/usr/sbin/chown root:wheel \(shellQuoted(daemonPlist))",
            "/bin/chmod 644 \(shellQuoted(daemonPlist))",
            "/bin/launchctl bootstrap system \(shellQuoted(daemonPlist))"
        ]
        do { try runAdministratorCommand(steps.joined(separator: " && ")) } catch { return false }
        return installedDaemonIsCurrent
    }

    private func activeConnection() -> NSXPCConnection {
        if let connection { return connection }

        let connection = NSXPCConnection(machServiceName: HostsHelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HostsHelperProtocol.self)
        connection.resume()
        self.connection = connection
        return connection
    }

    var serviceStatus: SMAppService.Status { usesAuthorizationFallback ? .enabled : service.status }

    func register() throws {
        guard !usesAuthorizationFallback else { return }
        try service.register()
    }

    func unregister() throws {
        resetConnection()
        guard !usesAuthorizationFallback else { return }
        try service.unregister()
    }

    func repairRegistration() throws {
        resetConnection()
        guard !usesAuthorizationFallback else {
            guard FileManager.default.isExecutableFile(atPath: embeddedHelperURL.path) else {
                throw HostsClientError.unavailable
            }
            return
        }
        if service.status != .notRegistered {
            try service.unregister()
        }
        try service.register()
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func apply(domains: [String]) async throws {
        if usesAuthorizationFallback {
            if installDaemonIfNeeded() {
                do { try await applyViaXPC(domains: domains); return } catch {}
            }
            try applyWithAuthorization(domains: domains)
            return
        }
        try await applyViaXPC(domains: domains)
    }

    private func applyViaXPC(domains: [String]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            withProxy { proxy in
                let reply = Self.booleanReplyHandler { success, message in
                    success ? continuation.resume() : continuation.resume(throwing: HostsClientError.helper(message ?? L("Helper odrzucił operację.")))
                }
                proxy.apply(domains: domains, withReply: reply)
            } onFailure: { continuation.resume(throwing: $0) }
        }
    }

    func removeManagedSection() async throws {
        if usesAuthorizationFallback {
            if installDaemonIfNeeded() {
                do { try await removeViaXPC(); return } catch {}
            }
            try runPrivilegedHelper(arguments: ["--remove"])
            return
        }
        try await removeViaXPC()
    }

    private func removeViaXPC() async throws {
        try await withCheckedThrowingContinuation { continuation in
            withProxy { proxy in
                let reply = Self.booleanReplyHandler { success, message in
                    success ? continuation.resume() : continuation.resume(throwing: HostsClientError.helper(message ?? L("Helper odrzucił operację.")))
                }
                proxy.removeManagedSection(withReply: reply)
            } onFailure: { continuation.resume(throwing: $0) }
        }
    }

    func status() async throws -> (enabled: Bool, count: Int) {
        if usesAuthorizationFallback {
            guard embeddedHelperIsOperational() else {
                throw HostsClientError.unavailable
            }
            return try localStatus()
        }
        return try await withCheckedThrowingContinuation { continuation in
            withProxy { proxy in
                let reply = Self.statusReplyHandler { enabled, count, message in
                    if let message {
                        continuation.resume(throwing: HostsClientError.helper(message))
                    } else {
                        continuation.resume(returning: (enabled, count))
                    }
                }
                proxy.status(withReply: reply)
            } onFailure: { continuation.resume(throwing: $0) }
        }
    }

    private func withProxy(
        _ operation: @escaping @MainActor @Sendable (HostsHelperProtocol) -> Void,
        onFailure: @escaping @MainActor @Sendable (Error) -> Void
    ) {
        resetConnection()
        if FileManager.default.fileExists(atPath: HostsHelperConstants.installedPlistPath), !installedDaemonIsCurrent {
            installDaemonIfNeeded()
        }
        let connection = activeConnection()
        let errorHandler = Self.errorHandler(onFailure)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler(errorHandler) as? HostsHelperProtocol else {
            resetConnection()
            onFailure(HostsClientError.unavailable)
            return
        }
        operation(proxy)
    }

    private nonisolated static func errorHandler(
        _ handler: @escaping @MainActor @Sendable (Error) -> Void
    ) -> @Sendable (Error) -> Void {
        { error in
            Task { @MainActor in
                handler(error)
            }
        }
    }

    private nonisolated static func booleanReplyHandler(
        _ handler: @escaping @MainActor @Sendable (Bool, String?) -> Void
    ) -> @Sendable (Bool, String?) -> Void {
        { success, message in
            Task { @MainActor in
                handler(success, message)
            }
        }
    }

    private nonisolated static func statusReplyHandler(
        _ handler: @escaping @MainActor @Sendable (Bool, Int, String?) -> Void
    ) -> @Sendable (Bool, Int, String?) -> Void {
        { enabled, count, message in
            Task { @MainActor in
                handler(enabled, count, message)
            }
        }
    }

    private func applyWithAuthorization(domains: [String]) throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAdBlock-hosts-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try domains.joined(separator: "\n").write(to: temporaryURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        try runPrivilegedHelper(arguments: ["--apply-file", temporaryURL.path])
    }

    /// Czyści pamięć podręczną DNS i restartuje mDNSResponder, aby przeglądarki i aplikacje od razu
    /// zobaczyły zmiany w /etc/hosts. Wymaga hasła administratora (okno systemowe).
    func flushDNSCache() async throws {
        if usesXPC || installDaemonIfNeeded() {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    withProxy { proxy in
                        let reply = Self.booleanReplyHandler { success, message in
                            success ? continuation.resume() : continuation.resume(throwing: HostsClientError.helper(message ?? L("Helper odrzucił operację.")))
                        }
                        proxy.flushDNSCache(withReply: reply)
                    } onFailure: { continuation.resume(throwing: $0) }
                }
                return
            } catch {
                if !usesAuthorizationFallback { throw error }
            }
        }
        try runAdministratorCommand("/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder")
    }

    // MARK: - Firewall

    func applyFirewall(_ config: FirewallConfig) async throws {
        let data = try JSONEncoder().encode(config)
        if usesAuthorizationFallback {
            if installDaemonIfNeeded() {
                do { try await xpcBoolCall { proxy, reply in proxy.applyFirewall(config: data, withReply: reply) }; return } catch {}
            }
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacAdBlock-firewall-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            try data.write(to: temporaryURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            try runPrivilegedHelper(arguments: config.enabled ? ["--firewall-apply", temporaryURL.path] : ["--firewall-disable"])
            return
        }
        try await xpcBoolCall { proxy, reply in proxy.applyFirewall(config: data, withReply: reply) }
    }

    /// Stan pf bez okna z hasłem; nil, gdy helper nie jest dostępny bez hasła.
    func firewallStatus() async -> (active: Bool, rules: Int)? {
        guard usesXPC else { return nil }
        return try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(active: Bool, rules: Int), Error>) in
            withProxy { proxy in
                let reply = Self.statusReplyHandler { active, count, message in
                    if let message {
                        continuation.resume(throwing: HostsClientError.helper(message))
                    } else {
                        continuation.resume(returning: (active, count))
                    }
                }
                proxy.firewallStatus(withReply: reply)
            } onFailure: { continuation.resume(throwing: $0) }
        }
    }

    func setNativeFirewall(enabled: Bool, stealth: Bool) async throws {
        if usesXPC || installDaemonIfNeeded() {
            do { try await xpcBoolCall { proxy, reply in proxy.setNativeFirewall(enabled: enabled, stealth: stealth, withReply: reply) }; return } catch {
                if !usesAuthorizationFallback { throw error }
            }
        }
        try runPrivilegedHelper(arguments: ["--native-firewall", enabled ? "on" : "off", stealth ? "on" : "off"])
    }

    private func xpcBoolCall(
        _ call: @escaping @MainActor @Sendable (HostsHelperProtocol, @escaping @Sendable (Bool, String?) -> Void) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            withProxy { proxy in
                let reply = Self.booleanReplyHandler { success, message in
                    success ? continuation.resume() : continuation.resume(throwing: HostsClientError.helper(message ?? L("Helper odrzucił operację.")))
                }
                call(proxy, reply)
            } onFailure: { continuation.resume(throwing: $0) }
        }
    }

    private func runAdministratorCommand(_ command: String) throws {
        let source = "do shell script \(appleScriptQuoted(command)) with administrator privileges"
        guard let script = NSAppleScript(source: source) else { throw HostsClientError.unavailable }
        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo["NSAppleScriptErrorMessage"] as? String ?? L("Nie udało się uruchomić helpera z uprawnieniami administratora.")
            throw HostsClientError.helper(message)
        }
    }

    private func runPrivilegedHelper(arguments: [String]) throws {
        guard FileManager.default.isExecutableFile(atPath: embeddedHelperURL.path) else {
            throw HostsClientError.unavailable
        }
        let command = ([embeddedHelperURL.path] + arguments).map(shellQuoted).joined(separator: " ")
        let source = "do shell script \(appleScriptQuoted(command)) with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            throw HostsClientError.unavailable
        }
        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo["NSAppleScriptErrorMessage"] as? String ?? L("Nie udało się uruchomić helpera z uprawnieniami administratora.")
            throw HostsClientError.helper(message)
        }
    }

    private func localStatus() throws -> (enabled: Bool, count: Int) {
        let contents = try String(contentsOfFile: "/etc/hosts", encoding: .utf8)
        guard let start = contents.range(of: ManagedHostsComposer.beginMarker),
              let end = contents.range(of: ManagedHostsComposer.endMarker),
              start.upperBound < end.lowerBound else {
            return (false, 0)
        }
        let count = contents[start.upperBound..<end.lowerBound]
            .split(whereSeparator: \Character.isNewline)
            .filter { $0.hasPrefix("0.0.0.0 ") }
            .count
        return (true, count)
    }

    private func embeddedHelperIsOperational() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: embeddedHelperURL.path) else { return false }
        let process = Process()
        process.executableURL = embeddedHelperURL
        process.arguments = ["--self-check"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationReason == .exit && process.terminationStatus == EXIT_SUCCESS
        } catch {
            return false
        }
    }

    private var embeddedHelperURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
            .appendingPathComponent(HostsHelperConstants.machServiceName)
    }

    private var signingTeamIdentifier: String? {
        guard let executableURL = Bundle.main.executableURL else { return nil }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation) == errSecSuccess,
              let information = signingInformation as? [CFString: Any] else { return nil }
        return information[kSecCodeInfoTeamIdentifier] as? String
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func resetConnection() {
        let oldConnection = connection
        connection = nil
        oldConnection?.invalidationHandler = nil
        oldConnection?.invalidate()
    }
}
