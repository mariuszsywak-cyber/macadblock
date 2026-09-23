import Foundation

public struct SafariContentRule: Codable, Sendable {
    public struct Trigger: Codable, Sendable {
        public let urlFilter: String
        public let urlFilterIsCaseSensitive: Bool?
        public let resourceType: [String]?
        public let loadType: [String]?
        public let requestMethod: [String]?
        public let ifDomain: [String]?
        public let unlessDomain: [String]?
        public var loadContext: [String]? = nil

        enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
            case resourceType = "resource-type"
            case loadType = "load-type"
            case requestMethod = "request-method"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
            case loadContext = "load-context"
        }
    }

    public struct Action: Codable, Sendable {
        public let type: String
        public let selector: String?
    }

    public let trigger: Trigger
    public let action: Action
}

public struct DeclarativeNetRequestRule: Codable, Sendable {
    public struct HeaderOperation: Codable, Sendable {
        public let header: String
        public let operation: String
        public let value: String?
    }

    public struct QueryTransform: Codable, Sendable {
        public let removeParams: [String]
    }

    public struct URLTransform: Codable, Sendable {
        public let scheme: String?
        public let queryTransform: QueryTransform?
    }

    public struct Redirect: Codable, Sendable {
        public let transform: URLTransform
    }

    public struct Action: Codable, Sendable {
        public let type: String
        public let redirect: Redirect?
        public let requestHeaders: [HeaderOperation]?
        public let responseHeaders: [HeaderOperation]?
    }

    public struct Condition: Codable, Sendable {
        public let urlFilter: String?
        public let regexFilter: String?
        public let isUrlFilterCaseSensitive: Bool?
        public let resourceTypes: [String]?
        public let excludedResourceTypes: [String]?
        public let requestMethods: [String]?
        public let excludedRequestMethods: [String]?
        public let initiatorDomains: [String]?
        public let excludedInitiatorDomains: [String]?
        public let domainType: String?
    }

    public let id: Int
    public let priority: Int
    public let action: Action
    public let condition: Condition
}

public struct WebExtensionCosmeticPayload: Codable, Sendable {
    public let rules: [AdblockCosmeticRule]
    public let exemptDomains: [String]
    public let unsupportedRuleCount: Int
    /// Scriptlety do wykonania na stronie. Puste dla starszych, zapisanych wcześniej ładunków.
    public let scriptlets: [ScriptletInvocation]

    public init(
        rules: [AdblockCosmeticRule],
        exemptDomains: [String],
        unsupportedRuleCount: Int,
        scriptlets: [ScriptletInvocation] = []
    ) {
        self.rules = rules
        self.exemptDomains = exemptDomains
        self.unsupportedRuleCount = unsupportedRuleCount
        self.scriptlets = scriptlets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rules = try container.decode([AdblockCosmeticRule].self, forKey: .rules)
        exemptDomains = try container.decode([String].self, forKey: .exemptDomains)
        unsupportedRuleCount = try container.decode(Int.self, forKey: .unsupportedRuleCount)
        scriptlets = (try? container.decode([ScriptletInvocation].self, forKey: .scriptlets)) ?? []
    }
}

public struct SafariRuleCompiler: Sendable {
    /// Limit reguł klasycznego Content Blockera (Safari odrzuca całą listę po jego przekroczeniu).
    public let maximumRules: Int
    /// Limit reguł dynamicznych Web Extension (declarativeNetRequest), znacznie niższy niż limit
    /// Content Blockera. Gdy nie podano wartości, używany jest ten sam limit co dla Content Blockera.
    public let maximumDynamicRules: Int

    public init(maximumRules: Int = 45_000, maximumDynamicRules: Int? = nil) {
        self.maximumRules = maximumRules
        self.maximumDynamicRules = maximumDynamicRules ?? maximumRules
    }

    /// Reguły dla klasycznego Content Blockera. Domeny z `allowlist` dostają na końcu listy
    /// regułę `ignore-previous-rules`, która wyłącza wszystkie wcześniejsze blokady i ukrywanie
    /// elementów na tych stronach. Kolejność ma znaczenie: Safari stosuje reguły po kolei.
    public func contentBlockerRules(from parsed: ParsedAdblockRules, allowlist: [String] = []) -> [SafariContentRule] {
        contentBlockerSlices(from: parsed, allowlist: allowlist, maximumSliceCount: 1).first ?? []
    }

    /// Reguły podzielone na osobne listy dla kolejnych Content Blockerów. Każda lista jest przez Safari
    /// oceniana niezależnie, dlatego wyjątki allowlisty muszą znaleźć się na końcu każdej z nich —
    /// `ignore-previous-rules` z jednej listy nie odwołuje blokady z innej.
    ///
    /// Liczba zwróconych list jest liczona dynamicznie: używamy tylko tylu blokerów, ile faktycznie
    /// potrzeba na zmieszczenie wszystkich reguł, aż do `maximumSliceCount` (rozmiar puli wbudowanych
    /// w aplikację rozszerzeń). Dzięki temu włączenie kolejnych list filtrów samo "odpala" kolejne
    /// uśpione Content Blockery zamiast wymagać ręcznej zmiany w kodzie za każdym razem.
    public func contentBlockerSlices(
        from parsed: ParsedAdblockRules,
        allowlist: [String] = [],
        maximumSliceCount: Int = SharedStorage.maximumContentBlockerSliceCount
    ) -> [[SafariContentRule]] {
        let maxSlices = max(1, maximumSliceCount)
        let exceptions = Self.allowlistExceptionRules(for: allowlist, limit: maximumRules)
        let perSlice = max(0, maximumRules - exceptions.count)
        guard perSlice > 0 else { return [exceptions] }

        let rules = contentRules(from: parsed, budget: perSlice * maxSlices)
        let neededSlices = min(maxSlices, max(1, (rules.count + perSlice - 1) / perSlice))

        var result: [[SafariContentRule]] = []
        var index = 0
        for _ in 0..<neededSlices {
            let end = min(index + perSlice, rules.count)
            result.append(Array(rules[index..<end]) + exceptions)
            index = end
        }
        return result
    }

    private func contentRules(from parsed: ParsedAdblockRules, budget: Int) -> [SafariContentRule] {
        var rules = Array(Self.platformContentRules.prefix(budget))
        let networkCapacity = max(0, budget - rules.count - min(parsed.cosmetic.count, budget / 4))
        let selectedNetwork = prioritized(parsed.network).prefix(networkCapacity)
        for rule in selectedNetwork.sorted(by: contentRuleOrder) where rules.count < budget {
            guard rule.action != .removeParameters,
                  rule.excludedRequestMethods.isEmpty,
                  let regex = Self.regex(from: rule.pattern, isRegularExpression: rule.isRegularExpression),
                  Self.isSafariCompatibleRegex(regex) else { continue }
            let actionType: String
            switch rule.action {
            case .block: actionType = "block"
            case .allow: actionType = "ignore-previous-rules"
            case .blockCookies: actionType = "block-cookies"
            case .upgradeScheme: actionType = "make-https"
            case .removeParameters: continue
            }

            // Safari nie pozwala łączyć if-domain z unless-domain w jednym triggerze — jedna taka reguła
            // unieważniłaby całą listę. Wykluczenia przy regule z listą domen trafiają do osobnej reguły
            // ignore-previous-rules umieszczonej bezpośrednio po niej.
            let exclusions = Set(rule.excludedDomains + (rule.includedDomains.isEmpty ? Array(parsed.genericNetworkExemptDomains) : [])).sorted()
            let trigger = contentTrigger(for: rule, regex: regex, ifDomains: rule.includedDomains, unlessDomains: exclusions)
            if let types = trigger.resourceType, types.isEmpty { continue }
            rules.append(SafariContentRule(trigger: trigger, action: .init(type: actionType, selector: nil)))

            if rule.action != .allow, !rule.includedDomains.isEmpty, !exclusions.isEmpty, rules.count < budget {
                let restore = contentTrigger(for: rule, regex: regex, ifDomains: exclusions, unlessDomains: [])
                rules.append(SafariContentRule(trigger: restore, action: .init(type: "ignore-previous-rules", selector: nil)))
            }
        }

        let cosmeticExceptions = Dictionary(grouping: parsed.cosmetic.filter(\.isException), by: \.selector)
        let globalExemptions = parsed.cosmeticExemptDomains.sorted()
        for rule in parsed.cosmetic.sorted(by: cosmeticRuleOrder) where rules.count < budget {
            guard !rule.isException, rule.action == .hide, Self.isNativeCSSSelector(rule.selector) else { continue }
            let selectorExemptions = cosmeticExceptions[rule.selector, default: []].flatMap(\.includedDomains)
            let included = rule.includedDomains
            let exclusions = Set(rule.excludedDomains + selectorExemptions + (included.isEmpty ? globalExemptions : []))

            let ifDomain: [String]?
            let unlessDomain: [String]?
            if included.isEmpty {
                ifDomain = nil
                unlessDomain = contentDomains(exclusions.sorted())
            } else {
                // if-domain i unless-domain wykluczają się nawzajem. Wykluczenie spoza wskazanych domen jest bez znaczenia;
                // gdy dotyczy którejś z nich, reguła zostaje pominięta (obsłuży ją Web Extension, który zna wyjątki).
                let relevant = exclusions.filter { excluded in
                    included.contains { excluded == $0 || excluded.hasSuffix("." + $0) }
                }
                if !relevant.isEmpty { continue }
                ifDomain = contentDomains(included)
                unlessDomain = nil
            }
            rules.append(SafariContentRule(
                trigger: .init(
                    urlFilter: ".*",
                    urlFilterIsCaseSensitive: nil,
                    resourceType: nil,
                    loadType: nil,
                    requestMethod: nil,
                    ifDomain: ifDomain,
                    unlessDomain: unlessDomain
                ),
                action: .init(type: "css-display-none", selector: rule.selector)
            ))
        }
        return rules
    }

    /// Jedna reguła na domenę: `if-domain` z przedrostkiem `*` obejmuje też subdomeny.
    /// Normalizacja jest taka sama jak w `UserFilterSettings` (m.in. usunięcie przedrostka „www.”),
    /// żeby wyjątek zapisany w aplikacji i w popupie Safari dawał identyczną regułę.
    static func allowlistExceptionRules(for allowlist: [String], limit: Int) -> [SafariContentRule] {
        let domains = Set(allowlist.compactMap(UserFilterSettings.normalizedHost)).sorted()
        guard !domains.isEmpty else { return [] }
        return domains.prefix(max(0, limit / 2)).map { domain in
            SafariContentRule(
                trigger: .init(
                    urlFilter: ".*",
                    urlFilterIsCaseSensitive: nil,
                    resourceType: nil,
                    loadType: nil,
                    requestMethod: nil,
                    ifDomain: ["*" + domain],
                    unlessDomain: nil
                ),
                action: .init(type: "ignore-previous-rules", selector: nil)
            )
        }
    }

    private static let platformContentRules: [SafariContentRule] = [
        SafariContentRule(
            trigger: .init(
                urlFilter: ".*",
                urlFilterIsCaseSensitive: nil,
                resourceType: nil,
                loadType: nil,
                requestMethod: nil,
                ifDomain: ["*onet.pl"],
                unlessDomain: nil
            ),
            action: .init(type: "css-display-none", selector: "[data-slotplthr]")
        ),
        SafariContentRule(
            trigger: .init(
                urlFilter: ".*",
                urlFilterIsCaseSensitive: nil,
                resourceType: nil,
                loadType: nil,
                requestMethod: nil,
                ifDomain: ["*onet.pl"],
                unlessDomain: nil
            ),
            action: .init(type: "css-display-none", selector: "[class*='AdSlotPlaceholder_placeholder']")
        ),
        SafariContentRule(
            trigger: .init(
                urlFilter: ".*cacheableShow.*",
                urlFilterIsCaseSensitive: false,
                resourceType: ["document"],
                loadType: nil,
                requestMethod: nil,
                ifDomain: nil,
                unlessDomain: nil
            ),
            action: .init(type: "block", selector: nil)
        )
    ]

    public func declarativeNetRequestRules(from parsed: ParsedAdblockRules) -> [DeclarativeNetRequestRule] {
        var rules: [DeclarativeNetRequestRule] = []
        let selected = prioritized(parsed.network).prefix(max(0, maximumDynamicRules - 1))
        for rule in selected {
            guard rule.pattern.count <= 2_000 else { continue }
            let mappedTypes = rule.resourceTypes.compactMap { Self.dnrResourceTypeMap($0) }
            let mappedExcludedTypes = rule.excludedResourceTypes.compactMap { Self.dnrResourceTypeMap($0) }
            let action = dnrAction(for: rule)
            let isDocumentException = rule.action == .allow && mappedTypes.contains("main_frame")
            rules.append(DeclarativeNetRequestRule(
                id: rules.count + 1,
                priority: dnrPriority(for: rule),
                action: isDocumentException ? .init(type: "allowAllRequests", redirect: nil, requestHeaders: nil, responseHeaders: nil) : action,
                condition: .init(
                    urlFilter: rule.isRegularExpression ? nil : rule.pattern,
                    regexFilter: rule.isRegularExpression ? rule.pattern : nil,
                    isUrlFilterCaseSensitive: rule.isCaseSensitive ? true : nil,
                    resourceTypes: mappedTypes.isEmpty ? nil : Array(Set(mappedTypes)).sorted(),
                    excludedResourceTypes: mappedExcludedTypes.isEmpty ? nil : Array(Set(mappedExcludedTypes)).sorted(),
                    requestMethods: rule.requestMethods.nilIfEmpty,
                    excludedRequestMethods: rule.excludedRequestMethods.nilIfEmpty,
                    initiatorDomains: rule.includedDomains.isEmpty ? nil : rule.includedDomains,
                    excludedInitiatorDomains: Array(Set(rule.excludedDomains + (rule.includedDomains.isEmpty ? Array(parsed.genericNetworkExemptDomains) : []))).sorted().nilIfEmpty,
                    domainType: rule.loadType == "third-party" ? "thirdParty" : (rule.loadType == "first-party" ? "firstParty" : nil)
                )
            ))
        }
        if rules.count < maximumDynamicRules {
            rules.append(Self.trackingParameterRule(id: rules.count + 1))
        }
        return rules
    }

    public func cosmeticPayload(from parsed: ParsedAdblockRules) -> WebExtensionCosmeticPayload {
        WebExtensionCosmeticPayload(
            rules: parsed.cosmetic.sorted(by: cosmeticRuleOrder),
            exemptDomains: parsed.cosmeticExemptDomains.sorted(),
            unsupportedRuleCount: parsed.unsupportedRuleCount,
            scriptlets: Self.scriptlets(from: parsed)
        )
    }

    /// Scriptlety bez wskazanej domeny działałyby na każdej stronie, dlatego przyjmujemy wyłącznie
    /// reguły domenowe (wyjątki `#@%#` mogą być ogólne, bo tylko wyłączają działanie).
    static func scriptlets(from parsed: ParsedAdblockRules, limit: Int = 20_000) -> [ScriptletInvocation] {
        parsed.cosmetic
            .filter { $0.action == .scriptlet }
            .compactMap { rule -> ScriptletInvocation? in
                guard let raw = rule.argument,
                      let call = ScriptletInvocation.parse(raw),
                      ScriptletInvocation.supportedNames.contains(call.name),
                      rule.isException || !rule.includedDomains.isEmpty else { return nil }
                return ScriptletInvocation(
                    name: call.name,
                    arguments: call.arguments,
                    includedDomains: rule.includedDomains,
                    excludedDomains: rule.excludedDomains,
                    isException: rule.isException
                )
            }
            .sorted {
                if $0.name != $1.name { return $0.name < $1.name }
                if $0.arguments != $1.arguments { return $0.arguments.joined(separator: ",") < $1.arguments.joined(separator: ",") }
                return $0.includedDomains.joined(separator: ",") < $1.includedDomains.joined(separator: ",")
            }
            .prefix(limit)
            .map { $0 }
    }

    private func contentTrigger(
        for rule: AdblockNetworkRule,
        regex: String,
        ifDomains: [String],
        unlessDomains: [String]
    ) -> SafariContentRule.Trigger {
        let types = Self.contentResourceTypes(included: rule.resourceTypes, excluded: rule.excludedResourceTypes)
        return .init(
            urlFilter: regex,
            urlFilterIsCaseSensitive: rule.isCaseSensitive ? true : nil,
            resourceType: types.resourceTypes,
            loadType: rule.loadType.map { [$0] },
            requestMethod: rule.excludedRequestMethods.isEmpty ? rule.requestMethods.nilIfEmpty : nil,
            ifDomain: contentDomains(ifDomains),
            unlessDomain: ifDomains.isEmpty ? contentDomains(unlessDomains) : nil,
            loadContext: types.loadContext
        )
    }

    /// Zamienia wewnętrzne typy zasobów na wartości Safari Content Blocker. Zwraca pustą tablicę,
    /// gdy reguła wymaga typów, których Safari nie potrafi wyrazić (wtedy reguła musi zostać pominięta).
    private static func contentResourceTypes(included: [String], excluded: [String]) -> (resourceTypes: [String]?, loadContext: [String]?) {
        func mapped(_ value: String) -> String? {
            switch value {
            case "top-document", "child-document": "document"
            case "image": "image"
            case "style-sheet": "style-sheet"
            case "script": "script"
            case "font": "font"
            case "media": "media"
            case "popup": "popup"
            case "fetch", "ping", "websocket", "other", "csp-report": "raw"
            default: nil
            }
        }

        var types: Set<String>
        var loadContext: [String]?
        if included.isEmpty {
            guard !excluded.isEmpty else { return (nil, nil) }
            types = ["document", "image", "style-sheet", "script", "font", "media", "popup", "raw", "svg-document"]
            for value in excluded {
                if let type = mapped(value) { types.remove(type) }
            }
        } else {
            types = Set(included.compactMap(mapped))
            let top = included.contains("top-document")
            let child = included.contains("child-document")
            let otherDocumentTypes = included.contains { mapped($0) != "document" }
            if !otherDocumentTypes, top != child { loadContext = [top ? "top-frame" : "child-frame"] }
        }
        return (types.sorted(), loadContext)
    }

    /// Safari akceptuje tylko podzbiór wyrażeń regularnych: bez alternacji, grup nieprzechwytujących,
    /// liczników, klas skrótowych, granic słów i odwołań wstecznych. Jedna nieobsługiwana reguła
    /// powoduje odrzucenie całej listy, dlatego takie reguły są pomijane.
    static func isSafariCompatibleRegex(_ regex: String) -> Bool {
        guard !regex.isEmpty, regex.count < 2_000 else { return false }
        var previousWasBackslash = false
        var previousWasOpenParenthesis = false
        for character in regex {
            if previousWasBackslash {
                if "bBdDsSwW123456789".contains(character) { return false }
                previousWasBackslash = false
                previousWasOpenParenthesis = false
                continue
            }
            switch character {
            case "\\":
                previousWasBackslash = true
            case "|", "{", "}":
                return false
            case "?" where previousWasOpenParenthesis:
                return false
            default:
                break
            }
            previousWasOpenParenthesis = character == "("
        }
        return true
    }

    private func contentDomains(_ domains: [String]) -> [String]? {
        let values = domains.map { $0.hasPrefix("*") ? $0 : "*\($0)" }
        return values.isEmpty ? nil : values
    }

    private func dnrAction(for rule: AdblockNetworkRule) -> DeclarativeNetRequestRule.Action {
        switch rule.action {
        case .block:
            return .init(type: "block", redirect: nil, requestHeaders: nil, responseHeaders: nil)
        case .allow:
            return .init(type: "allow", redirect: nil, requestHeaders: nil, responseHeaders: nil)
        case .blockCookies:
            return .init(type: "modifyHeaders", redirect: nil, requestHeaders: [.init(header: "cookie", operation: "remove", value: nil)], responseHeaders: nil)
        case .upgradeScheme:
            return .init(type: "upgradeScheme", redirect: nil, requestHeaders: nil, responseHeaders: nil)
        case .removeParameters:
            let transform = DeclarativeNetRequestRule.URLTransform(scheme: nil, queryTransform: .init(removeParams: rule.removeParameters))
            return .init(type: "redirect", redirect: .init(transform: transform), requestHeaders: nil, responseHeaders: nil)
        }
    }

    private static func trackingParameterRule(id: Int) -> DeclarativeNetRequestRule {
        let parameters = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "utm_id", "gclid", "dclid", "fbclid", "msclkid", "mc_cid", "mc_eid", "igshid"]
        return .init(
            id: id,
            priority: 2,
            action: .init(type: "redirect", redirect: .init(transform: .init(scheme: nil, queryTransform: .init(removeParams: parameters))), requestHeaders: nil, responseHeaders: nil),
            condition: .init(urlFilter: "|http", regexFilter: nil, isUrlFilterCaseSensitive: nil, resourceTypes: ["main_frame"], excludedResourceTypes: nil, requestMethods: nil, excludedRequestMethods: nil, initiatorDomains: nil, excludedInitiatorDomains: nil, domainType: nil)
        )
    }

    private func contentRuleOrder(_ lhs: AdblockNetworkRule, _ rhs: AdblockNetworkRule) -> Bool {
        let leftRank = semanticRank(lhs)
        let rightRank = semanticRank(rhs)
        if leftRank != rightRank { return leftRank < rightRank }
        return lhs.pattern < rhs.pattern
    }

    /// Kolejność wybierania reguł, gdy lista przekracza limit: najpierw wyjątki i reguły `important`,
    /// potem blokady domen (`||host^`), a w obrębie tej samej grupy — deterministyczna, ale nie alfabetyczna
    /// kolejność (dzięki temu przy obcięciu nie tracimy z góry całych końcówek alfabetu).
    private func prioritized(_ rules: Set<AdblockNetworkRule>) -> [AdblockNetworkRule] {
        rules
            .map { rule in
                (
                    rule: rule,
                    rank: capacityRank(rule),
                    specificity: (!rule.isRegularExpression && rule.pattern.hasPrefix("||")) ? 0 : 1,
                    hash: Self.stableHash(rule.pattern)
                )
            }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                if lhs.specificity != rhs.specificity { return lhs.specificity < rhs.specificity }
                if lhs.hash != rhs.hash { return lhs.hash < rhs.hash }
                return lhs.rule.pattern < rhs.rule.pattern
            }
            .map { $0.rule }
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }

    private func capacityRank(_ rule: AdblockNetworkRule) -> Int {
        if rule.action == .allow { return rule.isImportant ? 0 : 1 }
        if rule.isImportant { return 2 }
        if rule.action != .block { return 3 }
        return 4
    }

    private func semanticRank(_ rule: AdblockNetworkRule) -> Int {
        switch (rule.isImportant, rule.action == .allow) {
        case (false, false): 0
        case (false, true): 1
        case (true, false): 2
        case (true, true): 3
        }
    }

    private func dnrPriority(for rule: AdblockNetworkRule) -> Int {
        switch (rule.isImportant, rule.action == .allow) {
        case (false, false): 1
        case (false, true): 100_000
        case (true, false): 200_000
        case (true, true): 300_000
        }
    }

    private func cosmeticRuleOrder(_ lhs: AdblockCosmeticRule, _ rhs: AdblockCosmeticRule) -> Bool {
        if lhs.isException != rhs.isException { return !lhs.isException }
        if lhs.includedDomains.count != rhs.includedDomains.count { return lhs.includedDomains.count > rhs.includedDomains.count }
        return lhs.selector < rhs.selector
    }

    public static func regex(from adblockPattern: String, isRegularExpression: Bool = false) -> String? {
        guard !adblockPattern.isEmpty, adblockPattern.count < 2_000 else { return nil }
        if isRegularExpression { return adblockPattern }
        var pattern = adblockPattern
        let domainAnchored = pattern.hasPrefix("||")
        let leftAnchored = !domainAnchored && pattern.hasPrefix("|")
        let rightAnchored = pattern.hasSuffix("|")
        if domainAnchored { pattern.removeFirst(2) } else if leftAnchored { pattern.removeFirst() }
        if rightAnchored { pattern.removeLast() }

        // Separator "^" (dowolny znak poza literą, cyfrą, "_", "-", ".", "%") tłumaczymy na klasę znaków.
        // Alternacja "(?:...|$)" nie jest obsługiwana przez Safari, a adres URL w filtrze zawsze
        // zawiera co najmniej "/" po hoście, więc wymaganie jednego znaku jest tu bezpieczne.
        var escaped = ""
        for character in pattern {
            switch character {
            case "*": escaped += ".*"
            case "^": escaped += "[^A-Za-z0-9_.%-]"
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "\\", "|", "$": escaped += "\\\(character)"
            default: escaped.append(character)
            }
        }
        if domainAnchored { return "^[a-z][a-z0-9+.-]*://([^/]+\\.)?\(escaped)" }
        return (leftAnchored ? "^" : "") + escaped + (rightAnchored ? "$" : "")
    }

    private static func isNativeCSSSelector(_ selector: String) -> Bool {
        !selector.isEmpty
            && selector.count <= 8_000
            && !selector.contains(where: { "{};<>".contains($0) || $0.isNewline })
            && !selector.contains("/*")
            && ![":-abp-", ":has-text(", ":matches-", ":xpath(", ":upward(", ":remove-", ":style("].contains { selector.contains($0) }
    }

    private static func dnrResourceTypeMap(_ value: String) -> String? {
        [
            "top-document": "main_frame", "child-document": "sub_frame", "style-sheet": "stylesheet",
            "script": "script", "image": "image", "font": "font", "media": "media", "fetch": "xmlhttprequest",
            "ping": "ping", "websocket": "websocket", "popup": "main_frame", "other": "other", "csp-report": "other"
        ][value]
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
