import Foundation

public enum ManagedHostsComposer {
    public static let beginMarker = "# BEGIN MacAdBlock managed section"
    public static let endMarker = "# END MacAdBlock managed section"

    public static func replacingManagedSection(in original: String, domains: [String]) -> String {
        let stripped = removingManagedSection(from: original).trimmingCharacters(in: .newlines)
        let validDomains = Set(domains.compactMap(HostsParser.normalizedDomain)).sorted()
        guard !validDomains.isEmpty else { return stripped + "\n" }

        let entries = validDomains.map { "0.0.0.0 \($0)" }.joined(separator: "\n")
        return stripped + "\n\n\(beginMarker)\n\(entries)\n\(endMarker)\n"
    }

    /// Usuwa wyłącznie kompletne sekcje BEGIN…END. Znacznik BEGIN bez pasującego END (uszkodzony plik)
    /// nie powoduje wycięcia reszty pliku — linie użytkownika zawsze zostają nietknięte.
    public static func removingManagedSection(from original: String) -> String {
        // Podział po dowolnym znaku końca linii, nie po samym "\n": w Swifcie "\r\n" jest jednym
        // znakiem, więc plik z zakończeniami CRLF nie dzielił się wcale i sekcja zostawała w środku.
        let lines = original.split(omittingEmptySubsequences: false, whereSeparator: \Character.isNewline)
        func isMarker(_ line: Substring, _ marker: String) -> Bool {
            line.trimmingCharacters(in: .whitespacesAndNewlines) == marker
        }

        var output: [Substring] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if isMarker(line, beginMarker),
               let endIndex = lines[(index + 1)...].firstIndex(where: { isMarker($0, endMarker) }) {
                index = endIndex + 1
                continue
            }
            if !isMarker(line, beginMarker), !isMarker(line, endMarker) {
                output.append(line)
            }
            index += 1
        }
        return output.joined(separator: "\n")
    }
}
