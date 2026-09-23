import Foundation

if CommandLine.arguments == [CommandLine.arguments[0], "--self-check"] {
    FileHandle.standardOutput.write(Data("ok\n".utf8))
    exit(EXIT_SUCCESS)
}

if CommandLine.arguments == [CommandLine.arguments[0], "--build"] {
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    FileHandle.standardOutput.write(Data("\(build)\n".utf8))
    exit(EXIT_SUCCESS)
}

if CommandLine.arguments.count > 1 {
    guard geteuid() == 0 else {
        FileHandle.standardError.write(Data("MacAdBlock helper wymaga uprawnień administratora.\n".utf8))
        exit(77)
    }

    do {
        let manager = HostsFileManager()
        switch CommandLine.arguments[1] {
        case "--apply-file" where CommandLine.arguments.count == 3:
            let path = CommandLine.arguments[2]
            let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else {
                throw CocoaError(.fileReadNoPermission, userInfo: [NSLocalizedDescriptionKey: "Nie można bezpiecznie otworzyć listy domen."])
            }
            defer { close(descriptor) }

            var fileInfo = stat()
            guard fstat(descriptor, &fileInfo) == 0,
                  (fileInfo.st_mode & S_IFMT) == S_IFREG,
                  fileInfo.st_size <= 200 * 1_024 * 1_024 else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Lista domen ma nieprawidłowy format lub rozmiar."])
            }

            let data = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            let domains = text.split(whereSeparator: \Character.isNewline).map(String.init)
            _ = try manager.apply(domains: domains)
            flushDNSCache()
        case "--firewall-apply" where CommandLine.arguments.count == 3:
            let descriptor = open(CommandLine.arguments[2], O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else {
                throw CocoaError(.fileReadNoPermission, userInfo: [NSLocalizedDescriptionKey: "Nie można bezpiecznie otworzyć konfiguracji firewalla."])
            }
            defer { close(descriptor) }
            var fileInfo = stat()
            guard fstat(descriptor, &fileInfo) == 0, (fileInfo.st_mode & S_IFMT) == S_IFREG, fileInfo.st_size <= 1_048_576 else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Konfiguracja firewalla ma nieprawidłowy format lub rozmiar."])
            }
            let data = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readDataToEndOfFile()
            try FirewallManager().apply(try JSONDecoder().decode(FirewallConfig.self, from: data))
        case "--firewall-disable":
            try FirewallManager().disable()
        case "--native-firewall" where CommandLine.arguments.count == 4:
            try FirewallManager().setNativeFirewall(
                enabled: CommandLine.arguments[2] == "on",
                stealth: CommandLine.arguments[3] == "on"
            )
        case "--remove":
            try manager.removeManagedSection()
            flushDNSCache()
        default:
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Nieznane polecenie helpera."])
        }
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

private func flushDNSCache() {
    HostsFileManager.flushDNSCache()
}

let delegate = HostsHelperListenerDelegate()
let listener = NSXPCListener(machServiceName: HostsHelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
