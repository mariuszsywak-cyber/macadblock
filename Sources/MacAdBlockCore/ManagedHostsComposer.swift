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
    ///
    /// Dodatkowo usuwa „osierocone” wpisy `0.0.0.0 <domena>` leżące POZA znacznikami. Aktualny kod
    /// zawsze zapisuje takie wpisy wyłącznie wewnątrz sekcji BEGIN…END, więc jeśli taka linia istnieje
    /// poza nią, to wyłącznie pozostałość po starszej wersji programu (sprzed wprowadzenia znaczników),
    /// która pisała listę wprost do /etc/hosts. Bez tego takie wpisy nigdy nie znikały i przy każdej
    /// kolejnej aktualizacji plik tylko rósł (opisane w zgłoszeniu: hosts rozdęty do dwóch kopii listy).
    public static func removingManagedSection(from original: String) -> String {
        // Podział po dowolnym znaku końca linii, nie po samym "\n": w Swifcie "\r\n" jest jednym
        // znakiem, więc plik z zakończeniami CRLF nie dzielił się wcale i sekcja zostawała w środku.
        let lines = original.split(omittingEmptySubsequences: false, whereSeparator: \Character.isNewline)
        func isMarker(_ line: Substring, _ marker: String) -> Bool {
            line.trimmingCharacters(in: .whitespacesAndNewlines) == marker
        }
        func isOrphanedBlockedEntry(_ line: Substring) -> Bool {
            line.hasPrefix("0.0.0.0 ") || line.hasPrefix("0.0.0.0\t")
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
            if !isMarker(line, beginMarker), !isMarker(line, endMarker), !isOrphanedBlockedEntry(line) {
                output.append(line)
            }
            index += 1
        }
        return output.joined(separator: "\n")
    }
}
