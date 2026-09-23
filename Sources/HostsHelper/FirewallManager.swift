import Darwin
import Foundation

/// Zarządza zakotwiczonymi regułami pf i wbudowanym firewallem aplikacji macOS. Działa jako root.
struct FirewallManager {
    private let anchorPath = "/etc/pf.anchors/\(PFRulesetBuilder.anchorName)"
    private let mainConfigurationPath = "/etc/pf.macadblock.conf"
    private let systemConfigurationPath = "/etc/pf.conf"
    private let stateDirectory = "/var/db/MacAdBlock"
    private var enabledByUsMarker: String { stateDirectory + "/firewall-enabled-pf" }
    private let pfctl = "/sbin/pfctl"
    private let socketFilter = "/usr/libexec/ApplicationFirewall/socketfilterfw"

    func apply(_ config: FirewallConfig) throws {
        guard config.enabled else {
            try disable()
            return
        }
        let rules = try PFRulesetBuilder.anchorRules(for: config)
        let main = PFRulesetBuilder.mainConfiguration()
        let previousAnchor = try? String(contentsOfFile: anchorPath, encoding: .utf8)

        try write(rules, to: anchorPath)
        try write(main, to: mainConfigurationPath)
        do {
            // Najpierw sam test składni, żeby błędna reguła nie zostawiła systemu bez firewalla.
            try run(pfctl, ["-n", "-f", mainConfigurationPath])
            try run(pfctl, ["-f", mainConfigurationPath])
        } catch {
            try? write(previousAnchor ?? "", to: anchorPath)
            throw error
        }

        if !pfIsEnabled() {
            try run(pfctl, ["-e"])
            try? FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o750])
            FileManager.default.createFile(atPath: enabledByUsMarker, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
    }

    func disable() throws {
        if FileManager.default.fileExists(atPath: anchorPath) {
            try write("", to: anchorPath)
        }
        guard pfIsEnabled() else {
            try? FileManager.default.removeItem(atPath: enabledByUsMarker)
            return
        }
        // Wracamy do domyślnych reguł systemu; pf wyłączamy tylko wtedy, gdy to my go włączyliśmy.
        _ = try? run(pfctl, ["-f", systemConfigurationPath])
        if FileManager.default.fileExists(atPath: enabledByUsMarker) {
            _ = try? run(pfctl, ["-d"])
            try? FileManager.default.removeItem(atPath: enabledByUsMarker)
        }
    }

    func status() -> (active: Bool, ruleCount: Int) {
        guard pfIsEnabled() else { return (false, 0) }
        let output = (try? run(pfctl, ["-a", PFRulesetBuilder.anchorName, "-s", "rules"])) ?? ""
        let count = output.split(whereSeparator: \Character.isNewline).filter { !$0.hasPrefix("#") }.count
        return (count > 0, count)
    }

    func setNativeFirewall(enabled: Bool, stealth: Bool) throws {
        try run(socketFilter, ["--setglobalstate", enabled ? "on" : "off"])
        try run(socketFilter, ["--setstealthmode", stealth ? "on" : "off"])
    }

    // MARK: - Pomocnicze

    private func pfIsEnabled() -> Bool {
        ((try? run(pfctl, ["-s", "info"])) ?? "").contains("Status: Enabled")
    }

    private func write(_ text: String, to path: String) throws {
        let temporary = path + ".tmp"
        try Data(text.utf8).write(to: URL(fileURLWithPath: temporary), options: .atomic)
        chmod(temporary, 0o644)
        chown(temporary, 0, 0)
        guard rename(temporary, path) == 0 else {
            let code = errno
            unlink(temporary)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Nie można zapisać \(path) (błąd \(code))."])
        }
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let outData = output.fileHandleForReading.readDataToEndOfFile()
        let errData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: outData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: message.isEmpty ? "\((executable as NSString).lastPathComponent) zakończył się kodem \(process.terminationStatus)." : message
            ])
        }
        return text
    }
}
