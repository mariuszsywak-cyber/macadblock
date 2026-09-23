import AppIntents
import Foundation

/// Akcje dla aplikacji Skróty i Siri. Działają na modelu działającej aplikacji (MacAdBlock startuje w tle,
/// gdy skrót jest uruchamiany, więc model istnieje, zanim intencja się wykona).
struct PauseProtectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause protection"
    static let description = IntentDescription("Turns MacAdBlock protection off for a set time, then resumes it automatically.")

    @Parameter(title: "Minutes", default: 60, inclusiveRange: (1, 1_440))
    var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.current?.pauseProtection(for: TimeInterval(minutes) * 60)
        return .result()
    }
}

struct ResumeProtectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume protection"
    static let description = IntentDescription("Turns MacAdBlock protection back on.")

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.current?.resumeProtection()
        return .result()
    }
}

struct UpdateFiltersIntent: AppIntent {
    static let title: LocalizedStringResource = "Update filter lists"
    static let description = IntentDescription("Downloads the latest filter lists and rebuilds the rules.")

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.current?.updateFilters()
        return .result()
    }
}

struct MacAdBlockShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PauseProtectionIntent(),
            phrases: ["Pause \(.applicationName)", "Pause protection in \(.applicationName)"],
            shortTitle: "Pause protection",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: ResumeProtectionIntent(),
            phrases: ["Resume \(.applicationName)", "Turn on \(.applicationName)"],
            shortTitle: "Resume protection",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: UpdateFiltersIntent(),
            phrases: ["Update \(.applicationName) lists"],
            shortTitle: "Update filter lists",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
