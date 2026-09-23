import AppKit
import Darwin
import Foundation

final class SingleInstanceController {
    private var lockFileDescriptor: Int32 = -1

    func acquire() -> Bool {
        guard lockFileDescriptor == -1 else { return true }

        let lockURL = lockFileURL
        try? FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        // Poprzednia instancja może jeszcze kończyć pracę (np. po automatycznej instalacji w /Applications),
        // więc przez krótką chwilę ponawiamy próbę zamiast od razu się poddawać.
        var locked = flock(descriptor, LOCK_EX | LOCK_NB) == 0
        var attempts = 0
        while !locked && attempts < 25 {
            Thread.sleep(forTimeInterval: 0.2)
            locked = flock(descriptor, LOCK_EX | LOCK_NB) == 0
            attempts += 1
        }
        guard locked else {
            Darwin.close(descriptor)
            return false
        }

        lockFileDescriptor = descriptor
        return true
    }

    func activateExistingInstance() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let existingApplication = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != currentProcessIdentifier && !$0.isTerminated }
        existingApplication?.activate(options: [.activateAllWindows])
    }

    deinit {
        guard lockFileDescriptor >= 0 else { return }
        flock(lockFileDescriptor, LOCK_UN)
        Darwin.close(lockFileDescriptor)
    }

    private var lockFileURL: URL {
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("MacAdBlock", isDirectory: true)
            .appendingPathComponent("application.lock")
    }
}

final class MacAdBlockApplicationDelegate: NSObject, NSApplicationDelegate {
    private let singleInstanceController = SingleInstanceController()

    func applicationWillFinishLaunching(_ notification: Notification) {
#if DEBUG
        if ProcessInfo.processInfo.environment["MACADBLOCK_PREVIEW_INSTANCE"] == "1" { return }
#endif
        guard singleInstanceController.acquire() else {
            singleInstanceController.activateExistingInstance()
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
            return
        }
    }
}
