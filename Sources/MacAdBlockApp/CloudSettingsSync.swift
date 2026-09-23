import Foundation

/// Synchronizacja wybranych ustawień (stan ochrony, harmonogram) między Makami przez tego samego
/// Apple ID, przez iCloud Key-Value Store. Nie wymaga logowania w appce — działa, jeśli użytkownik
/// jest zalogowany do iCloud w Ustawieniach systemowych; w przeciwnym razie zapisy/odczyty są cichym
/// no-opem (Apple sam wtedy ignoruje wywołania NSUbiquitousKeyValueStore).
/// Wyłączona domyślnie — użytkownik włącza ją świadomie w Ustawieniach ogólnych.
@MainActor
final class CloudSettingsSync {
    static let shared = CloudSettingsSync()

    private let store = NSUbiquitousKeyValueStore.default
    private var isObserving = false
    private var isApplyingRemote = false

    private enum Key {
        static let protectionEnabled = "sync.protectionEnabled"
        static let scheduleEnabled = "sync.scheduleEnabled"
        static let scheduleStart = "sync.scheduleStart"
        static let scheduleEnd = "sync.scheduleEnd"
        static let scheduleWeekdays = "sync.scheduleWeekdays"
        static let updatedAt = "sync.updatedAt"
    }

    private init() {}

    /// Wywoływane raz, gdy synchronizacja jest włączona (przy starcie appki albo gdy użytkownik
    /// właśnie zaznaczył przełącznik). Zaczyna nasłuchiwać zmian z innych urządzeń i od razu
    /// próbuje zastosować to, co już jest w chmurze.
    func start(with model: AppModel) {
        store.synchronize()
        applyRemote(to: model, onlyIfNewer: false)
        guard !isObserving else { return }
        isObserving = true
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self, weak model] _ in
            guard let self, let model else { return }
            Task { @MainActor in
                self.applyRemote(to: model)
            }
        }
    }

    /// Wysyła bieżący stan do chmury. Wywoływane z didSet-ów AppModel — no-op, jeśli synchronizacja
    /// jest wyłączona albo właśnie trwa stosowanie zmiany przyszłej z chmury (unika pętli).
    func push(from model: AppModel) {
        guard model.iCloudSyncEnabled, !isApplyingRemote else { return }
        store.set(model.protectionEnabled, forKey: Key.protectionEnabled)
        store.set(model.scheduleEnabled, forKey: Key.scheduleEnabled)
        store.set(model.scheduleStartMinutes, forKey: Key.scheduleStart)
        store.set(model.scheduleEndMinutes, forKey: Key.scheduleEnd)
        store.set(Array(model.scheduleWeekdays), forKey: Key.scheduleWeekdays)
        store.set(Date().timeIntervalSince1970, forKey: Key.updatedAt)
        store.synchronize()
    }

    private func applyRemote(to model: AppModel, onlyIfNewer: Bool = true) {
        guard model.iCloudSyncEnabled else { return }
        let remoteStamp = store.double(forKey: Key.updatedAt)
        guard remoteStamp > 0 else { return }
        if onlyIfNewer, remoteStamp <= model.iCloudLastAppliedAt { return }

        isApplyingRemote = true
        defer { isApplyingRemote = false }

        if store.object(forKey: Key.protectionEnabled) != nil {
            model.setProtectionEnabled(store.bool(forKey: Key.protectionEnabled))
        }
        if store.object(forKey: Key.scheduleEnabled) != nil {
            model.setScheduleEnabled(store.bool(forKey: Key.scheduleEnabled))
        }
        if let start = store.object(forKey: Key.scheduleStart) as? Int,
           let end = store.object(forKey: Key.scheduleEnd) as? Int {
            model.setScheduleWindow(startMinutes: start, endMinutes: end)
        }
        if let weekdays = store.array(forKey: Key.scheduleWeekdays) as? [Int] {
            model.scheduleWeekdays = Set(weekdays)
        }
        model.iCloudLastAppliedAt = remoteStamp
    }
}
