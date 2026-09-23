import Foundation
import NetworkExtension

/// Wyłącznik awaryjny VPN: gdy tunel nieoczekiwanie się rozłączy (a nie z inicjatywy użytkownika),
/// automatycznie blokuje ruch wychodzący przez firewall pf, aby nic nie „wyciekło” poza tunel.
/// Działa niezależnie od tego, czy ekran VPN albo Ustawień jest otwarty — nasłuchuje bezpośrednio
/// na `NEVPNManager.shared()`, który jest współdzielonym singletonem systemowym.
@MainActor
final class VPNKillSwitch: NSObject, ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "vpnKillSwitchEnabled")
            if !isEnabled { disarm() }
        }
    }
    @Published private(set) var isActive = false
    @Published private(set) var triggeredAt: Date?

    private let manager = NEVPNManager.shared()
    private var armed = false
    private var savedFirewallConfig: FirewallConfig?

    private static let allowRuleID = UUID(uuidString: "9B2F2B7E-8B1B-4C9A-9B1C-A11000000001")!
    private static let blockRuleID = UUID(uuidString: "9B2F2B7E-8B1B-4C9A-9B1C-B10C00000002")!

    override init() {
        isEnabled = UserDefaults.standard.bool(forKey: "vpnKillSwitchEnabled")
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

    /// Wołane po udanym, celowym połączeniu VPN — od tej chwili nieoczekiwana utrata połączenia uzbraja blokadę.
    func arm() {
        guard isEnabled else { return }
        armed = true
    }

    /// Wołane tuż przed celowym rozłączeniem przez użytkownika (żeby nie potraktować go jako wyciek).
    func disarm() {
        armed = false
        deactivate()
    }

    @objc private func vpnStatusDidChange() {
        guard isEnabled, armed else { return }
        switch manager.connection.status {
        case .connected:
            deactivate()
        case .disconnected, .invalid:
            activate()
        default:
            break
        }
    }

    private func activate() {
        guard !isActive, let firewall = AppModel.current?.firewall else { return }
        savedFirewallConfig = firewall.config

        var config = firewall.config
        config.enabled = true
        config.blockInbound = true

        config.rules.removeAll { $0.id == Self.allowRuleID || $0.id == Self.blockRuleID }
        if let server = manager.protocolConfiguration?.serverAddress,
           PFRulesetBuilder.normalizedRemote(server) != nil {
            config.rules.append(FirewallRule(
                id: Self.allowRuleID, action: .allow, direction: .outbound, proto: .any,
                remote: server, port: "", note: L("Kill switch VPN — serwer")
            ))
        }
        config.rules.append(FirewallRule(
            id: Self.blockRuleID, action: .block, direction: .outbound, proto: .any,
            remote: "any", port: "", note: L("Kill switch VPN — blokada")
        ))

        firewall.config = config
        firewall.applyChanges()
        isActive = true
        triggeredAt = Date()
    }

    private func deactivate() {
        guard isActive else { return }
        if let saved = savedFirewallConfig, let firewall = AppModel.current?.firewall {
            firewall.config = saved
            firewall.applyChanges()
        }
        savedFirewallConfig = nil
        isActive = false
        triggeredAt = nil
    }
}
