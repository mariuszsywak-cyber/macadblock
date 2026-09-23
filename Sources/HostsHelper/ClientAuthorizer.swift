import Foundation
import Security

enum ClientAuthorizer {
    /// Wymaganie podpisu kodu klienta (identyfikator + Team ID). System wymusza je na samym połączeniu XPC
    /// (na podstawie audit tokena procesu), co eliminuje podatność kontroli opartej wyłącznie na PID.
    /// Zwraca nil, gdy helper nie ma skonfigurowanego Team ID (wtedy działa tylko ścieżka DEBUG).
    static func codeSigningRequirement() -> String? {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "AuthorizedClientBundleIdentifier") as? String,
              !identifier.isEmpty,
              let team = Bundle.main.object(forInfoDictionaryKey: "AuthorizedClientTeamIdentifier") as? String,
              !team.isEmpty,
              identifier.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }),
              team.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    static func isAuthorized(_ connection: NSXPCConnection) -> Bool {
        guard let expectedIdentifier = Bundle.main.object(forInfoDictionaryKey: "AuthorizedClientBundleIdentifier") as? String,
              !expectedIdentifier.isEmpty else {
            return false
        }

        let attributes = [kSecGuestAttributePid: NSNumber(value: connection.processIdentifier)] as CFDictionary
        var guestCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guestCode) == errSecSuccess,
              let guestCode else { return false }
        // Proces musi mieć ważny podpis także w pamięci, nie tylko na dysku.
        guard SecCodeCheckValidity(guestCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { return false }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guestCode, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }

        var signingInformation: CFDictionary?
        guard SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation) == errSecSuccess,
              let info = signingInformation as? [CFString: Any],
              let identifier = info[kSecCodeInfoIdentifier] as? String,
              identifier == expectedIdentifier else { return false }

        let expectedTeam = Bundle.main.object(forInfoDictionaryKey: "AuthorizedClientTeamIdentifier") as? String ?? ""
        if !expectedTeam.isEmpty {
            return info[kSecCodeInfoTeamIdentifier] as? String == expectedTeam
        }

#if DEBUG
        return matchesBundledMainExecutable(staticCode)
#else
        return false
#endif
    }

    private static func matchesBundledMainExecutable(_ clientCode: SecStaticCode) -> Bool {
        guard let helperURL = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return false }
        let contentsURL = helperURL.deletingLastPathComponent().deletingLastPathComponent()
        guard contentsURL.lastPathComponent == "Contents",
              let appInfo = NSDictionary(contentsOf: contentsURL.appendingPathComponent("Info.plist")),
              let executableName = appInfo[kCFBundleExecutableKey as String] as? String,
              !executableName.isEmpty else { return false }

        let appExecutableURL = contentsURL
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
        var appCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appExecutableURL as CFURL, [], &appCode) == errSecSuccess,
              let appCode else { return false }

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(appCode, [], &requirement) == errSecSuccess,
              let requirement else { return false }

        return SecStaticCodeCheckValidity(clientCode, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }
}
