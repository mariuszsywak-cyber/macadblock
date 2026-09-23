import Foundation

public enum AdblockNetworkAction: String, Codable, Hashable, Sendable {
    case block, allow, blockCookies, upgradeScheme, removeParameters
}

public struct AdblockNetworkRule: Codable, Hashable, Sendable {
    public let pattern: String
    public let isRegularExpression: Bool
    public let action: AdblockNetworkAction
    public let includedDomains: [String]
    public let excludedDomains: [String]
    public let resourceTypes: [String]
    public let excludedResourceTypes: [String]
    public let requestMethods: [String]
    public let excludedRequestMethods: [String]
    public let loadType: String?
    public let isCaseSensitive: Bool
    public let isImportant: Bool
    public let removeParameters: [String]
}

public enum AdblockCosmeticAction: String, Codable, Hashable, Sendable {
    case hide, remove, style, procedural, scriptlet
}

public struct AdblockCosmeticRule: Codable, Hashable, Sendable {
    public let selector: String
    public let includedDomains: [String]
    public let excludedDomains: [String]
    public let isException: Bool
    public let action: AdblockCosmeticAction
    public let argument: String?
}

/// Wywołanie scriptletu z reguły `##+js(nazwa, argument…)` albo `#%#//scriptlet('nazwa', 'argument'…)`.
/// Scriptlety wykonuje rozszerzenie Safari w kontekście strony; argumenty są danymi, nigdy kodem.
public struct ScriptletInvocation: Codable, Hashable, Sendable {
    public let name: String
    public let arguments: [String]
    public let includedDomains: [String]
    public let excludedDomains: [String]
    public let isException: Bool

    public init(name: String, arguments: [String], includedDomains: [String], excludedDomains: [String], isException: Bool) {
        self.name = name
        self.arguments = arguments
        self.includedDomains = includedDomains
        self.excludedDomains = excludedDomains
        self.isException = isException
    }

    /// Lista musi odpowiadać bibliotece `macAdBlockScriptletRunner` w `background.js`.
    /// Reguła z nieznaną nazwą jest liczona jako nieobsługiwana i nigdy nie trafia do rozszerzenia.
    public static let supportedNames: Set<String> = [
        "set-constant", "set",
        "abort-on-property-read", "aopr",
        "abort-on-property-write", "aopw",
        "json-prune",
        "prevent-settimeout", "no-settimeout-if",
        "prevent-setinterval", "no-setinterval-if",
        "prevent-window-open", "nowoif"
    ]

    /// Rozkłada surowy zapis reguły na nazwę i argumenty, obsługując zapis uBlock i AdGuard.
    public static func parse(_ raw: String) -> (name: String, arguments: [String])? {
        var body = raw.trimmingCharacters(in: .whitespaces)
        for prefix in ["//scriptlet", "+js"] where body.hasPrefix(prefix) {
            body = String(body.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        if body.hasPrefix("("), body.hasSuffix(")") {
            body = String(body.dropFirst().dropLast())
        }
        var parts = splitArguments(body)
        guard let first = parts.first?.lowercased(), !first.isEmpty else { return nil }
        parts.removeFirst()
        if parts.last?.isEmpty == true { parts.removeLast() }
        return (first, parts)
    }

    public static func isSupported(_ raw: String) -> Bool {
        guard let parsed = parse(raw) else { return false }
        return supportedNames.contains(parsed.name)
    }

    /// Podział po przecinkach z poszanowaniem cudzysłowów i znaku ucieczki — argument może zawierać przecinek.
    private static func splitArguments(_ body: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in body {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "," {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts
    }
}

public struct ParsedAdblockRules: Codable, Sendable {
    public var network: Set<AdblockNetworkRule> = []
    public var cosmetic: Set<AdblockCosmeticRule> = []
    public var cosmeticExemptDomains: Set<String> = []
    public var genericNetworkExemptDomains: Set<String> = []
    public var unsupportedRuleCount = 0
}

public struct AdblockParser: Sendable {
    public init() {}

    public func parse(_ text: String) -> ParsedAdblockRules {
        var result = ParsedAdblockRules()
        let lines = text.split(whereSeparator: \Character.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let disabledRules = Set(lines.compactMap(Self.badFilterKey))

        for line in lines {
            guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[Adblock") else { continue }

            if let cosmetic = parseCosmetic(line) {
                // Scriptlet o znanej nazwie umie wykonać rozszerzenie; nieznany pozostaje nieobsługiwany.
                if cosmetic.action == .scriptlet, !ScriptletInvocation.isSupported(cosmetic.argument ?? "") {
                    result.unsupportedRuleCount += 1
                }
                result.cosmetic.insert(cosmetic)
                continue
            }
            if line.contains("$@$"), line.range(of: "$@$", options: .backwards) != nil {
                result.unsupportedRuleCount += 1
                continue
            }
            if line.contains("$$"), line.range(of: "$$", options: .backwards) != nil {
                result.unsupportedRuleCount += 1
                continue
            }

            let isException = line.hasPrefix("@@")
            let body = isException ? String(line.dropFirst(2)) : line
            let split = splitPatternAndOptions(body)
            guard !split.pattern.isEmpty else { continue }
            if disabledRules.contains(Self.canonicalRuleKey(line)) { continue }

            var includedDomains: [String] = []
            var excludedDomains: [String] = []
            var resourceTypes: Set<String> = []
            var excludedResourceTypes: Set<String> = []
            var requestMethods: Set<String> = []
            var excludedRequestMethods: Set<String> = []
            var loadType: String?
            var caseSensitive = false
            var important = false
            var badFilter = false
            var documentException = false
            var cosmeticException = false
            var genericBlockException = false
            var unsupportedModifier = false
            var action: AdblockNetworkAction = isException ? .allow : .block
            var removeParameters: Set<String> = []

            for option in split.options {
                let lower = option.lowercased()
                if lower.isEmpty || lower == "all" || lower == "network" {
                    continue
                } else if lower.hasPrefix("domain=") || lower.hasPrefix("from=") {
                    let prefix = lower.hasPrefix("domain=") ? "domain=" : "from="
                    let domains = parseDomainList(String(option.dropFirst(prefix.count)))
                    includedDomains = domains.included
                    excludedDomains = domains.excluded
                } else if lower.hasPrefix("method=") {
                    for rawMethod in String(option.dropFirst("method=".count)).split(separator: "|") {
                        let method = rawMethod.lowercased()
                        let excluded = method.hasPrefix("~")
                        let value = excluded ? String(method.dropFirst()) : method
                        guard Self.supportedMethods.contains(value) else {
                            result.unsupportedRuleCount += 1
                            unsupportedModifier = true
                            continue
                        }
                        if excluded { excludedRequestMethods.insert(value) } else { requestMethods.insert(value) }
                    }
                } else if lower == "third-party" || lower == "3p" {
                    loadType = "third-party"
                } else if lower == "~third-party" || lower == "1p" || lower == "first-party" {
                    loadType = "first-party"
                } else if lower == "match-case" {
                    caseSensitive = true
                } else if lower == "important" {
                    important = true
                } else if lower == "badfilter" {
                    badFilter = true
                } else if lower == "document" || lower == "doc" {
                    resourceTypes.insert("top-document")
                    documentException = isException
                } else if lower == "elemhide" || lower == "generichide" || lower == "specifichide" {
                    cosmeticException = isException
                } else if lower == "genericblock" {
                    genericBlockException = isException
                } else if lower == "cookie" {
                    action = isException ? .allow : .blockCookies
                } else if lower == "https" || lower == "upgrade" || lower == "redirect=https" {
                    action = isException ? .allow : .upgradeScheme
                } else if lower.hasPrefix("removeparam=") {
                    let value = String(option.dropFirst("removeparam=".count))
                    for parameter in value.split(separator: "|") where isSafeParameterName(String(parameter)) {
                        removeParameters.insert(String(parameter))
                    }
                    if !removeParameters.isEmpty { action = isException ? .allow : .removeParameters }
                } else if lower == "removeparam" {
                    result.unsupportedRuleCount += 1
                    unsupportedModifier = true
                } else if lower.hasPrefix("csp=") || lower.hasPrefix("header=") || lower.hasPrefix("replace=") || lower.hasPrefix("uritransform=") || lower.hasPrefix("urlskip=") {
                    result.unsupportedRuleCount += 1
                    unsupportedModifier = true
                } else if let type = Self.resourceTypeMap[lower.trimmingCharacters(in: CharacterSet(charactersIn: "~"))] {
                    if lower.hasPrefix("~") { excludedResourceTypes.insert(type) } else { resourceTypes.insert(type) }
                } else {
                    result.unsupportedRuleCount += 1
                    unsupportedModifier = true
                }
            }

            guard !badFilter, !unsupportedModifier else { continue }
            if isException, let host = Self.domainHost(from: split.pattern) {
                if cosmeticException || documentException { result.cosmeticExemptDomains.insert(host) }
                if genericBlockException { result.genericNetworkExemptDomains.insert(host) }
            }
            if cosmeticException || genericBlockException { continue }

            result.network.insert(AdblockNetworkRule(
                pattern: split.pattern,
                isRegularExpression: split.isRegularExpression,
                action: action,
                includedDomains: includedDomains,
                excludedDomains: excludedDomains,
                resourceTypes: resourceTypes.sorted(),
                excludedResourceTypes: excludedResourceTypes.sorted(),
                requestMethods: requestMethods.sorted(),
                excludedRequestMethods: excludedRequestMethods.sorted(),
                loadType: loadType,
                isCaseSensitive: caseSensitive,
                isImportant: important,
                removeParameters: removeParameters.sorted()
            ))
        }
        return result
    }

    private func parseCosmetic(_ line: String) -> AdblockCosmeticRule? {
        let separators: [(String, Bool, AdblockCosmeticAction)] = [
            ("#@%#", true, .scriptlet), ("#%#", false, .scriptlet),
            ("#@?#", true, .procedural), ("#?#", false, .procedural),
            ("#@$#", true, .style), ("#$#", false, .style),
            ("#@#", true, .hide), ("##", false, .hide)
        ]
        guard let separator = separators.first(where: { line.contains($0.0) }),
              let range = line.range(of: separator.0) else { return nil }
        let domainText = String(line[..<range.lowerBound]).replacingOccurrences(of: ",", with: "|")
        var selector = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !selector.isEmpty else { return nil }
        let domains = parseDomainList(domainText)
        var action = separator.2
        var argument: String?

        if action == .scriptlet {
            argument = selector
            selector = ""
        } else if selector.hasPrefix("+js("), selector.hasSuffix(")") {
            action = .scriptlet
            argument = String(selector.dropFirst(4).dropLast())
            selector = ""
        } else if selector.hasPrefix("^") {
            action = .scriptlet
            argument = selector
            selector = ""
        } else if selector.hasSuffix(":remove()") {
            action = .remove
            selector.removeLast(9)
        } else if let extracted = extractTrailingOperator("style", from: selector) {
            action = .style
            selector = extracted.selector
            argument = extracted.argument
        } else if selector.contains(":has-text(") || selector.contains(":matches-") || selector.contains(":xpath(") || selector.contains(":upward(") || selector.contains(":remove-attr(") || selector.contains(":remove-class(") {
            action = .procedural
        }

        return AdblockCosmeticRule(selector: selector, includedDomains: domains.included, excludedDomains: domains.excluded, isException: separator.1, action: action, argument: argument)
    }

    private func splitPatternAndOptions(_ body: String) -> (pattern: String, options: [String], isRegularExpression: Bool) {
        // Wyrażenie regularne ma postać /regex/ lub /regex/$opcje. Wzorce ścieżek, np. /ads/banner.js$script,
        // zaczynają się od "/", ale po ostatnim "/" nie mają ani końca linii, ani "$" — to zwykły wzorzec.
        if body.hasPrefix("/"), body.count > 2, let closingSlash = body.dropFirst().lastIndex(of: "/") {
            let patternEnd = body.index(after: closingSlash)
            let suffix = String(body[patternEnd...])
            if suffix.isEmpty || suffix.hasPrefix("$") {
                let regex = String(body[body.index(after: body.startIndex)..<closingSlash])
                if !regex.isEmpty {
                    return (regex, suffix.hasPrefix("$") ? splitOptions(String(suffix.dropFirst())) : [], true)
                }
            }
        }
        let split = body.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(split[0]), split.count == 2 ? splitOptions(String(split[1])) : [], false)
    }

    private func splitOptions(_ value: String) -> [String] {
        var options: [String] = []
        var current = ""
        var escaped = false
        for character in value {
            if character == ",", !escaped { options.append(current); current = "" } else { current.append(character) }
            if character == "\\" { escaped.toggle() } else { escaped = false }
        }
        if !current.isEmpty { options.append(current) }
        return options
    }

    private func extractTrailingOperator(_ name: String, from selector: String) -> (selector: String, argument: String)? {
        let marker = ":\(name)("
        guard selector.hasSuffix(")"), let range = selector.range(of: marker, options: .backwards) else { return nil }
        return (String(selector[..<range.lowerBound]), String(selector[range.upperBound..<selector.index(before: selector.endIndex)]))
    }

    private func parseDomainList(_ value: String) -> (included: [String], excluded: [String]) {
        var included: Set<String> = []
        var excluded: Set<String> = []
        for item in value.split(separator: "|") {
            let domain = item.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !domain.isEmpty else { continue }
            if domain.hasPrefix("~") { excluded.insert(String(domain.dropFirst())) } else { included.insert(domain) }
        }
        return (included.sorted(), excluded.sorted())
    }

    private func isSafeParameterName(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        return !value.isEmpty && value.count <= 128 && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func domainHost(from pattern: String) -> String? {
        guard pattern.hasPrefix("||") else { return nil }
        let candidate = pattern.dropFirst(2).prefix { $0 != "^" && $0 != "/" && $0 != "*" && $0 != "|" }
        let host = String(candidate).lowercased()
        return host.contains(".") ? host : nil
    }

    private static func badFilterKey(_ line: String) -> String? {
        guard !line.contains("##"), !line.contains("#?#"), !line.contains("#$#") else { return nil }
        let isException = line.hasPrefix("@@")
        let body = isException ? String(line.dropFirst(2)) : line
        let split = body.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
        guard split.count == 2 else { return nil }
        let options = split[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard options.contains(where: { $0.caseInsensitiveCompare("badfilter") == .orderedSame }) else { return nil }
        let retained = options.filter { $0.caseInsensitiveCompare("badfilter") != .orderedSame }
        let rebuilt = (isException ? "@@" : "") + String(split[0]) + (retained.isEmpty ? "" : "$" + retained.joined(separator: ","))
        return canonicalRuleKey(rebuilt)
    }

    private static func canonicalRuleKey(_ line: String) -> String {
        let isException = line.hasPrefix("@@")
        let body = isException ? String(line.dropFirst(2)) : line
        let split = body.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
        guard split.count == 2 else { return (isException ? "@@" : "") + body }
        let options = split[1].split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.lowercased() }
            .sorted()
        return (isException ? "@@" : "") + String(split[0]) + "$" + options.joined(separator: ",")
    }

    private static let resourceTypeMap = [
        "document": "top-document", "subdocument": "child-document", "frame": "child-document",
        "script": "script", "image": "image", "stylesheet": "style-sheet", "font": "font",
        "media": "media", "object": "other", "object-subrequest": "other",
        "xmlhttprequest": "fetch", "xhr": "fetch", "ping": "ping", "beacon": "ping",
        "websocket": "websocket", "csp_report": "csp-report", "other": "other", "popup": "popup"
    ]

    private static let supportedMethods: Set<String> = ["connect", "delete", "get", "head", "options", "patch", "post", "put"]
}
