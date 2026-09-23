import AppIntents
import Foundation

/// Filtr trybu Skupienie (System Settings → Skupienie → [tryb] → Filtry).
/// Użytkownik przypisuje ten filtr do wybranego trybu Skupienia (np. „Praca”, „Czas wolny”)
/// i system sam wywołuje `perform()` przy jego włączeniu/wyłączeniu — bez potrzeby otwierania appki.
struct MacAdBlockFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Ochrona MacAdBlock"

    // SetFocusFilterIntent wymaga, żeby WSZYSTKIE parametry były opcjonalne — nil oznacza
    // „nie zmieniaj tego ustawienia” (np. gdy filtr jest dopiero konfigurowany albo usuwany z trybu).
    @Parameter(title: "Ochrona")
    var isProtectionEnabled: Bool?

    static var parameterSummary: some ParameterSummary {
        Summary("Ustaw ochronę: \(\.$isProtectionEnabled)")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: (isProtectionEnabled ?? true) ? "Ochrona włączona" : "Ochrona wyłączona",
            subtitle: "MacAdBlock"
        )
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let isProtectionEnabled {
            AppModel.current?.setProtectionEnabled(isProtectionEnabled)
        }
        return .result()
    }
}
