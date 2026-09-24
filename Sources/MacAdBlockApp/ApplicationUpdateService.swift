import AppKit
import CryptoKit
import Foundation
import Security

struct ApplicationRelease: Decodable, Sendable {
    let version: String
    let build: Int
    let packageURL: URL
    let sha256: String
    let notes: String?
}

struct InstalledApplicationVersion: Comparable, Sendable {
    let version: String
    let build: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.build != rhs.build { return lhs.build < rhs.build }
        return lhs.version.compare(rhs.version, options: .numeric) == .orderedAscending
    }
}

enum ApplicationUpdateError: LocalizedError {
    case insecureURL
    case invalidResponse
    case invalidManifest
    case invalidChecksum
    case invalidPackageSignature
    case packageTooLarge
    case invalidInstalledApplication
    case authorizationCancelled
    case authorizationFailed(String)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .insecureURL: L("Aktualizacje muszą być pobierane przez bezpieczne połączenie HTTPS.")
        case .invalidResponse: L("Serwer aktualizacji zwrócił nieprawidłową odpowiedź.")
        case .invalidManifest: L("Manifest aktualizacji jest nieprawidłowy.")
        case .invalidChecksum: L("Pobrany instalator nie przeszedł kontroli integralności SHA-256.")
        case .invalidPackageSignature: L("Pakiet aktualizacji nie ma ważnego podpisu tego samego wydawcy.")
        case .packageTooLarge: L("Pakiet aktualizacji przekracza dozwolony rozmiar.")
        case .invalidInstalledApplication: L("Skopiowana aplikacja jest niekompletna albo ma nieprawidłową wersję.")
        case .authorizationCancelled: L("Instalacja została anulowana.")
        case .authorizationFailed(let details): L("Nie udało się uzyskać uprawnień administratora: \(details)")
        case .copyFailed(let details): L("System nie mógł skopiować aplikacji: \(details)")
        }
    }
}

struct ApplicationUpdateService: Sendable {
    static let destinationURL = URL(fileURLWithPath: "/Applications/MacAdBlock.app", isDirectory: true)
    private let maximumManifestSize = 1_000_000
    private let maximumPackageSize: Int64 = 750_000_000

    func version(at applicationURL: URL) -> InstalledApplicationVersion? {
        let infoURL = applicationURL.appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: infoURL.path),
              let data = try? Data(contentsOf: infoURL),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = object as? [String: Any] else { return nil }
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let buildString = info["CFBundleVersion"] as? String ?? "0"
        return InstalledApplicationVersion(version: version, build: Int(buildString) ?? 0)
    }

    func fetchRelease(from manifestURL: URL) async throws -> ApplicationRelease {
        guard manifestURL.scheme?.lowercased() == "https" else { throw ApplicationUpdateError.insecureURL }
        var request = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw ApplicationUpdateError.invalidResponse
        }
        guard data.count <= maximumManifestSize,
              let release = try? JSONDecoder().decode(ApplicationRelease.self, from: data),
              release.packageURL.scheme?.lowercased() == "https",
              release.sha256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil else {
            throw ApplicationUpdateError.invalidManifest
        }
        return release
    }

    func downloadVerifiedPackage(for release: ApplicationRelease) async throws -> URL {
        let request = URLRequest(url: release.packageURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 120)
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw ApplicationUpdateError.invalidResponse
        }
        if response.expectedContentLength > maximumPackageSize {
            throw ApplicationUpdateError.packageTooLarge
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
        if let size = attributes[.size] as? NSNumber, size.int64Value > maximumPackageSize {
            throw ApplicationUpdateError.packageTooLarge
        }
        guard try sha256(of: temporaryURL).caseInsensitiveCompare(release.sha256) == .orderedSame else {
            throw ApplicationUpdateError.invalidChecksum
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAdBlock-\(release.version)-\(release.build).pkg")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        // SHA-256 z manifestu potwierdza tylko integralność. Autentyczność wydawcy sprawdza podpis pakietu.
        do {
            try verifyPackageSignature(at: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    private func verifyPackageSignature(at packageURL: URL) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        process.arguments = ["--check-signature", packageURL.path]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw ApplicationUpdateError.invalidPackageSignature
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw ApplicationUpdateError.invalidPackageSignature }
        if let team = Self.currentTeamIdentifier(), !text.contains("(\(team))") {
            throw ApplicationUpdateError.invalidPackageSignature
        }
    }

    /// Team ID, którym podpisana jest uruchomiona aplikacja (nil dla podpisu ad-hoc).
    static func currentTeamIdentifier() -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation) == errSecSuccess,
              let information = signingInformation as? [CFString: Any],
              let team = information[kSecCodeInfoTeamIdentifier] as? String,
              !team.isEmpty,
              team.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return team
    }

    /// Kopiowanie, weryfikacja i okno hasła administratora trwają długo, więc całość działa poza głównym wątkiem
    /// (blokowanie interfejsu na oczekiwaniu na wątek o niższym QoS powodowało odwrócenie priorytetów).
    func installCurrentApplication() async throws -> URL {
        let service = self
        return try await Task.detached(priority: .userInitiated) {
            try service.installCurrentApplicationBlocking()
        }.value
    }

    private func installCurrentApplicationBlocking() throws -> URL {
        let source = Bundle.main.bundleURL.standardizedFileURL
        let destination = Self.destinationURL
        guard source != destination else { return destination }

        let fileManager = FileManager.default
        guard let sourceVersion = version(at: source) else {
            throw ApplicationUpdateError.invalidInstalledApplication
        }
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("MacAdBlock-install-\(UUID().uuidString)", isDirectory: true)
        let staging = temporaryDirectory.appendingPathComponent("MacAdBlock.app", isDirectory: true)
        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        try copyApplication(from: source, to: staging)
        try validateApplication(at: staging, expectedVersion: sourceVersion)
        try installWithAdministratorPrivileges(from: staging, to: destination)
        try validateApplication(at: destination, expectedVersion: sourceVersion)
        // Ta kopia (np. build Debug z Xcode w DerivedData) za chwilę zniknie — wywołujący kończy
        // ten proces i uruchamia świeżo zainstalowaną kopię z /Applications. Jeśli tego nie zrobimy,
        // macOS/Safari zostawiają wpis dla rozszerzenia spod starej, porzuconej ścieżki, więc
        // w Ustawieniach Safari pojawiają się DWIE wtyczki MacAdBlock — jedna spod folderu Debug,
        // druga spod /Applications. „Best effort”: brak pluginkit albo błąd nie mogą przerwać instalacji.
        unregisterStaleExtensions(at: source)
        return destination
    }

    /// Usuwa rejestrację PlugKit (Safari App Extensions itp.) dla wtyczek porzucanej kopii aplikacji,
    /// żeby po instalacji do /Applications w systemie nie zostawał „duch” starego rozszerzenia.
    private func unregisterStaleExtensions(at bundleURL: URL) {
        let pluginKit = URL(fileURLWithPath: "/usr/bin/pluginkit")
        guard FileManager.default.isExecutableFile(atPath: pluginKit.path) else { return }
        let plugInsURL = bundleURL.appendingPathComponent("Contents/PlugIns", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: plugInsURL, includingPropertiesForKeys: nil) else { return }
        for item in items where item.pathExtension == "appex" {
            let process = Process()
            process.executableURL = pluginKit
            process.arguments = ["-r", item.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }

    @MainActor
    func openApplicationAndTerminate(at url: URL) {
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = [
            "-c",
            // Czekamy, aż obecny proces naprawdę zniknie (do 20 s): dopóki trzyma blokadę jednej instancji,
            // nowa kopia z /Applications zamykałaby się od razu i wyglądało to jak brak ponownego uruchomienia.
            "i=0; while kill -0 \"$2\" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.2; i=$((i+1)); done; sleep 0.3; /usr/bin/open -n \"$1\" || exec \"$1/Contents/MacOS/MacAdBlock\"",
            "macadblock-relaunch",
            url.path,
            String(ProcessInfo.processInfo.processIdentifier)
        ]
        do {
            try relauncher.run()
            NSApplication.shared.terminate(nil)
        } catch {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }

    @MainActor
    func openInstaller(at packageURL: URL) {
        NSWorkspace.shared.open(packageURL)
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func validateApplication(at url: URL, expectedVersion: InstalledApplicationVersion) throws {
        let executable = url.appendingPathComponent("Contents/MacOS/MacAdBlock")
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              version(at: url) == expectedVersion else {
            throw ApplicationUpdateError.invalidInstalledApplication
        }
    }

    private func copyApplication(from source: URL, to destination: URL) throws {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["--noqtn", source.path, destination.path]
        var environment = ProcessInfo.processInfo.environment
        environment["COPYFILE_DISABLE"] = "1"
        process.environment = environment
        process.standardError = standardError

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ApplicationUpdateError.copyFailed(error.localizedDescription)
        }

        guard process.terminationStatus == 0 else {
            let data = standardError.fileHandleForReading.readDataToEndOfFile()
            let details = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = details.flatMap { $0.isEmpty ? nil : $0 }
                ?? L("ditto zakończyło działanie z kodem \(process.terminationStatus).")
            throw ApplicationUpdateError.copyFailed(message)
        }

        try clearExtendedAttributes(at: destination)
    }

    private func clearExtendedAttributes(at url: URL) throws {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-cr", url.path]
        process.standardError = standardError

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ApplicationUpdateError.copyFailed(error.localizedDescription)
        }

        guard process.terminationStatus == 0 else {
            let data = standardError.fileHandleForReading.readDataToEndOfFile()
            let details = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ApplicationUpdateError.copyFailed(
                details.flatMap { $0.isEmpty ? nil : $0 }
                    ?? L("Nie udało się usunąć metadanych Finder z kopii aplikacji.")
            )
        }
    }

    private func installWithAdministratorPrivileges(from source: URL, to destination: URL) throws {
        let identifier = UUID().uuidString
        let applicationsDirectory = destination.deletingLastPathComponent()
        let privilegedStaging = applicationsDirectory
            .appendingPathComponent(".MacAdBlock-installing-\(identifier).app", isDirectory: true)
        let backup = applicationsDirectory
            .appendingPathComponent(".MacAdBlock-backup-\(identifier).app", isDirectory: true)

        let sourcePath = shellQuoted(source.path)
        let destinationPath = shellQuoted(destination.path)
        let stagingPath = shellQuoted(privilegedStaging.path)
        let backupPath = shellQuoted(backup.path)
        // Sam `codesign --verify` przepuszcza każdą poprawnie podpisaną aplikację. Gdy uruchomiona kopia ma Team ID,
        // instalowana aplikacja musi być podpisana tym samym Teamem (weryfikacja na kopii należącej do roota).
        let requirementFlag: String
        let requirementDefinition: String
        if let team = Self.currentTeamIdentifier() {
            let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
            requirementFlag = "-R \"=$REQUIREMENT\" "
            requirementDefinition = "REQUIREMENT=\(shellQuoted(requirement))"
        } else {
            requirementFlag = ""
            requirementDefinition = "REQUIREMENT="
        }
        let command = [
            "SOURCE=\(sourcePath)",
            "DESTINATION=\(destinationPath)",
            "STAGING=\(stagingPath)",
            "BACKUP=\(backupPath)",
            requirementDefinition,
            "/bin/rm -rf \"$STAGING\" \"$BACKUP\" || exit 20",
            "COPYFILE_DISABLE=1 /usr/bin/ditto --noqtn \"$SOURCE\" \"$STAGING\" || { /bin/rm -rf \"$STAGING\"; exit 21; }",
            "/usr/bin/xattr -cr \"$STAGING\" || { /bin/rm -rf \"$STAGING\"; exit 22; }",
            "/usr/bin/codesign --verify --deep --strict \(requirementFlag)\"$STAGING\" || { /bin/rm -rf \"$STAGING\"; exit 23; }",
            "HAD_DESTINATION=0",
            "if [ -e \"$DESTINATION\" ]; then /bin/mv \"$DESTINATION\" \"$BACKUP\" || { /bin/rm -rf \"$STAGING\"; exit 24; }; HAD_DESTINATION=1; fi",
            "if /bin/mv \"$STAGING\" \"$DESTINATION\" && /usr/bin/codesign --verify --deep --strict \(requirementFlag)\"$DESTINATION\"; then /bin/rm -rf \"$BACKUP\"; exit 0; fi",
            "/bin/rm -rf \"$DESTINATION\" \"$STAGING\"",
            "if [ \"$HAD_DESTINATION\" -eq 1 ]; then /bin/mv \"$BACKUP\" \"$DESTINATION\" || exit 25; fi",
            "exit 26"
        ].joined(separator: "; ")

        let appleScriptSource = "do shell script \(appleScriptQuoted(command)) with administrator privileges"

        // osascript jako osobny proces jest bezpieczny wątkowo (NSAppleScript wymaga głównego wątku),
        // a oczekiwanie na okno hasła nie blokuje interfejsu aplikacji.
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScriptSource]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw ApplicationUpdateError.authorizationFailed(error.localizedDescription)
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return }

        let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains("(-128)") || message.localizedCaseInsensitiveContains("User canceled") {
            throw ApplicationUpdateError.authorizationCancelled
        }
        throw ApplicationUpdateError.copyFailed(message.isEmpty ? L("System odrzucił operację instalacji.") : message)
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appleScriptQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
