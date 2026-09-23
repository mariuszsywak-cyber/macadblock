import Darwin
import Foundation

struct HostsFileManager {
    private let hostsURL = URL(fileURLWithPath: "/etc/hosts")
    private let backupDirectory = URL(fileURLWithPath: "/var/db/MacAdBlock", isDirectory: true)
    private let lockPath = "/var/run/com.italiano88.MacAdBlock.hosts.lock"
    private let maximumDomainCount = 10_000_000

    func apply(domains: [String]) throws -> Int {
        guard domains.count <= maximumDomainCount else {
            throw CocoaError(.fileWriteOutOfSpace, userInfo: [NSLocalizedDescriptionKey: "Lista domen przekracza bezpieczny limit."])
        }
        let normalized = Set(domains.compactMap(HostsParser.normalizedDomain)).sorted()
        return try withExclusiveLock {
            let original = try String(contentsOf: hostsURL, encoding: .utf8)
            let updated = ManagedHostsComposer.replacingManagedSection(in: original, domains: normalized)
            guard updated != original else { return normalized.count }
            try backup(originalData: Data(original.utf8))
            try atomicWrite(Data(updated.utf8))
            return normalized.count
        }
    }

    func removeManagedSection() throws {
        try withExclusiveLock {
            let original = try String(contentsOf: hostsURL, encoding: .utf8)
            let updated = ManagedHostsComposer.removingManagedSection(from: original).trimmingCharacters(in: .newlines) + "\n"
            guard updated != original else { return }
            try backup(originalData: Data(original.utf8))
            try atomicWrite(Data(updated.utf8))
        }
    }

    func status() throws -> (enabled: Bool, count: Int) {
        let contents = try String(contentsOf: hostsURL, encoding: .utf8)
        guard let start = contents.range(of: ManagedHostsComposer.beginMarker),
              let end = contents.range(of: ManagedHostsComposer.endMarker), start.upperBound < end.lowerBound else {
            return (false, 0)
        }
        let count = contents[start.upperBound..<end.lowerBound].split(whereSeparator: \Character.isNewline).filter { $0.hasPrefix("0.0.0.0 ") }.count
        return (true, count)
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else { throw posixError("Nie można utworzyć blokady") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw posixError("Nie można zablokować pliku hosts") }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static let maximumBackupCount = 5

    /// Zapisuje kopię pliku hosts BEZ sekcji zarządzanej przez MacAdBlock (kilka KB zamiast kilku MB),
    /// pomija kopię identyczną z poprzednią i zachowuje tylko kilka najnowszych.
    private func backup(originalData: Data) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o750])

        let original = String(decoding: originalData, as: UTF8.self)
        let backupData = Data(ManagedHostsComposer.removingManagedSection(from: original).utf8)

        let existing = ((try? fileManager.contentsOfDirectory(atPath: backupDirectory.path)) ?? [])
            .filter { $0.hasPrefix("hosts-") && $0.hasSuffix(".backup") }
            .sorted()
        if let latest = existing.last,
           let latestData = try? Data(contentsOf: backupDirectory.appendingPathComponent(latest)),
           latestData == backupData {
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let backupURL = backupDirectory.appendingPathComponent("hosts-\(formatter.string(from: Date())).backup")
        try backupData.write(to: backupURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)

        let all = existing + [backupURL.lastPathComponent]
        for name in all.dropLast(Self.maximumBackupCount) {
            try? fileManager.removeItem(at: backupDirectory.appendingPathComponent(name))
        }
    }

    /// Czyści bufory DNS. Wywoływane po każdej zmianie pliku hosts — zarówno z trybu CLI, jak i z usługi XPC.
    static func flushDNSCache() {
        for (executable, arguments) in [
            ("/usr/bin/dscacheutil", ["-flushcache"]),
            ("/usr/bin/killall", ["-HUP", "mDNSResponder"])
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            try? process.run()
            process.waitUntilExit()
        }
    }

    private func atomicWrite(_ data: Data) throws {
        guard data.count <= 200 * 1_024 * 1_024 else {
            throw CocoaError(.fileWriteOutOfSpace, userInfo: [NSLocalizedDescriptionKey: "Wynikowy plik hosts przekracza limit 200 MiB."])
        }
        var originalStat = stat()
        guard lstat(hostsURL.path, &originalStat) == 0, (originalStat.st_mode & S_IFMT) == S_IFREG else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSLocalizedDescriptionKey: "/etc/hosts nie jest zwykłym plikiem."])
        }

        let temporaryPath = "/etc/.hosts.macadblock.\(UUID().uuidString)"
        let descriptor = Darwin.open(temporaryPath, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw posixError("Nie można utworzyć pliku tymczasowego") }
        var shouldRemove = true
        defer {
            Darwin.close(descriptor)
            if shouldRemove { unlink(temporaryPath) }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                guard written > 0 else { throw posixError("Nie można zapisać pliku tymczasowego") }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
        guard fchown(descriptor, originalStat.st_uid, originalStat.st_gid) == 0,
              fchmod(descriptor, originalStat.st_mode & 0o7777) == 0,
              fsync(descriptor) == 0 else { throw posixError("Nie można utrwalić atrybutów pliku hosts") }
        guard rename(temporaryPath, hostsURL.path) == 0 else { throw posixError("Nie można atomowo zastąpić /etc/hosts") }
        shouldRemove = false

        let directoryDescriptor = Darwin.open("/etc", O_RDONLY)
        if directoryDescriptor >= 0 {
            _ = fsync(directoryDescriptor)
            Darwin.close(directoryDescriptor)
        }
    }

    private func posixError(_ description: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(description): \(String(cString: strerror(errno)))"])
    }
}
