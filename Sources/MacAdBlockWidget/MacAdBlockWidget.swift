import WidgetKit
import SwiftUI

private let widgetAppGroupIdentifier = "group.com.italiano88.MacAdBlock"

struct ProtectionEntry: TimelineEntry {
    let date: Date
    let protectionEnabled: Bool
    let pausedUntil: Date?
    let blockedToday: Int
}

struct ProtectionProvider: TimelineProvider {
    func placeholder(in context: Context) -> ProtectionEntry {
        ProtectionEntry(date: Date(), protectionEnabled: true, pausedUntil: nil, blockedToday: 128)
    }

    func getSnapshot(in context: Context, completion: @escaping (ProtectionEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ProtectionEntry>) -> Void) {
        let entry = currentEntry()
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func currentEntry() -> ProtectionEntry {
        let defaults = UserDefaults(suiteName: widgetAppGroupIdentifier)
        let protectionEnabled = defaults?.object(forKey: "protectionEnabled") as? Bool ?? true
        let pausedUntil = defaults?.object(forKey: "pausedUntil") as? Date
        return ProtectionEntry(
            date: Date(),
            protectionEnabled: protectionEnabled,
            pausedUntil: pausedUntil,
            blockedToday: Self.readBlockedToday()
        )
    }

    private static func readBlockedToday() -> Int {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: widgetAppGroupIdentifier) else {
            return 0
        }
        let url = container.appendingPathComponent("Generated/blocked-daily.json")
        guard let data = try? Data(contentsOf: url),
              let counts = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return 0
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let key = formatter.string(from: calendar.startOfDay(for: Date()))
        return counts[key] ?? 0
    }
}

struct MacAdBlockWidgetView: View {
    var entry: ProtectionProvider.Entry

    private var isPaused: Bool {
        !entry.protectionEnabled || (entry.pausedUntil.map { $0 > entry.date } ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: isPaused ? "shield.slash.fill" : "checkmark.shield.fill")
                    .foregroundStyle(isPaused ? .orange : .green)
                Text(isPaused ? "Wstrzymana" : "Chroniony")
                    .font(.headline)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.blockedToday)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("zablokowanych dziś")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .containerBackground(for: .widget) {
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

struct MacAdBlockWidget: Widget {
    let kind = "MacAdBlockWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ProtectionProvider()) { entry in
            MacAdBlockWidgetView(entry: entry)
        }
        .configurationDisplayName("MacAdBlock")
        .description("Status ochrony i liczba zablokowanych dziś reklam oraz trackerów.")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct MacAdBlockWidgetBundle: WidgetBundle {
    var body: some Widget {
        MacAdBlockWidget()
    }
}
