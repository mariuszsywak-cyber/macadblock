import Foundation
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let message = (context.inputItems.first as? NSExtensionItem)?
            .userInfo?[SFExtensionMessageKey] as? [String: Any]

        switch message?["command"] as? String {
        case "allowlist":
            // Popup zapisuje wyjątki przez aplikację, żeby znała je również warstwa Content Blockera i hosts.
            let domains = message?["domains"] as? [String] ?? []
            complete(context, with: ["allowlist": Self.storeAllowlist(domains)])
        case "custom-rule":
            // Selektor wskazany element pickerem trafia do własnych reguł, więc przetrwa restart rozszerzenia.
            let rule = message?["rule"] as? String ?? ""
            complete(context, with: ["saved": Self.appendCustomRule(rule)])
        default:
            complete(context, with: Self.rulesPayload())
        }
    }

    private func complete(_ context: NSExtensionContext, with payload: [String: Any]) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: payload]
        context.completeRequest(returningItems: [response])
    }

    private static func rulesPayload() -> [String: Any] {
        let emptyCosmetic: [String: Any] = ["rules": [], "exemptDomains": [], "unsupportedRuleCount": 0]
        guard let storage = availableStorage(),
              let data = try? Data(contentsOf: storage.webExtensionRulesURL),
              let rules = try? JSONSerialization.jsonObject(with: data) else {
            return ["rules": [], "cosmetic": emptyCosmetic, "allowlist": []]
        }

        var cosmetic: Any = emptyCosmetic
        if let cosmeticData = try? Data(contentsOf: storage.webExtensionCosmeticRulesURL),
           let cosmeticObject = try? JSONSerialization.jsonObject(with: cosmeticData) {
            cosmetic = cosmeticObject
        }
        return [
            "rules": rules,
            "cosmetic": cosmetic,
            "allowlist": storage.readUserSettings().normalizedAllowlist
        ]
    }

    private static func storeAllowlist(_ domains: [String]) -> [String] {
        guard let storage = availableStorage() else { return [] }
        var settings = storage.readUserSettings()
        settings.allowlistedDomains = domains
        try? storage.writeUserSettings(settings)
        return settings.normalizedAllowlist
    }

    private static func appendCustomRule(_ rule: String) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2_000, let storage = availableStorage() else { return false }
        var settings = storage.readUserSettings()
        let existing = settings.customRules.split(whereSeparator: \Character.isNewline).map(String.init)
        guard !existing.contains(trimmed) else { return true }
        settings.customRules = (existing + [trimmed]).joined(separator: "\n")
        return (try? storage.writeUserSettings(settings)) != nil
    }

    private static func availableStorage() -> SharedStorage? {
        if let shared = try? SharedStorage() { return shared }
        return try? SharedStorage.applicationFallback()
    }
}
