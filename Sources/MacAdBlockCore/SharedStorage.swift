import Foundation

public struct SharedStorage: Sendable {
    public static let appGroupIdentifier = "group.com.italiano88.MacAdBlock"

    public enum StorageError: LocalizedError {
        case appGroupUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .appGroupUnavailable(let identifier):
                "Brak kontenera App Group: \(identifier). Skonfiguruj identyczny App Group dla aplikacji i rozszerzeń."
            }
        }
    }

    public let rootURL: URL

    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        try createDirectories()
    }

    public init(appGroupIdentifier: String = Self.appGroupIdentifier) throws {
        guard let rootURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw StorageError.appGroupUnavailable(appGroupIdentifier)
        }
        self.rootURL = rootURL
        try createDirectories()
    }

    public static func applicationFallback() throws -> SharedStorage {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try SharedStorage(rootURL: base.appendingPathComponent("MacAdBlock", isDirectory: true))
    }

    public var cacheDirectory: URL { rootURL.appendingPathComponent("FilterCache", isDirectory: true) }
    public var generatedDirectory: URL { rootURL.appendingPathComponent("Generated", isDirectory: true) }
    public var metadataURL: URL { rootURL.appendingPathComponent("download-metadata.json") }
    public var statisticsURL: URL { rootURL.appendingPathComponent("statistics.json") }
    /// Safari stosuje limit reguł do każdego rozszerzenia osobno, dlatego reguły są dzielone
    /// na kilka list, a każdy Content Blocker dostaje swoją część. To jest rozmiar CAŁEJ puli
    /// wbudowanych w aplikację rozszerzeń (uśpionych, dopóki nie są potrzebne) — faktyczna liczba
    /// użytych wycinków jest liczona dynamicznie w SafariRuleCompiler.contentBlockerSlices i rośnie
    /// tylko wtedy, gdy reguły przestają się mieścić w mniejszej liczbie blokerów.
    public static let maximumContentBlockerSliceCount = 8

    public var contentBlockerRulesURL: URL { contentBlockerRulesURL(slice: 0) }

    public func contentBlockerRulesURL(slice: Int) -> URL {
        let name = slice <= 0 ? "blockerList.json" : "blockerList-\(slice).json"
        return generatedDirectory.appendingPathComponent(name)
    }
    public var webExtensionRulesURL: URL { generatedDirectory.appendingPathComponent("dnr-rules.json") }
    public var webExtensionCosmeticRulesURL: URL { generatedDirectory.appendingPathComponent("cosmetic-rules.json") }
    public var hostsDomainsURL: URL { generatedDirectory.appendingPathComponent("hosts-domains.txt") }
    public var compiledFingerprintURL: URL { generatedDirectory.appendingPathComponent("compiled-fingerprint.txt") }
    /// Wyjątki, własne reguły i własne listy. Zapisuje je aplikacja oraz rozszerzenie Safari
    /// (popup i element picker), dlatego plik leży w katalogu głównym kontenera App Group.
    public var userSettingsURL: URL { rootURL.appendingPathComponent("user-settings.json") }

    public func readUserSettings() -> UserFilterSettings {
        (try? readJSON(UserFilterSettings.self, from: userSettingsURL)) ?? .empty
    }

    public func writeUserSettings(_ settings: UserFilterSettings) throws {
        try writeJSON(settings, to: userSettingsURL)
    }

    /// Dziennik domen zablokowanych przez DNS proxy. Zapisuje go rozszerzenie sieciowe,
    /// aplikacja tylko go odczytuje i czyści.
    public var blockLogURL: URL { rootURL.appendingPathComponent("Generated/blocked-log.json") }

    public func readBlockLog() -> [BlockedLogEntry] {
        ((try? readJSON([BlockedLogEntry].self, from: blockLogURL)) ?? []).sorted { $0.last > $1.last }
    }

    public func clearBlockLog() {
        try? FileManager.default.removeItem(at: blockLogURL)
        try? FileManager.default.removeItem(at: dailyBlocksURL)
    }

    /// Dzienne liczniki blokad DNS (klucz `yyyy-MM-dd` w czasie lokalnym). Zapisuje je DNS proxy.
    public var dailyBlocksURL: URL { rootURL.appendingPathComponent("Generated/blocked-daily.json") }

    /// Ostatnie `days` dni od najstarszego do dzisiejszego; dni bez blokad mają zero.
    public func readDailyBlocks(days: Int, now: Date = Date()) -> [DailyBlockCount] {
        let stored = (try? readJSON([String: Int].self, from: dailyBlocksURL)) ?? [:]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: now)
        return (0..<max(1, days)).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DailyBlockCount(day: day, count: stored[formatter.string(from: day)] ?? 0)
        }
    }

    /// Data ostatniej zmiany pliku ustawień — pozwala aplikacji zauważyć wyjątek dodany w Safari.
    public var userSettingsModificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: userSettingsURL.path))?[.modificationDate] as? Date
    }

    /// Usuwa odcisk ostatniej kompilacji, aby kolejna aktualizacja przebudowała reguły nawet wtedy,
    /// gdy żadne źródło się nie zmieniło (np. po wyłączeniu i ponownym włączeniu ochrony).
    public func invalidateCompiledFingerprint() {
        try? FileManager.default.removeItem(at: compiledFingerprintURL)
    }

    public func cacheURL(for source: FilterSource) -> URL {
        cacheDirectory.appendingPathComponent(source.id).appendingPathExtension("txt")
    }

    public func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    public func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try write(encoder.encode(value), to: url)
    }

    public func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func createDirectories() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: generatedDirectory, withIntermediateDirectories: true)
    }
}

public struct DailyBlockCount: Sendable, Identifiable, Equatable {
    public var day: Date
    public var count: Int
    public var id: Date { day }

    public init(day: Date, count: Int) {
        self.day = day
        self.count = count
    }
}

public struct BlockedLogEntry: Codable, Sendable, Identifiable, Equatable {
    public var domain: String
    public var count: Int
    /// Sekundy od 1970 — format zapisywany przez DNS proxy bez zależności od Core.
    public var last: Double

    public var id: String { domain }
    public var lastDate: Date { Date(timeIntervalSince1970: last) }

    public init(domain: String, count: Int, last: Double) {
        self.domain = domain
        self.count = count
        self.last = last
    }
}
