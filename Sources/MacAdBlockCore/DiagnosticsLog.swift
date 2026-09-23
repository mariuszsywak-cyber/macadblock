import Foundation

/// Jeden wpis dziennika diagnostycznego.
public struct DiagnosticEntry: Codable, Sendable, Identifiable {
    public var id: String { "\(timestamp.timeIntervalSince1970)-\(subsystem)-\(operation)" }
    public let timestamp: Date
    public let subsystem: String
    public let operation: String
    public let message: String

    public init(timestamp: Date = Date(), subsystem: String, operation: String, message: String) {
        self.timestamp = timestamp
        self.subsystem = subsystem
        self.operation = operation
        self.message = message
    }
}

extension SharedStorage {
    /// Trwały log błędów w formacie JSON Lines (jeden obiekt JSON na linię) — przede wszystkim z warstw
    /// uprzywilejowanych (helper XPC, /etc/hosts, firewall, aktualizacje list), gdzie błąd wcześniej
    /// potrafił zawieść po cichu (`try?` połykający wyjątek bez śladu — patrz incydent z niewyczyszczonym
    /// /etc/hosts, który ten log ma pomóc wyłapać następnym razem, zanim urośnie do prawdziwego problemu).
    ///
    /// Plik leży obok innych danych aplikacji w SharedStorage, więc przeżywa restart i można go podejrzeć
    /// bez GUI ani terminala — bezpośrednio z plików projektu. Przycinany do ostatnich
    /// `maximumDiagnosticEntries` wpisów, żeby sam nigdy nie urósł bez końca.
    public var diagnosticsLogURL: URL { rootURL.appendingPathComponent("diagnostics-log.jsonl") }

    private static let maximumDiagnosticEntries = 500

    public func appendDiagnostic(subsystem: String, operation: String, error: Error) {
        appendDiagnostic(subsystem: subsystem, operation: operation, message: error.localizedDescription)
    }

    /// Best-effort: logowanie samo w sobie nigdy nie powinno wywołać błędu widocznego dla użytkownika,
    /// więc każda awaria zapisu (np. brak miejsca) jest po cichu pomijana — to jedyne świadome `try?`
    /// w tym pliku, bo alternatywą byłoby przerywanie prawdziwej operacji z powodu samego logowania.
    ///
    /// Dopisywanie idzie przez `FileHandle` (koszt proporcjonalny do jednej linii), a nie przez
    /// odczyt-i-nadpisanie całego pliku przy KAŻDYM wpisie jak wcześniej — to była realna, zbędna
    /// praca na dysku przy każdym błędzie. Przycinanie do `maximumDiagnosticEntries` (jedyna operacja,
    /// która musi przeczytać cały plik) uruchamia się tylko, gdy plik realnie urośnie ponad zapas.
    public func appendDiagnostic(subsystem: String, operation: String, message: String) {
        let entry = DiagnosticEntry(timestamp: Date(), subsystem: subsystem, operation: operation, message: message)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry) else { return }
        var lineData = data
        lineData.append(UInt8(ascii: "\n"))

        if let handle = try? FileHandle(forWritingTo: diagnosticsLogURL) {
            handle.seekToEndOfFile()
            handle.write(lineData)
            try? handle.close()
        } else {
            try? write(lineData, to: diagnosticsLogURL)
        }

        if let size = (try? FileManager.default.attributesOfItem(atPath: diagnosticsLogURL.path))?[.size] as? NSNumber,
           size.intValue > Self.trimThresholdBytes {
            trimDiagnosticsLog()
        }
    }

    private static let trimThresholdBytes = 200_000

    private func trimDiagnosticsLog() {
        guard let existing = try? String(contentsOf: diagnosticsLogURL, encoding: .utf8) else { return }
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count > Self.maximumDiagnosticEntries else { return }
        lines.removeFirst(lines.count - Self.maximumDiagnosticEntries)
        try? write(Data((lines.joined(separator: "\n") + "\n").utf8), to: diagnosticsLogURL)
    }

    /// Wpisy od najnowszego do najstarszego — do podglądu w GUI (Diagnostyka) albo z zewnątrz
    /// (bezpośredni odczyt pliku `diagnosticsLogURL`).
    public func readDiagnostics(limit: Int = 200) -> [DiagnosticEntry] {
        guard let contents = try? String(contentsOf: diagnosticsLogURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(DiagnosticEntry.self, from: Data($0.utf8)) }
        return Array(entries.reversed().prefix(limit))
    }

    public func clearDiagnostics() {
        try? FileManager.default.removeItem(at: diagnosticsLogURL)
    }
}
