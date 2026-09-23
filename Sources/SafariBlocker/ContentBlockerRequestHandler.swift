import Foundation

final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        // Każdy Content Blocker obsługuje inną część reguł; numer części jest w jego Info.plist.
        let slice = Bundle.main.object(forInfoDictionaryKey: "MacAdBlockRuleSliceIndex") as? Int ?? 0
        let rulesURL: URL?
        if let storage = Self.availableStorage(),
           FileManager.default.fileExists(atPath: storage.contentBlockerRulesURL(slice: slice).path) {
            rulesURL = storage.contentBlockerRulesURL(slice: slice)
        } else if slice > 0 {
            // Dla dalszych części nie ma listy w pakiecie — pusta lista jest poprawną odpowiedzią.
            rulesURL = Self.emptyRuleListURL()
        } else {
            rulesURL = Bundle.main.url(forResource: "blockerList", withExtension: "json")
        }

        guard let rulesURL else {
            context.cancelRequest(withError: NSError(
                domain: "MacAdBlock.SafariBlocker",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Nie znaleziono skompilowanej listy reguł."]
            ))
            return
        }
        let attachment = NSItemProvider(contentsOf: rulesURL)
        let item = NSExtensionItem()
        item.attachments = attachment.map { [$0] }
        context.completeRequest(returningItems: [item])
    }

    /// Safari odrzuca rozszerzenie bez listy reguł, więc gdy część jeszcze nie istnieje,
    /// podajemy pustą, poprawną tablicę zapisaną w katalogu tymczasowym.
    private static func emptyRuleListURL() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macadblock-empty-rules.json")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard (try? Data("[]".utf8).write(to: url, options: .atomic)) != nil else { return nil }
        }
        return url
    }

    private static func availableStorage() -> SharedStorage? {
        if let shared = try? SharedStorage() { return shared }
        return try? SharedStorage.applicationFallback()
    }
}
