import Foundation

/// Reguła firewalla MacAdBlock. Trafia do zakotwiczonego zestawu reguł pf (`/etc/pf.anchors`).
/// Pole `remote` to adres IP, blok CIDR albo nazwa domeny (rozwiązywana przez pf przy wczytaniu reguł);
/// puste oznacza „dowolny”. Dla ruchu przychodzącego `port` to port lokalny, dla wychodzącego — port docelowy.
public struct FirewallRule: Codable, Identifiable, Equatable, Sendable {
    public enum Action: String, Codable, CaseIterable, Sendable { case block, allow }
    public enum Direction: String, Codable, CaseIterable, Sendable { case outbound, inbound }
    public enum Proto: String, Codable, CaseIterable, Sendable { case any, tcp, udp }

    public var id: UUID
    public var enabled: Bool
    public var action: Action
    public var direction: Direction
    public var proto: Proto
    public var remote: String
    public var port: String
    public var note: String

    public init(
        id: UUID = UUID(),
        enabled: Bool = true,
        action: Action = .block,
        direction: Direction = .outbound,
        proto: Proto = .any,
        remote: String = "",
        port: String = "",
        note: String = ""
    ) {
        self.id = id
        self.enabled = enabled
        self.action = action
        self.direction = direction
        self.proto = proto
        self.remote = remote
        self.port = port
        self.note = note
    }
}

public struct FirewallConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Ruch wychodzący tylko na DNS, DHCP, NTP oraz HTTP/HTTPS.
    public var lockdown: Bool
    /// Blokuje nowe połączenia przychodzące (odpowiedzi na połączenia wychodzące przechodzą).
    public var blockInbound: Bool
    public var rules: [FirewallRule]

    public init(enabled: Bool = false, lockdown: Bool = false, blockInbound: Bool = false, rules: [FirewallRule] = []) {
        self.enabled = enabled
        self.lockdown = lockdown
        self.blockInbound = blockInbound
        self.rules = rules
    }

    public static let disabled = FirewallConfig()
}

public enum FirewallError: LocalizedError, Equatable {
    case invalidRemote(String)
    case invalidPort(String)
    case tooManyRules

    public var errorDescription: String? {
        switch self {
        case .invalidRemote(let value): "Nieprawidłowy adres lub domena: \(value)"
        case .invalidPort(let value): "Nieprawidłowy port: \(value)"
        case .tooManyRules: "Zbyt wiele reguł firewalla (limit to \(PFRulesetBuilder.maximumRules))."
        }
    }
}

/// Buduje tekst reguł pf wyłącznie z ustrukturyzowanych danych — żadna wartość od użytkownika nie trafia do pf
/// bez walidacji, więc nie da się wstrzyknąć własnych dyrektyw.
public enum PFRulesetBuilder {
    public static let anchorName = "com.italiano88.macadblock"
    public static let maximumRules = 500

    /// Zwraca znormalizowany adres (`any`, IPv4, IPv6, CIDR albo nazwa domeny) lub nil, gdy jest nieprawidłowy.
    public static func normalizedRemote(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty || value == "any" { return "any" }

        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2 else { return nil }
        let address = parts[0]

        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            if parts.count == 2 {
                guard let prefix = Int(parts[1]), (0...32).contains(prefix) else { return nil }
            }
            return value
        }
        if address.contains(":"), inet_pton(AF_INET6, address, &v6) == 1 {
            if parts.count == 2 {
                guard let prefix = Int(parts[1]), (0...128).contains(prefix) else { return nil }
            }
            return value
        }
        guard parts.count == 1, isHostname(address) else { return nil }
        return address
    }

    /// Port (`443`) albo zakres (`8000:8100`); pusty tekst oznacza dowolny port i zwraca "".
    public static func normalizedPort(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "" }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 5, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let number = Int(part), (1...65_535).contains(number) else { return nil }
            numbers.append(number)
        }
        if numbers.count == 2, numbers[0] > numbers[1] { return nil }
        return numbers.map(String.init).joined(separator: ":")
    }

    private static func isHostname(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 253 else { return false }
        // Ostatni człon złożony z samych cyfr to nieprawidłowy adres IP (np. 300.1.1.1), a nie domena.
        if let last = value.split(separator: ".").last, last.allSatisfy(\.isNumber) { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard (1...63).contains(label.count),
                  label.first != "-", label.last != "-" else { return false }
            return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// Reguły zakotwiczone (anchor) `com.italiano88.macadblock`. Kolejność ma znaczenie: każda reguła ma `quick`,
    /// więc obowiązuje pierwsze dopasowanie.
    public static func anchorRules(for config: FirewallConfig) throws -> String {
        let active = config.rules.filter(\.enabled)
        guard active.count <= maximumRules else { throw FirewallError.tooManyRules }

        var lines: [String] = [
            "# Generowane przez MacAdBlock — nie edytuj ręcznie.",
            // Bez tych reguł blokada połączeń przychodzących zerwałaby IPv6 (wykrywanie sąsiadów) i DHCP.
            "pass quick inet6 proto icmp6 all",
            "pass in quick proto udp from any port 67 to any port 68",
            "pass in quick inet6 proto udp from fe80::/10 port 547 to fe80::/10 port 546"
        ]

        // Wyjątki (allow) mają pierwszeństwo przed blokadami.
        for rule in active where rule.action == .allow { lines.append(try render(rule)) }
        for rule in active where rule.action == .block { lines.append(try render(rule)) }

        if config.lockdown {
            lines.append("pass out quick proto udp from any to any port { 53, 67, 123, 853 } keep state")
            lines.append("pass out quick proto tcp from any to any port { 53, 80, 443, 853 } keep state")
            lines.append("block drop out quick all")
        } else {
            lines.append("pass out quick all keep state")
        }
        if config.blockInbound {
            lines.append("block drop in quick all")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Główny plik konfiguracji ładowany przez `pfctl -f`: domyślne kotwice Apple plus nasza.
    public static func mainConfiguration() -> String {
        """
        set skip on lo0
        scrub-anchor "com.apple/*"
        nat-anchor "com.apple/*"
        rdr-anchor "com.apple/*"
        dummynet-anchor "com.apple/*"
        anchor "com.apple/*"
        load anchor "com.apple" from "/etc/pf.anchors/com.apple"
        anchor "\(anchorName)"
        load anchor "\(anchorName)" from "/etc/pf.anchors/\(anchorName)"

        """
    }

    private static func render(_ rule: FirewallRule) throws -> String {
        guard let remote = normalizedRemote(rule.remote) else { throw FirewallError.invalidRemote(rule.remote) }
        guard let port = normalizedPort(rule.port) else { throw FirewallError.invalidPort(rule.port) }

        var words: [String] = [rule.action == .block ? "block drop" : "pass"]
        words.append(rule.direction == .outbound ? "out" : "in")
        words.append("quick")

        switch rule.proto {
        case .tcp: words.append("proto tcp")
        case .udp: words.append("proto udp")
        case .any: if !port.isEmpty { words.append("proto { tcp, udp }") }
        }

        if rule.direction == .outbound {
            words.append("from any to \(remote)")
        } else {
            words.append("from \(remote) to any")
        }
        if !port.isEmpty { words.append("port \(port)") }
        if rule.action == .allow { words.append("keep state") }
        return words.joined(separator: " ")
    }
}
