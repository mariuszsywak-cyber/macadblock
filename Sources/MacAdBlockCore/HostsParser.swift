import Foundation

public struct HostsParser: Sendable {
    private static let ignoredHosts: Set<String> = [
        "localhost", "localhost.localdomain", "broadcasthost", "ip6-localhost", "ip6-loopback"
    ]

    public init() {}

    public func parseHosts(_ text: String) -> Set<String> {
        var domains: Set<String> = []
        for rawLine in text.split(whereSeparator: \Character.isNewline) {
            let withoutComment = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let fields = withoutComment.split(whereSeparator: \Character.isWhitespace)
            guard !fields.isEmpty else { continue }

            let candidates: ArraySlice<Substring>
            if Self.isIPAddress(String(fields[0])) {
                candidates = fields.dropFirst()
            } else {
                candidates = fields[...]
            }
            for candidate in candidates {
                if let domain = Self.normalizedDomain(String(candidate)) {
                    domains.insert(domain)
                }
            }
        }
        return domains
    }

    public func parseDomains(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \Character.isNewline).compactMap { line in
            // omittingEmptySubsequences: false — linia zaczynająca się od "#" jest w całości komentarzem
            // (bez tego tekst komentarza trafiałby do kandydatów na domeny).
            let candidate = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            return Self.normalizedDomain(String(candidate).trimmingCharacters(in: .whitespaces))
        })
    }

    public static func normalizedDomain(_ value: String) -> String? {
        let domain = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !domain.isEmpty, domain.count <= 253, !ignoredHosts.contains(domain), !isIPAddress(domain) else { return nil }
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

    private static func isIPAddress(_ value: String) -> Bool {
        value == "0" || value.contains(":") || value.split(separator: ".").count == 4 && value.split(separator: ".").allSatisfy { Int($0) != nil }
    }
}
