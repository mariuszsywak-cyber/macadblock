import Foundation

public struct UpdateStatistics: Codable, Sendable {
    public var lastUpdated: Date?
    public var sourceCount: Int
    public var networkRuleCount: Int
    public var cosmeticRuleCount: Int
    public var contentBlockerRuleCount: Int
    public var webExtensionRuleCount: Int
    public var hostDomainCount: Int
    public var cacheHits: Int
    public var unsupportedRuleCount: Int

    public static let empty = UpdateStatistics(
        lastUpdated: nil,
        sourceCount: 0,
        networkRuleCount: 0,
        cosmeticRuleCount: 0,
        contentBlockerRuleCount: 0,
        webExtensionRuleCount: 0,
        hostDomainCount: 0,
        cacheHits: 0,
        unsupportedRuleCount: 0
    )
}

public struct FilterUpdateFailure: Error, Sendable {
    public let source: FilterSource
    public let message: String
}

public struct FilterUpdateResult: Sendable {
    public let statistics: UpdateStatistics
    public let failures: [FilterUpdateFailure]
}

/// Etap aktualizacji list, zgłaszany przez `FilterUpdateService.update` do interfejsu, żeby pokazać
/// pasek postępu z podpisem tego, co aktualnie się dzieje.
public enum FilterUpdateStage: Sendable, Equatable {
    /// `lastSourceName`/`lastSourceFormat` opisują listę, która właśnie się pobrała (pobieranie
    /// trwa równolegle, więc to najświeżej ukończona, nie jedna „aktualnie” ściągana pozycja).
    case downloading(completed: Int, total: Int, lastSourceName: String?, lastSourceFormat: FilterFormat?)
    case parsing
    case compiling
    case writing
}

public actor FilterUpdateService {
    private let storage: SharedStorage
    private let downloader: FilterDownloader
    private let adblockParser = AdblockParser()
    private let hostsParser = HostsParser()
    private let compiler: SafariRuleCompiler

    public init(storage: SharedStorage, downloader: FilterDownloader? = nil, compiler: SafariRuleCompiler = .init()) {
        self.storage = storage
        self.downloader = downloader ?? FilterDownloader(storage: storage)
        self.compiler = compiler
    }

    /// `userSettings` pochodzi z pliku w App Group. Wyjątki są usuwane z listy domen dla `/etc/hosts`
    /// i DNS proxy (oba czytają ten sam plik), a do Content Blockera trafiają jako reguły wyłączające.
    public func update(
        sources: [FilterSource],
        userSettings: UserFilterSettings = .empty,
        progress: (@Sendable (FilterUpdateStage) -> Void)? = nil
    ) async throws -> FilterUpdateResult {
        var downloads: [DownloadedFilter] = []
        var failures: [FilterUpdateFailure] = []
        let total = sources.count
        progress?(.downloading(completed: 0, total: total, lastSourceName: nil, lastSourceFormat: nil))

        await withTaskGroup(of: Result<DownloadedFilter, FilterUpdateFailure>.self) { group in
            for source in sources {
                group.addTask { [downloader] in
                    do {
                        return .success(try await downloader.download(source))
                    } catch {
                        if let cached = await downloader.cached(source) {
                            return .success(cached)
                        }
                        return .failure(FilterUpdateFailure(source: source, message: error.localizedDescription))
                    }
                }
            }
            var completed = 0
            for await result in group {
                let finishedSource: FilterSource
                switch result {
                case .success(let download):
                    downloads.append(download)
                    finishedSource = download.source
                case .failure(let failure):
                    failures.append(failure)
                    finishedSource = failure.source
                }
                completed += 1
                progress?(.downloading(completed: completed, total: total, lastSourceName: finishedSource.name, lastSourceFormat: finishedSource.format))
            }
        }

        guard !downloads.isEmpty else {
            throw failures.first ?? FilterDownloadError.emptyResponse
        }

        // Jeśli żadne źródło się nie zmieniło, a poprzednie wyniki nadal istnieją, nie parsujemy
        // i nie kompilujemy wszystkiego od nowa (oszczędza CPU i baterię).
        let fingerprint = Self.fingerprint(of: downloads, maximumRules: compiler.maximumRules, userSettings: userSettings)
        if let previous = try? String(contentsOf: storage.compiledFingerprintURL, encoding: .utf8),
           previous == fingerprint,
           Self.outputsExist(in: storage),
           var saved = try? storage.readJSON(UpdateStatistics.self, from: storage.statisticsURL) {
            saved.lastUpdated = Date()
            saved.cacheHits = downloads.filter(\.wasNotModified).count
            try? storage.writeJSON(saved, to: storage.statisticsURL)
            return FilterUpdateResult(statistics: saved, failures: failures.sorted { $0.source.name < $1.source.name })
        }

        progress?(.parsing)
        var parsedRules = ParsedAdblockRules()
        var hostDomains: Set<String> = []
        // Własne reguły użytkownika mają pierwszeństwo w kolejności wyboru, dlatego parsujemy je razem z listami.
        if !userSettings.customRules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = adblockParser.parse(userSettings.customRules)
            parsedRules.network.formUnion(parsed.network)
            parsedRules.cosmetic.formUnion(parsed.cosmetic)
            parsedRules.cosmeticExemptDomains.formUnion(parsed.cosmeticExemptDomains)
            parsedRules.genericNetworkExemptDomains.formUnion(parsed.genericNetworkExemptDomains)
            parsedRules.unsupportedRuleCount += parsed.unsupportedRuleCount
        }
        for download in downloads {
            guard let text = String(data: download.data, encoding: .utf8) else { continue }
            switch download.source.format {
            case .adblock:
                let parsed = adblockParser.parse(text)
                parsedRules.network.formUnion(parsed.network)
                parsedRules.cosmetic.formUnion(parsed.cosmetic)
                parsedRules.cosmeticExemptDomains.formUnion(parsed.cosmeticExemptDomains)
                parsedRules.genericNetworkExemptDomains.formUnion(parsed.genericNetworkExemptDomains)
                parsedRules.unsupportedRuleCount += parsed.unsupportedRuleCount
            case .hosts:
                hostDomains.formUnion(hostsParser.parseHosts(text))
            case .domains:
                hostDomains.formUnion(hostsParser.parseDomains(text))
            }
        }

        let allowlist = userSettings.normalizedAllowlist
        if !allowlist.isEmpty {
            hostDomains = hostDomains.filter { domain in
                !allowlist.contains { domain == $0 || domain.hasSuffix("." + $0) }
            }
        }

        progress?(.compiling)
        let contentSlices = compiler.contentBlockerSlices(from: parsedRules, allowlist: allowlist)
        let webRules = compiler.declarativeNetRequestRules(from: parsedRules)
        let cosmeticPayload = compiler.cosmeticPayload(from: parsedRules)
        progress?(.writing)
        for (index, slice) in contentSlices.enumerated() {
            try storage.writeJSON(slice, to: storage.contentBlockerRulesURL(slice: index))
        }
        // Gdy tym razem potrzeba mniej blokerów niż poprzednio (np. po wyłączeniu list filtrów),
        // czyścimy resztę puli, żeby nieużywane już rozszerzenia nie serwowały nieaktualnych reguł.
        if contentSlices.count < SharedStorage.maximumContentBlockerSliceCount {
            let empty: [SafariContentRule] = []
            for index in contentSlices.count..<SharedStorage.maximumContentBlockerSliceCount {
                try? storage.writeJSON(empty, to: storage.contentBlockerRulesURL(slice: index))
            }
        }
        try storage.writeJSON(webRules, to: storage.webExtensionRulesURL)
        try storage.writeJSON(cosmeticPayload, to: storage.webExtensionCosmeticRulesURL)
        try storage.write(Data((hostDomains.sorted().joined(separator: "\n") + "\n").utf8), to: storage.hostsDomainsURL)

        let statistics = UpdateStatistics(
            lastUpdated: Date(),
            sourceCount: downloads.count,
            networkRuleCount: parsedRules.network.count,
            cosmeticRuleCount: parsedRules.cosmetic.count,
            contentBlockerRuleCount: contentSlices.reduce(0) { $0 + $1.count },
            webExtensionRuleCount: webRules.count,
            hostDomainCount: hostDomains.count,
            cacheHits: downloads.filter(\.wasNotModified).count,
            unsupportedRuleCount: parsedRules.unsupportedRuleCount
        )
        try storage.writeJSON(statistics, to: storage.statisticsURL)
        try? storage.write(Data(fingerprint.utf8), to: storage.compiledFingerprintURL)
        return FilterUpdateResult(statistics: statistics, failures: failures.sorted { $0.source.name < $1.source.name })
    }

    private static func fingerprint(
        of downloads: [DownloadedFilter],
        maximumRules: Int,
        userSettings: UserFilterSettings
    ) -> String {
        let parts = downloads
            .map { "\($0.source.id):\($0.source.format.rawValue):\($0.metadata.sha256)" }
            .sorted()
        return (["v3", "max=\(maximumRules)", "user=\(userSettings.fingerprint)"] + parts).joined(separator: "\n")
    }

    private static func outputsExist(in storage: SharedStorage) -> Bool {
        [
            storage.contentBlockerRulesURL,
            storage.webExtensionRulesURL,
            storage.webExtensionCosmeticRulesURL,
            storage.hostsDomainsURL,
            storage.statisticsURL
        ].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Wynik sprawdzenia jednej domeny: odpowiada na pytanie „dlaczego ta strona nie działa”.
/// Wszystkie dane pochodzą z pobranych list i wygenerowanych plików — nic nie jest szacowane.
public struct DomainDiagnosis: Codable, Sendable, Equatable {
    public let domain: String
    public let isAllowlisted: Bool
    public let blockedByHosts: Bool
    /// Nazwy włączonych list, które zawierają regułę dotyczącą tej domeny.
    public let matchingSources: [String]
    /// Przykładowe reguły z tych list (najwyżej kilka, do pokazania w interfejsie).
    public let sampleRules: [String]
    public let cosmeticRuleCount: Int
    public let scriptletNames: [String]
    public let scannedSourceCount: Int

    public var isTouchedByProtection: Bool {
        blockedByHosts || !matchingSources.isEmpty || cosmeticRuleCount > 0 || !scriptletNames.isEmpty
    }
}

/// Sprawdza, co ochrona robi z konkretną domeną. Przeszukiwanie plików cache jest kosztowne,
/// dlatego wywołuje się je na żądanie użytkownika, nie w trakcie aktualizacji.
public struct DomainDiagnostics: Sendable {
    private let storage: SharedStorage
    private let maximumBytesPerSource = 12_000_000
    private let maximumSamplesPerSource = 3

    public init(storage: SharedStorage) {
        self.storage = storage
    }

    public func diagnose(
        _ rawDomain: String,
        sources: [FilterSource],
        settings: UserFilterSettings
    ) -> DomainDiagnosis? {
        guard let domain = UserFilterSettings.normalizedHost(rawDomain) else { return nil }

        var matchingSources: [String] = []
        var samples: [String] = []
        var scanned = 0
        for source in sources {
            let url = storage.cacheURL(for: source)
            guard let text = Self.readText(at: url, limit: maximumBytesPerSource) else { continue }
            scanned += 1
            var found = 0
            for line in text.split(whereSeparator: \Character.isNewline) {
                guard found < maximumSamplesPerSource, Self.lineMentions(line, domain: domain) else { continue }
                found += 1
                samples.append("\(source.name): \(line.trimmingCharacters(in: .whitespaces))")
            }
            if found > 0 { matchingSources.append(source.name) }
        }

        let payload = try? storage.readJSON(WebExtensionCosmeticPayload.self, from: storage.webExtensionCosmeticRulesURL)
        let cosmeticCount = (payload?.rules ?? []).filter { rule in
            rule.action != .scriptlet && !rule.isException && Self.domains(rule.includedDomains, contain: domain) && !Self.domains(rule.excludedDomains, contain: domain)
        }.count
        let scriptlets = (payload?.scriptlets ?? []).filter { item in
            !item.isException && Self.domains(item.includedDomains, contain: domain) && !Self.domains(item.excludedDomains, contain: domain)
        }.map(\.name)

        return DomainDiagnosis(
            domain: domain,
            isAllowlisted: settings.isAllowlisted(domain),
            blockedByHosts: Self.hostsBlock(domain, in: storage),
            matchingSources: matchingSources.sorted(),
            sampleRules: Array(samples.prefix(24)),
            cosmeticRuleCount: cosmeticCount,
            scriptletNames: Array(Set(scriptlets)).sorted(),
            scannedSourceCount: scanned
        )
    }

    private static func hostsBlock(_ domain: String, in storage: SharedStorage) -> Bool {
        guard let text = readText(at: storage.hostsDomainsURL, limit: 80_000_000) else { return false }
        for line in text.split(whereSeparator: \Character.isNewline) {
            let entry = line.trimmingCharacters(in: .whitespaces)
            if entry == domain || domain.hasSuffix("." + entry) { return true }
        }
        return false
    }

    private static func domains(_ list: [String], contain domain: String) -> Bool {
        list.contains { entry in
            let normalized = entry.hasPrefix("*") ? String(entry.dropFirst().drop(while: { $0 == "." })) : entry
            return domain == normalized || domain.hasSuffix("." + normalized)
        }
    }

    /// Nazwa domeny musi występować jako osobny element reguły. Bez sprawdzenia granic
    /// „example.com” pasowałoby też do „notexample.com”, co dawałoby mylącą diagnozę.
    static func lineMentions(_ line: Substring, domain: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("!"), !trimmed.hasPrefix("#"), !trimmed.hasPrefix("[") else { return false }
        let lowercased = trimmed.lowercased()
        guard lowercased.contains(domain) else { return false }

        var searchRange = lowercased.startIndex..<lowercased.endIndex
        while let found = lowercased.range(of: domain, range: searchRange) {
            let beforeOK: Bool
            if found.lowerBound == lowercased.startIndex {
                beforeOK = true
            } else {
                let previous = lowercased[lowercased.index(before: found.lowerBound)]
                beforeOK = !(previous.isLetter || previous.isNumber || previous == "-")
            }
            let afterOK: Bool
            if found.upperBound == lowercased.endIndex {
                afterOK = true
            } else {
                let next = lowercased[found.upperBound]
                afterOK = !(next.isLetter || next.isNumber || next == "-" || next == ".")
            }
            if beforeOK && afterOK { return true }
            searchRange = found.upperBound..<lowercased.endIndex
        }
        return false
    }

    private static func readText(at url: URL, limit: Int) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= limit,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
