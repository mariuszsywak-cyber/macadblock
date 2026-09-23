import Foundation

final class HostsHelperService: NSObject, HostsHelperProtocol {
    private let manager = HostsFileManager()
    private let firewall = FirewallManager()

    func apply(domains: [String], withReply reply: @escaping (Bool, String?) -> Void) {
        do {
            _ = try manager.apply(domains: domains)
            HostsFileManager.flushDNSCache()
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func removeManagedSection(withReply reply: @escaping (Bool, String?) -> Void) {
        do {
            try manager.removeManagedSection()
            HostsFileManager.flushDNSCache()
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func applyFirewall(config: Data, withReply reply: @escaping (Bool, String?) -> Void) {
        do {
            guard config.count <= 1_048_576 else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Konfiguracja firewalla jest zbyt duża."])
            }
            try firewall.apply(try JSONDecoder().decode(FirewallConfig.self, from: config))
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func firewallStatus(withReply reply: @escaping (Bool, Int, String?) -> Void) {
        let status = firewall.status()
        reply(status.active, status.ruleCount, nil)
    }

    func setNativeFirewall(enabled: Bool, stealth: Bool, withReply reply: @escaping (Bool, String?) -> Void) {
        do {
            try firewall.setNativeFirewall(enabled: enabled, stealth: stealth)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func flushDNSCache(withReply reply: @escaping (Bool, String?) -> Void) {
        HostsFileManager.flushDNSCache()
        reply(true, nil)
    }

    func status(withReply reply: @escaping (Bool, Int, String?) -> Void) {
        do {
            let status = try manager.status()
            reply(status.enabled, status.count, nil)
        } catch {
            reply(false, 0, error.localizedDescription)
        }
    }
}

final class HostsHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HostsHelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard ClientAuthorizer.isAuthorized(connection) else { return false }
        if let requirement = ClientAuthorizer.codeSigningRequirement() {
            connection.setCodeSigningRequirement(requirement)
        }
        connection.exportedInterface = NSXPCInterface(with: HostsHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}
