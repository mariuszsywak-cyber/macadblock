import Foundation
import Testing
@testable import MacAdBlockCore

@Test func parserAndCompilersSupportHTTPMethods() throws {
    let parsed = AdblockParser().parse("""
    ||telemetry.example^$xhr,method=post|put,from=example.com
    ||pixel.example^$method=~get
    """)

    #expect(parsed.network.count == 2)
    let positive = try #require(parsed.network.first { $0.pattern.contains("telemetry") })
    #expect(positive.requestMethods == ["post", "put"])
    #expect(positive.includedDomains == ["example.com"])

    let compiler = SafariRuleCompiler(maximumRules: 20)
    let content = compiler.contentBlockerRules(from: parsed)
    #expect(content.contains { $0.trigger.requestMethod == ["post", "put"] })
    #expect(!content.contains { $0.trigger.urlFilter.contains("pixel") })

    let dnr = compiler.declarativeNetRequestRules(from: parsed)
    #expect(dnr.contains { $0.condition.requestMethods == ["post", "put"] })
    #expect(dnr.contains { $0.condition.excludedRequestMethods == ["get"] })
}

@Test func adblockParserDeduplicatesAndReadsOptions() {
    let text = """
    ! comment
    ||ads.example.com^$script,image,domain=example.com|~shop.example.com
    ||ads.example.com^$script,image,domain=example.com|~shop.example.com
    example.com##.advert
    @@||allowed.example.com^
    """
    let parsed = AdblockParser().parse(text)
    #expect(parsed.network.count == 2)
    #expect(parsed.cosmetic.count == 1)
    #expect(parsed.network.contains { $0.action == .allow })
}

@Test func hostsParserValidatesAndDeduplicates() {
    let text = """
    0.0.0.0 ads.example.com ads.example.com
    127.0.0.1 localhost
    ::1 ip6-localhost
    tracker.example.org # comment
    invalid_domain
    """
    let domains = HostsParser().parseHosts(text)
    #expect(domains == ["ads.example.com", "tracker.example.org"])
}

@Test func managedHostsComposerOnlyTouchesOwnedSection() {
    let original = """
    127.0.0.1 localhost
    # BEGIN MacAdBlock managed section
    0.0.0.0 old.example.com
    # END MacAdBlock managed section
    10.0.0.1 internal.example
    """
    let updated = ManagedHostsComposer.replacingManagedSection(in: original, domains: ["new.example.com"])
    #expect(updated.contains("127.0.0.1 localhost"))
    #expect(updated.contains("10.0.0.1 internal.example"))
    #expect(updated.contains("new.example.com"))
    #expect(!updated.contains("old.example.com"))
}

@Test func compilerProducesSafariAndDNRRules() {
    let parsed = AdblockParser().parse("||ads.example.com^\n@@||safe.example.com^\n")
    let compiler = SafariRuleCompiler(maximumRules: 100)
    let safari = compiler.contentBlockerRules(from: parsed)
    let dnr = compiler.declarativeNetRequestRules(from: parsed)
    #expect(safari.count == 5)
    #expect(dnr.count == 3)
    #expect(Set(dnr.map(\.action.type)).isSuperset(of: ["allow", "block"]))
}

@Test func compilerAddsOnetPlaceholderAndSelfPromotionProtection() {
    let rules = SafariRuleCompiler(maximumRules: 20).contentBlockerRules(from: AdblockParser().parse(""))
    #expect(rules.contains { $0.action.selector == "[data-slotplthr]" && $0.trigger.ifDomain == ["*onet.pl"] })
    #expect(rules.contains { $0.action.selector == "[class*='AdSlotPlaceholder_placeholder']" })
    #expect(rules.contains { $0.action.type == "block" && $0.trigger.urlFilter.contains("cacheableShow") })
}

@Test func parserSupportsPrivacyAndAdvancedRequestOptions() {
    let parsed = AdblockParser().parse("""
    ||tracker.example^$third-party,script,~image,match-case,important
    ||analytics.example^$removeparam=utm_source|gclid
    ||cookies.example^$cookie
    ||legacy.example^$https
    @@||trusted.example^$document
    """)
    #expect(parsed.network.count == 5)
    #expect(parsed.network.contains { $0.loadType == "third-party" && $0.isCaseSensitive && $0.isImportant })
    #expect(parsed.network.contains { $0.action == .removeParameters && $0.removeParameters == ["gclid", "utm_source"] })
    #expect(parsed.network.contains { $0.action == .blockCookies })
    #expect(parsed.network.contains { $0.action == .upgradeScheme })
    #expect(parsed.cosmeticExemptDomains.contains("trusted.example"))
}

@Test func parserSupportsExtendedCosmeticRulesAndExceptions() {
    let parsed = AdblockParser().parse("""
    example.com##.advert:remove()
    example.com##.sponsor:style(height: 0 !important)
    example.com#?#div:has-text(Sponsored)
    example.com#@#.allowed-ad
    @@||example.com^$generichide
    """)
    #expect(parsed.cosmetic.contains { $0.action == .remove })
    #expect(parsed.cosmetic.contains { $0.action == .style && $0.argument == "height: 0 !important" })
    #expect(parsed.cosmetic.contains { $0.action == .procedural })
    #expect(parsed.cosmetic.contains { $0.isException })
    #expect(parsed.cosmeticExemptDomains.contains("example.com"))
}

@Test func compilerProducesCookieUpgradeAndParameterRules() throws {
    let parsed = AdblockParser().parse("""
    ||cookies.example^$cookie
    ||legacy.example^$https
    ||analytics.example^$removeparam=utm_source
    """)
    let compiler = SafariRuleCompiler(maximumRules: 100)
    let safari = compiler.contentBlockerRules(from: parsed)
    let dnr = compiler.declarativeNetRequestRules(from: parsed)
    #expect(Set(safari.map(\.action.type)).isSuperset(of: ["block-cookies", "make-https"]))
    #expect(Set(dnr.map(\.action.type)).isSuperset(of: ["modifyHeaders", "upgradeScheme", "redirect"]))
    let data = try JSONEncoder().encode(dnr)
    #expect(!data.isEmpty)
}

@Test func badFilterDisablesEquivalentRuleRegardlessOfOptionOrder() {
    let parsed = AdblockParser().parse("""
    ||ads.example^$script,third-party
    ||ads.example^$third-party,script,badfilter
    ||keep.example^$image
    """)
    #expect(parsed.network.count == 1)
    #expect(parsed.network.first?.pattern == "||keep.example^")
}

@Test func unsupportedModifierCannotCreateOverbroadRule() {
    let parsed = AdblockParser().parse("""
    ||safe.example^$script,replace=/unsafe/value/
    ||supported.example^$script
    """)
    #expect(parsed.network.count == 1)
    #expect(parsed.network.first?.pattern == "||supported.example^")
    #expect(parsed.unsupportedRuleCount == 1)
}

@Test func compilerPreservesExceptionsWhenRuleCapacityIsSmall() {
    let parsed = AdblockParser().parse("""
    ||a.example^
    ||b.example^
    ||c.example^
    @@||safe.example^
    """)
    let rules = SafariRuleCompiler(maximumRules: 2).declarativeNetRequestRules(from: parsed)
    #expect(rules.contains { $0.action.type == "allow" })
}

@Test func importantBlockOverridesRegularExceptionPriority() {
    let parsed = AdblockParser().parse("""
    @@||ads.example^
    ||ads.example^$important
    """)
    let rules = SafariRuleCompiler(maximumRules: 10).declarativeNetRequestRules(from: parsed)
    let allowPriority = rules.first { $0.action.type == "allow" }?.priority ?? 0
    let blockPriority = rules.first { $0.action.type == "block" }?.priority ?? 0
    #expect(blockPriority > allowPriority)
}

@Test func scriptletAndHTMLFiltersAreNeverMisparsedAsNetworkBlocks() {
    let parsed = AdblockParser().parse("""
    example.com#%#//scriptlet('set-constant', 'flag', 'false')
    example.com##^script:has-text(advert)
    example.com$$script[tag-content="advert"]
    ||real.example^$script
    """)
    #expect(parsed.network.count == 1)
    #expect(parsed.network.first?.pattern == "||real.example^")
    // set-constant jest obsługiwany przez rozszerzenie, więc nieobsługiwane zostają tylko dwa filtry HTML.
    #expect(parsed.unsupportedRuleCount == 2)
    #expect(parsed.cosmetic.contains { $0.action == .scriptlet })
}

@Test func pathPatternsAreNotMisparsedAsRegularExpressions() {
    let parsed = AdblockParser().parse("""
    /ads/banner.js$script
    /ads/*$image,domain=example.com
    /^https?:\\/\\/ads\\./$script
    """)
    let path = parsed.network.first { $0.pattern == "/ads/banner.js" }
    #expect(path != nil)
    #expect(path?.isRegularExpression == false)
    #expect(path?.resourceTypes == ["script"])

    let wildcard = parsed.network.first { $0.pattern == "/ads/*" }
    #expect(wildcard?.isRegularExpression == false)
    #expect(wildcard?.includedDomains == ["example.com"])

    let regex = parsed.network.first { $0.isRegularExpression }
    #expect(regex?.pattern == "^https?:\\/\\/ads\\.")
    #expect(regex?.resourceTypes == ["script"])
}

@Test func contentBlockerNeverCombinesIfAndUnlessDomain() {
    let parsed = AdblockParser().parse("""
    ||ads.example^$domain=example.com|~shop.example.com
    ||other.example^$domain=~news.example.org
    example.com,~sub.example.com##.banner
    """)
    let rules = SafariRuleCompiler(maximumRules: 50).contentBlockerRules(from: parsed)
    #expect(!rules.contains { $0.trigger.ifDomain != nil && $0.trigger.unlessDomain != nil })
    #expect(rules.contains { $0.action.type == "ignore-previous-rules" && $0.trigger.ifDomain == ["*shop.example.com"] })
    #expect(rules.contains { $0.trigger.urlFilter.contains("other") && $0.trigger.unlessDomain == ["*news.example.org"] })
}

@Test func contentBlockerRegularExpressionsAvoidUnsupportedSyntax() {
    let parsed = AdblockParser().parse("""
    ||ads.example.com^
    ||track.example.com/pixel^*
    /banner(a|b)/
    /ads\\d+/
    ||plain.example.com^$script
    """)
    let rules = SafariRuleCompiler(maximumRules: 50).contentBlockerRules(from: parsed)
    #expect(rules.contains { $0.trigger.urlFilter.contains("ads\\.example\\.com") })
    #expect(rules.contains { $0.trigger.urlFilter.contains("plain\\.example\\.com") })
    #expect(!rules.contains { $0.trigger.urlFilter.contains("|") })
    #expect(!rules.contains { $0.trigger.urlFilter.contains("(?") })
    #expect(!rules.contains { $0.trigger.urlFilter.contains("banner(") })
    #expect(!rules.contains { $0.trigger.urlFilter.contains("\\d") })
}

@Test func contentBlockerHonoursExcludedResourceTypes() {
    let parsed = AdblockParser().parse("||media.example^$~image")
    let rules = SafariRuleCompiler(maximumRules: 20).contentBlockerRules(from: parsed)
    let rule = rules.first { $0.trigger.urlFilter.contains("media") }
    #expect(rule?.trigger.resourceType != nil)
    #expect(rule?.trigger.resourceType?.contains("image") == false)
    #expect(rule?.trigger.resourceType?.contains("script") == true)
}

@Test func ruleCapacityIsNotFilledInAlphabeticalOrder() {
    let lines = (0..<100).flatMap { index -> [String] in
        let suffix = String(format: "%03d", index)
        return ["||a\(suffix).example^", "||z\(suffix).example^"]
    }
    let parsed = AdblockParser().parse(lines.joined(separator: "\n"))
    let rules = SafariRuleCompiler(maximumRules: 53).contentBlockerRules(from: parsed)
    #expect(rules.contains { $0.trigger.urlFilter.contains("a0") })
    #expect(rules.contains { $0.trigger.urlFilter.contains("z0") })
}

@Test func cosmeticSelectorsCannotInjectCSS() {
    let parsed = AdblockParser().parse("""
    example.com##.ok
    example.org##.bad{background:url(//evil.example/x)}
    """)
    let rules = SafariRuleCompiler(maximumRules: 50).contentBlockerRules(from: parsed)
    #expect(rules.contains { $0.action.selector == ".ok" })
    #expect(!rules.contains { $0.action.selector?.contains("{") == true })
}

@Test func managedHostsComposerKeepsUserLinesWhenEndMarkerIsMissing() {
    let broken = """
    127.0.0.1 localhost
    # BEGIN MacAdBlock managed section
    0.0.0.0 old.example.com
    10.0.0.1 internal.example
    """
    let stripped = ManagedHostsComposer.removingManagedSection(from: broken)
    #expect(stripped.contains("127.0.0.1 localhost"))
    #expect(stripped.contains("10.0.0.1 internal.example"))
    #expect(!stripped.contains("BEGIN MacAdBlock"))

    let crlf = "127.0.0.1 localhost\r\n# BEGIN MacAdBlock managed section\r\n0.0.0.0 old.example.com\r\n# END MacAdBlock managed section\r\n10.0.0.1 internal.example\r\n"
    let cleaned = ManagedHostsComposer.removingManagedSection(from: crlf)
    #expect(!cleaned.contains("old.example.com"))
    #expect(cleaned.contains("internal.example"))
}

@Test func domainListIgnoresCommentLines() {
    let parsed = HostsParser().parseDomains("# Title: Example list\n! note\nads.example.com # inline\n\ntracker.example.org\n")
    #expect(parsed == ["ads.example.com", "tracker.example.org"])
}

@Test func catalogHasUniqueIDsAndHTTPSURLs() {
    let ids = FilterCatalog.all.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(FilterCatalog.all.allSatisfy { $0.url.scheme == "https" })
    #expect(FilterCatalog.all.filter(\.isExtra).allSatisfy { !$0.enabledByDefault })
}

@Test func allowlistAppendsIgnorePreviousRulesAtEnd() {
    let parsed = AdblockParser().parse("||ads.example.com^\nexample.com##.banner\n")
    let rules = SafariRuleCompiler(maximumRules: 100).contentBlockerRules(
        from: parsed,
        allowlist: ["mojbank.pl", "www.sklep.pl", "nieprawidłowa domena", ""]
    )

    let exceptions = rules.suffix(2)
    #expect(exceptions.allSatisfy { $0.action.type == "ignore-previous-rules" })
    #expect(exceptions.compactMap(\.trigger.ifDomain).flatMap { $0 }.sorted() == ["*mojbank.pl", "*sklep.pl"])
    #expect(exceptions.allSatisfy { $0.trigger.unlessDomain == nil })
    // Wyjątki muszą być na końcu listy, inaczej Safari zastosuje późniejsze blokady.
    #expect(rules.dropLast(2).allSatisfy { $0.action.type != "ignore-previous-rules" })
    #expect(rules.count <= 100)
}

@Test func allowlistNeverExceedsRuleBudget() {
    let allowlist = (0..<80).map { "domena\($0).pl" }
    let rules = SafariRuleCompiler(maximumRules: 20).contentBlockerRules(from: AdblockParser().parse("||a.example^"), allowlist: allowlist)
    #expect(rules.count <= 20)
    #expect(!rules.isEmpty)
}

@Test func dynamicRuleLimitIsIndependentFromContentBlockerLimit() {
    let parsed = AdblockParser().parse((0..<40).map { "||host\($0).example^" }.joined(separator: "\n"))
    let compiler = SafariRuleCompiler(maximumRules: 150_000, maximumDynamicRules: 5)
    #expect(compiler.declarativeNetRequestRules(from: parsed).count <= 5)
    #expect(compiler.contentBlockerRules(from: parsed).count > 5)
}

@Test func userSettingsMatchSubdomainsAndNormalizeInput() {
    var settings = UserFilterSettings()
    settings.allow("WWW.Example.COM")
    settings.allow("example.com")
    settings.allow("nieprawidłowa domena")
    // „www.” zawsze sprowadza się do domeny witryny, więc oba wpisy to ten sam wyjątek.
    #expect(settings.normalizedAllowlist == ["example.com"])
    #expect(settings.isAllowlisted("sklep.example.com"))
    #expect(settings.isAllowlisted("www.example.com"))
    #expect(!settings.isAllowlisted("example.com.evil.pl"))

    settings.disallow("www.example.com")
    #expect(settings.normalizedAllowlist.isEmpty)
}

@Test func customSourceRequiresHTTPSAndHasStableIdentifier() {
    #expect(UserFilterSettings.customSource(name: "Moja", url: URL(string: "http://example.com/l.txt")!, format: .adblock) == nil)
    #expect(UserFilterSettings.customSource(name: "  ", url: URL(string: "https://example.com/l.txt")!, format: .adblock) == nil)

    let url = URL(string: "https://example.com/lista.txt")!
    let first = UserFilterSettings.customSource(name: "Moja lista", url: url, format: .hosts, category: .privacy)
    let second = UserFilterSettings.customSource(name: "Inna nazwa", url: url, format: .hosts)
    #expect(first?.id == second?.id)
    #expect(first?.isExtra == true)
    #expect(first?.enabledByDefault == false)
}

@Test func userSettingsFingerprintReactsToEveryChange() {
    let empty = UserFilterSettings()
    var withAllowlist = empty
    withAllowlist.allow("example.com")
    var withRules = empty
    withRules.customRules = "||example.com^"

    #expect(empty.fingerprint != withAllowlist.fingerprint)
    #expect(empty.fingerprint != withRules.fingerprint)
    #expect(withAllowlist.fingerprint != withRules.fingerprint)
}

@Test func userSettingsDecodeToleratesMissingKeys() throws {
    let data = Data(#"{"allowlistedDomains":["example.com"]}"#.utf8)
    let settings = try JSONDecoder().decode(UserFilterSettings.self, from: data)
    #expect(settings.allowlistedDomains == ["example.com"])
    #expect(settings.customRules.isEmpty)
    #expect(settings.customSources.isEmpty)
}

@Test func allowlistNormalizationMatchesHostsParser() {
    // UserFilterSettings powtarza walidację hosta, bo target SafariBlocker nie kompiluje HostsParser.
    let samples = [
        "Example.COM", "www.example.com", "example.com.", "sklep.example.co.uk", "a.b",
        "0.0.0.0", "127.0.0.1", "localhost", "broadcasthost", "0", "::1", "ipv6:::1",
        "-bad.example.com", "bad-.example.com", "x..y", "", "   ", "nieprawidłowa domena",
        String(repeating: "a", count: 64) + ".example.com", "pl"
    ]
    for sample in samples {
        #expect(HostsParser.normalizedDomain(sample) == UserFilterSettings.validatedDomain(sample), "rozbieżność dla \(sample)")
    }
}

@Test func scriptletInvocationParsesBothSyntaxes() {
    let uBlock = ScriptletInvocation.parse("set-constant, adConfig.enabled, false")
    #expect(uBlock?.name == "set-constant")
    #expect(uBlock?.arguments == ["adConfig.enabled", "false"])

    let adGuard = ScriptletInvocation.parse("//scriptlet('json-prune', 'ads playlist.promo')")
    #expect(adGuard?.name == "json-prune")
    #expect(adGuard?.arguments == ["ads playlist.promo"])

    // Przecinek w cudzysłowie należy do argumentu, a nie rozdziela argumentów.
    let quoted = ScriptletInvocation.parse("+js(prevent-setTimeout, '/reklama,baner/', 500)")
    #expect(quoted?.arguments == ["/reklama,baner/", "500"])

    #expect(ScriptletInvocation.isSupported("aopr, blockAdBlock"))
    #expect(!ScriptletInvocation.isSupported("wymyslony-scriptlet, x"))
    #expect(ScriptletInvocation.parse("") == nil)
}

@Test func compilerKeepsOnlySupportedDomainScopedScriptlets() {
    let parsed = AdblockParser().parse("""
    example.com##+js(set-constant, canRunAds, true)
    example.com#@%#//scriptlet('aopr', 'blockAdBlock')
    ##+js(set-constant, globalny, true)
    example.com##+js(wymyslony-scriptlet, x)
    """)
    let payload = SafariRuleCompiler().cosmeticPayload(from: parsed)

    #expect(payload.scriptlets.count == 2)
    #expect(payload.scriptlets.contains { $0.name == "set-constant" && $0.arguments == ["canRunAds", "true"] && !$0.isException })
    #expect(payload.scriptlets.contains { $0.name == "aopr" && $0.isException })
    // Scriptlet bez domeny działałby wszędzie, a nieznana nazwa nie ma implementacji.
    #expect(!payload.scriptlets.contains { $0.arguments.contains("globalny") })
    #expect(!payload.scriptlets.contains { $0.name == "wymyslony-scriptlet" })
    #expect(payload.unsupportedRuleCount == 1)
}

@Test func cosmeticPayloadDecodesWithoutScriptletsKey() throws {
    let data = Data(#"{"rules":[],"exemptDomains":["example.com"],"unsupportedRuleCount":4}"#.utf8)
    let payload = try JSONDecoder().decode(WebExtensionCosmeticPayload.self, from: data)
    #expect(payload.scriptlets.isEmpty)
    #expect(payload.exemptDomains == ["example.com"])
    #expect(payload.unsupportedRuleCount == 4)
}

@Test func diagnosticsMatchesDomainTokensOnlyOnBoundaries() {
    #expect(DomainDiagnostics.lineMentions("||example.com^$third-party", domain: "example.com"))
    #expect(DomainDiagnostics.lineMentions("0.0.0.0 example.com", domain: "example.com"))
    #expect(DomainDiagnostics.lineMentions("||ads.example.com^", domain: "ads.example.com"))
    #expect(DomainDiagnostics.lineMentions("example.com##.banner", domain: "example.com"))

    // Granice muszą odsiać domeny, które tylko zawierają szukany tekst.
    #expect(!DomainDiagnostics.lineMentions("||notexample.com^", domain: "example.com"))
    #expect(!DomainDiagnostics.lineMentions("||example.com.evil.pl^", domain: "example.com"))
    #expect(!DomainDiagnostics.lineMentions("! example.com w komentarzu", domain: "example.com"))
    #expect(!DomainDiagnostics.lineMentions("# 0.0.0.0 example.com", domain: "example.com"))
    #expect(!DomainDiagnostics.lineMentions("||inna.pl^", domain: "example.com"))
}

@Test func diagnosticsReportsSourcesHostsAndCosmeticRules() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("macadblock-diagnostics-\(UUID().uuidString)", isDirectory: true)
    let storage = try SharedStorage(rootURL: root)
    defer { try? FileManager.default.removeItem(at: root) }

    let source = FilterSource(
        id: "testowa",
        name: "Lista testowa",
        url: URL(string: "https://example.org/lista.txt")!,
        format: .adblock,
        category: .ads,
        enabledByDefault: true,
        homepage: URL(string: "https://example.org")!
    )
    try storage.write(Data("||ads.example.com^$script\n||notexample.com^\n".utf8), to: storage.cacheURL(for: source))
    try storage.write(Data("ads.example.com\ninne.pl\n".utf8), to: storage.hostsDomainsURL)

    let parsed = AdblockParser().parse("""
    ads.example.com##.banner
    ads.example.com##+js(set-constant, canRunAds, true)
    """)
    try storage.writeJSON(SafariRuleCompiler().cosmeticPayload(from: parsed), to: storage.webExtensionCosmeticRulesURL)

    let diagnostics = DomainDiagnostics(storage: storage)
    let found = diagnostics.diagnose("WWW.Ads.Example.com", sources: [source], settings: .empty)
    #expect(found?.domain == "ads.example.com")
    #expect(found?.blockedByHosts == true)
    #expect(found?.matchingSources == ["Lista testowa"])
    #expect(found?.cosmeticRuleCount == 1)
    #expect(found?.scriptletNames == ["set-constant"])
    #expect(found?.sampleRules.count == 1)
    #expect(found?.isTouchedByProtection == true)

    // Domena nietknięta przez żadną regułę i domena na liście wyjątków.
    let clean = diagnostics.diagnose("inna-strona.pl", sources: [source], settings: .empty)
    #expect(clean?.isTouchedByProtection == false)
    #expect(clean?.scannedSourceCount == 1)

    var settings = UserFilterSettings()
    settings.allow("ads.example.com")
    #expect(diagnostics.diagnose("ads.example.com", sources: [source], settings: settings)?.isAllowlisted == true)
    #expect(diagnostics.diagnose("nieprawidłowa domena", sources: [source], settings: .empty) == nil)
}

@Test func ruleSlicesSplitCapacityAndRepeatAllowlistExceptions() {
    let parsed = AdblockParser().parse((0..<400).map { "||host\($0).example^" }.joined(separator: "\n"))
    let compiler = SafariRuleCompiler(maximumRules: 60)
    let slices = compiler.contentBlockerSlices(from: parsed, allowlist: ["mojbank.pl", "sklep.pl"], sliceCount: 3)

    #expect(slices.count == 3)
    // Każda lista mieści się w limicie Safari i każda kończy się wyjątkami allowlisty,
    // bo Safari ocenia listy niezależnie.
    for slice in slices {
        #expect(slice.count <= 60)
        #expect(slice.suffix(2).allSatisfy { $0.action.type == "ignore-previous-rules" })
    }
    // Trzy listy dają realnie więcej reguł niż jedna.
    let single = compiler.contentBlockerRules(from: parsed, allowlist: ["mojbank.pl", "sklep.pl"])
    #expect(slices.reduce(0) { $0 + $1.count } > single.count * 2)
    #expect(single.count <= 60)

    // Reguły nie mogą się powtarzać między listami.
    let blocked = slices.flatMap { $0.filter { $0.action.type == "block" }.map(\.trigger.urlFilter) }
    #expect(Set(blocked).count == blocked.count)
}

@Test func ruleSlicesStayUsableWhenAllowlistFillsTheBudget() {
    let allowlist = (0..<40).map { "domena\($0).pl" }
    let slices = SafariRuleCompiler(maximumRules: 12).contentBlockerSlices(
        from: AdblockParser().parse("||a.example^"),
        allowlist: allowlist,
        sliceCount: 2
    )
    #expect(slices.count == 2)
    #expect(slices.allSatisfy { $0.count <= 12 })
    #expect(slices.allSatisfy { !$0.isEmpty })
}

@Test func dailyBlocksFillMissingDaysWithZero() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("macadblock-daily-\(UUID().uuidString)", isDirectory: true)
    let storage = try SharedStorage(rootURL: root)
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let today = formatter.string(from: now)
    try storage.writeJSON([today: 12], to: storage.dailyBlocksURL)

    let days = storage.readDailyBlocks(days: 7, now: now)
    #expect(days.count == 7)
    #expect(days.last?.count == 12)
    #expect(days.dropLast().allSatisfy { $0.count == 0 })

    storage.clearBlockLog()
    #expect(storage.readDailyBlocks(days: 7, now: now).allSatisfy { $0.count == 0 })
}

@Test func firewallBuilderRendersRulesInPriorityOrder() throws {
    let config = FirewallConfig(
        enabled: true,
        lockdown: false,
        blockInbound: true,
        rules: [
            FirewallRule(action: .block, direction: .outbound, proto: .tcp, remote: "Tracker.Example.com", port: "443"),
            FirewallRule(action: .allow, direction: .outbound, proto: .any, remote: "10.0.0.0/8"),
            FirewallRule(enabled: false, action: .block, direction: .inbound, remote: "1.2.3.4"),
            FirewallRule(action: .block, direction: .inbound, proto: .any, remote: "", port: "8000:8100")
        ]
    )
    let text = try PFRulesetBuilder.anchorRules(for: config)
    let lines = text.split(separator: "\n").map(String.init)

    let allow = try #require(lines.firstIndex(of: "pass out quick from any to 10.0.0.0/8 keep state"))
    let block = try #require(lines.firstIndex(of: "block drop out quick proto tcp from any to tracker.example.com port 443"))
    #expect(allow < block)
    #expect(lines.contains("block drop in quick proto { tcp, udp } from any to any port 8000:8100"))
    #expect(!text.contains("1.2.3.4"))
    #expect(lines.contains("pass out quick all keep state"))
    #expect(lines.last == "block drop in quick all")
}

@Test func firewallLockdownReplacesOutboundPass() throws {
    let text = try PFRulesetBuilder.anchorRules(for: FirewallConfig(enabled: true, lockdown: true))
    #expect(text.contains("block drop out quick all"))
    #expect(!text.contains("pass out quick all keep state"))
}

@Test func firewallRejectsInjectionAndInvalidValues() throws {
    #expect(PFRulesetBuilder.normalizedRemote("1.2.3.4; pass all") == nil)
    #expect(PFRulesetBuilder.normalizedRemote("example.com\nblock all") == nil)
    #expect(PFRulesetBuilder.normalizedRemote("300.1.1.1") == nil)
    #expect(PFRulesetBuilder.normalizedRemote("10.0.0.0/33") == nil)
    #expect(PFRulesetBuilder.normalizedRemote("fe80::1/64") == "fe80::1/64")
    #expect(PFRulesetBuilder.normalizedRemote("") == "any")
    #expect(PFRulesetBuilder.normalizedPort("70000") == nil)
    #expect(PFRulesetBuilder.normalizedPort("9000:8000") == nil)
    #expect(PFRulesetBuilder.normalizedPort("80 ") == "80")
    #expect(PFRulesetBuilder.normalizedPort("") == "")

    let bad = FirewallConfig(enabled: true, rules: [FirewallRule(remote: "x y")])
    #expect(throws: FirewallError.self) { try PFRulesetBuilder.anchorRules(for: bad) }
}
