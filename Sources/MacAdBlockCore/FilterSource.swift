import Foundation

public enum FilterFormat: String, Codable, Sendable {
    case adblock
    case hosts
    case domains
}

public enum FilterCategory: String, Codable, Sendable {
    case ads
    case privacy
    case annoyances
    case social
    case regional
    case security
    case malware
    /// Blokowanie całych kategorii treści lub serwisów (dorośli, hazard, sieci społecznościowe, torrenty…).
    case content

    public var displayName: String {
        switch self {
        case .ads: "Reklamy"
        case .privacy: "Prywatność"
        case .annoyances: "Irytujące elementy"
        case .social: "Media społecznościowe"
        case .regional: "Filtry regionalne"
        case .security: "Ochrona przed oszustwami"
        case .malware: "Malware"
        case .content: "Blokowanie treści i serwisów"
        }
    }
}

/// Ustawienia wprowadzone przez użytkownika: wyjątki, własne reguły i własne listy.
/// Plik leży w kontenerze App Group, więc czyta go zarówno aplikacja, jak i rozszerzenia Safari.
public struct UserFilterSettings: Codable, Sendable, Equatable {
    public var allowlistedDomains: [String]
    public var customRules: String
    public var customSources: [FilterSource]

    public static let empty = UserFilterSettings()

    public init(allowlistedDomains: [String] = [], customRules: String = "", customSources: [FilterSource] = []) {
        self.allowlistedDomains = allowlistedDomains
        self.customRules = customRules
        self.customSources = customSources
    }

    /// Brakujące klucze nie unieważniają całego pliku — starsza konfiguracja wczytuje się z wartościami domyślnymi.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowlistedDomains = (try? container.decode([String].self, forKey: .allowlistedDomains)) ?? []
        customRules = (try? container.decode(String.self, forKey: .customRules)) ?? ""
        customSources = (try? container.decode([FilterSource].self, forKey: .customSources)) ?? []
    }

    /// Nazwy hostów po normalizacji, bez duplikatów i bez pustych wpisów. Przedrostek „www.” jest
    /// usuwany, bo wyjątek zawsze dotyczy całej witryny (tak samo zapisuje go popup w Safari).
    public var normalizedAllowlist: [String] {
        Set(allowlistedDomains.compactMap(Self.normalizedHost)).sorted()
    }

    static func normalizedHost(_ value: String) -> String? {
        guard let host = validatedDomain(value) else { return nil }
        guard host.hasPrefix("www.") else { return host }
        return validatedDomain(String(host.dropFirst(4))) ?? host
    }

    /// Walidacja nazwy hosta powtórzona z `HostsParser.normalizedDomain`, ponieważ target
    /// SafariBlocker kompiluje ten plik bez parsera hosts. Zgodności obu wersji pilnuje test
    /// `allowlistNormalizationMatchesHostsParser`.
    static func validatedDomain(_ value: String) -> String? {
        let domain = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let ignored: Set<String> = ["localhost", "localhost.localdomain", "broadcasthost", "ip6-localhost", "ip6-loopback"]
        guard !domain.isEmpty, domain.count <= 253, !ignored.contains(domain), !isAddress(domain) else { return nil }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return nil }
        for label in labels {
            guard !label.isEmpty, label.count <= 63,
                  label.first?.isLetter == true || label.first?.isNumber == true,
                  label.last?.isLetter == true || label.last?.isNumber == true,
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        }
        return domain
    }

    private static func isAddress(_ value: String) -> Bool {
        value == "0" || value.contains(":") || value.split(separator: ".").count == 4 && value.split(separator: ".").allSatisfy { Int($0) != nil }
    }

    public func isAllowlisted(_ domain: String) -> Bool {
        guard let host = Self.normalizedHost(domain) else { return false }
        let allowed = Set(normalizedAllowlist)
        guard !allowed.isEmpty else { return false }
        if allowed.contains(host) { return true }
        return allowed.contains { host.hasSuffix("." + $0) }
    }

    public mutating func allow(_ domain: String) {
        guard let host = Self.normalizedHost(domain) else { return }
        allowlistedDomains = Set(normalizedAllowlist + [host]).sorted()
    }

    public mutating func disallow(_ domain: String) {
        guard let host = Self.normalizedHost(domain) else { return }
        allowlistedDomains = normalizedAllowlist.filter { $0 != host }
    }

    /// Odcisk zmian — wchodzi do odcisku kompilacji, aby edycja wyjątków lub własnych reguł
    /// wymusiła przebudowanie reguł nawet wtedy, gdy żadna lista się nie zmieniła.
    public var fingerprint: String {
        [
            "allow=" + normalizedAllowlist.joined(separator: ","),
            "custom=" + String(Self.stableIdentifier(for: customRules), radix: 16),
            "sources=" + customSources.map(\.id).sorted().joined(separator: ",")
        ].joined(separator: "|")
    }

    /// Tworzy źródło z adresu podanego przez użytkownika. Wymaga HTTPS, tak jak listy z katalogu.
    public static func customSource(
        name: String,
        url: URL,
        format: FilterFormat,
        category: FilterCategory = .ads
    ) -> FilterSource? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.scheme?.lowercased() == "https", !trimmed.isEmpty else { return nil }
        return FilterSource(
            id: "custom-" + String(stableIdentifier(for: url.absoluteString), radix: 16),
            name: trimmed,
            url: url,
            format: format,
            category: category,
            enabledByDefault: false,
            homepage: url,
            countryCode: "USER",
            countryName: "Własne",
            estimatedRuleCount: 0,
            isExtra: true
        )
    }

    private static func stableIdentifier(for value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }
}

public struct FilterSource: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let url: URL
    public let format: FilterFormat
    public let category: FilterCategory
    public let enabledByDefault: Bool
    public let homepage: URL
    public let countryCode: String
    public let countryName: String
    public let estimatedRuleCount: Int
    /// Listy dodatkowe są dostępne w ustawieniach, ale nigdy nie włączają się same
    /// (kreator konfiguracji ani przełączniki kategorii ich nie aktywują).
    public let isExtra: Bool

    public init(
        id: String,
        name: String,
        url: URL,
        format: FilterFormat,
        category: FilterCategory,
        enabledByDefault: Bool,
        homepage: URL,
        countryCode: String = "INT",
        countryName: String = "Globalne",
        estimatedRuleCount: Int = 0,
        isExtra: Bool = false
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.format = format
        self.category = category
        self.enabledByDefault = enabledByDefault
        self.homepage = homepage
        self.countryCode = countryCode
        self.countryName = countryName
        self.estimatedRuleCount = estimatedRuleCount
        self.isExtra = isExtra
    }
}
