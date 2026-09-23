@preconcurrency import Network
@preconcurrency import NetworkExtension

final class DNSProxyProvider: NEDNSProxyProvider, @unchecked Sendable {
    private static let appGroupIdentifier = "group.com.italiano88.MacAdBlock"
    private static let upstreamTimeout: TimeInterval = 5

    private let queue = DispatchQueue(label: "com.italiano88.MacAdBlock.dns-proxy", qos: .userInitiated)
    /// Chroni `blockedDomains`, `lastDomainReload` i `isReloading` — zapytania DNS obsługiwane są współbieżnie.
    private static let blockLog = BlockLog(appGroupIdentifier: appGroupIdentifier)
    private let stateLock = NSLock()
    private var blockedDomains: Set<String> = []
    private var lastDomainReload = Date.distantPast
    private var isReloading = false
    private var upstreamHost: NWEndpoint.Host?
    private var upstreamPort: NWEndpoint.Port = 53

    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        guard let hostValue = options?["upstreamHost"] as? String,
              !hostValue.isEmpty else {
            completionHandler(NSError(
                domain: "MacAdBlock.DNSProxy",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Skonfiguruj upstreamHost w NEDNSProxyProviderProtocol. MacAdBlock nie wysyła zapytań DNS do zewnętrznego dostawcy bez świadomego wyboru."]
            ))
            return
        }
        upstreamHost = NWEndpoint.Host(hostValue)
        if let portValue = options?["upstreamPort"] as? Int, let port = NWEndpoint.Port(rawValue: UInt16(clamping: portValue)) {
            upstreamPort = port
        }
        let initialDomains = Self.loadBlockedDomains() ?? []
        stateLock.lock()
        blockedDomains = initialDomains
        lastDomainReload = Date()
        stateLock.unlock()
        completionHandler(nil)
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        if let udpFlow = flow as? NEAppProxyUDPFlow {
            processUDP(udpFlow)
            return true
        }
        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            processTCP(tcpFlow)
            return true
        }
        return false
    }

    private func processUDP(_ flow: NEAppProxyUDPFlow) {
        flow.open(withLocalFlowEndpoint: nil) { [weak self, weak flow] error in
            guard error == nil, let self, let flow else {
                flow?.closeReadWithError(error)
                flow?.closeWriteWithError(error)
                return
            }
            self.readUDP(flow)
        }
    }

    private func readUDP(_ flow: NEAppProxyUDPFlow) {
        flow.readDatagrams { [weak self, weak flow] packets, error in
            guard let self, let flow, error == nil, let packets else {
                flow?.closeReadWithError(error)
                flow?.closeWriteWithError(error)
                return
            }
            for (datagram, endpoint) in packets {
                if let domain = DNSMessage.questionName(in: datagram), self.isBlocked(domain) {
                    let response = DNSMessage.blockedResponse(for: datagram)
                    Task { try? await flow.writeDatagrams([(response, endpoint)]) }
                } else {
                    self.forwardUDP(datagram) { response in
                        guard let response else { return }
                        Task { try? await flow.writeDatagrams([(response, endpoint)]) }
                    }
                }
            }
            self.readUDP(flow)
        }
    }

    private func processTCP(_ flow: NEAppProxyTCPFlow) {
        flow.open(withLocalFlowEndpoint: nil) { [weak self, weak flow] error in
            guard error == nil, let self, let flow else {
                flow?.closeReadWithError(error)
                flow?.closeWriteWithError(error)
                return
            }
            self.readTCP(flow, buffered: Data())
        }
    }

    private func readTCP(_ flow: NEAppProxyTCPFlow, buffered: Data) {
        flow.readData { [weak self, weak flow] data, error in
            guard let self, let flow, error == nil, let data, !data.isEmpty else {
                flow?.closeReadWithError(error)
                flow?.closeWriteWithError(error)
                return
            }
            var accumulated = buffered
            accumulated.append(data)
            self.processTCPBuffer(accumulated, flow: flow)
        }
    }

    private func processTCPBuffer(_ data: Data, flow: NEAppProxyTCPFlow) {
        guard data.count >= 2 else { readTCP(flow, buffered: data); return }
        let length = Int(data[data.startIndex]) << 8 | Int(data[data.index(after: data.startIndex)])
        guard length > 0 else { flow.closeReadWithError(nil); flow.closeWriteWithError(nil); return }
        guard data.count >= length + 2 else { readTCP(flow, buffered: data); return }
        let query = Data(data.dropFirst(2).prefix(length))
        let remaining = Data(data.dropFirst(length + 2))
        let respond: @Sendable (Data?) -> Void = { [weak self, weak flow] response in
            guard let self, let flow, let response else { return }
            flow.write(Self.tcpFrame(response)) { error in
                guard error == nil else {
                    flow.closeReadWithError(error)
                    flow.closeWriteWithError(error)
                    return
                }
                if remaining.isEmpty { self.readTCP(flow, buffered: Data()) }
                else { self.processTCPBuffer(remaining, flow: flow) }
            }
        }
        if let domain = DNSMessage.questionName(in: query), isBlocked(domain) {
            respond(DNSMessage.blockedResponse(for: query))
        } else {
            forwardTCP(query, completion: respond)
        }
    }

    private func forwardUDP(_ query: Data, completion: @escaping @Sendable (Data?) -> Void) {
        guard let upstreamHost else { completion(nil); return }
        let connection = NWConnection(host: upstreamHost, port: upstreamPort, using: .udp)
        let once = OneShot()
        // Zakończenie dokładnie raz: odpowiedź, błąd albo limit czasu — połączenie nigdy nie zostaje w zawieszeniu.
        let finish: @Sendable (Data?) -> Void = { data in
            once.run {
                connection.cancel()
                completion(data)
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: query, completion: .contentProcessed { error in
                    guard error == nil else { finish(nil); return }
                    connection.receiveMessage { data, _, _, _ in finish(data) }
                })
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.upstreamTimeout) { finish(nil) }
    }

    private func forwardTCP(_ query: Data, completion: @escaping @Sendable (Data?) -> Void) {
        guard let upstreamHost else { completion(nil); return }
        let connection = NWConnection(host: upstreamHost, port: upstreamPort, using: .tcp)
        let once = OneShot()
        let finish: @Sendable (Data?) -> Void = { data in
            once.run {
                connection.cancel()
                completion(data)
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Self.tcpFrame(query), completion: .contentProcessed { error in
                    guard error == nil else { finish(nil); return }
                    connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { header, _, _, error in
                        guard error == nil, let header, header.count == 2 else { finish(nil); return }
                        let length = Int(header[header.startIndex]) << 8 | Int(header[header.index(after: header.startIndex)])
                        guard length > 0 else { finish(nil); return }
                        connection.receive(minimumIncompleteLength: length, maximumLength: length) { response, _, _, _ in
                            finish(response)
                        }
                    }
                })
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.upstreamTimeout) { finish(nil) }
    }

    /// Odświeża listę domen w tle (nie w ścieżce obsługi zapytania) co 30 sekund.
    private func reloadDomainsIfNeeded() {
        stateLock.lock()
        let due = !isReloading && Date().timeIntervalSince(lastDomainReload) >= 30
        if due {
            isReloading = true
            lastDomainReload = Date()
        }
        stateLock.unlock()
        guard due else { return }

        queue.async { [weak self] in
            let loaded = Self.loadBlockedDomains()
            guard let self else { return }
            self.stateLock.lock()
            if let loaded { self.blockedDomains = loaded }
            self.isReloading = false
            self.stateLock.unlock()
        }
    }

    private func isBlocked(_ domain: String) -> Bool {
        reloadDomainsIfNeeded()
        stateLock.lock()
        let domains = blockedDomains
        stateLock.unlock()

        var candidate = domain.lowercased()
        while !candidate.isEmpty {
            if domains.contains(candidate) {
                Self.blockLog.record(domain.lowercased())
                return true
            }
            guard let dot = candidate.firstIndex(of: ".") else { break }
            candidate = String(candidate[candidate.index(after: dot)...])
        }
        return false
    }

    private static func tcpFrame(_ message: Data) -> Data {
        var result = Data([UInt8((message.count >> 8) & 0xff), UInt8(message.count & 0xff)])
        result.append(message)
        return result
    }

    /// nil oznacza błąd odczytu (wtedy zostaje poprzednia lista); pusty zbiór to świadomie pusta lista.
    private static func loadBlockedDomains() -> Set<String>? {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else { return nil }
        let url = root.appendingPathComponent("Generated/hosts-domains.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Set(text.split(whereSeparator: \Character.isNewline).map { $0.lowercased() })
    }
}

/// Wykonuje blok najwyżej raz (odpowiedź, błąd i limit czasu mogą nadejść niezależnie).
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func run(_ block: () -> Void) {
        lock.lock()
        let shouldRun = !fired
        fired = true
        lock.unlock()
        if shouldRun { block() }
    }
}

private enum DNSMessage {
    static func questionName(in data: Data) -> String? {
        guard data.count >= 13 else { return nil }
        var offset = 12
        var labels: [String] = []
        while offset < data.count {
            let length = Int(data[offset])
            offset += 1
            if length == 0 { break }
            guard length <= 63, offset + length <= data.count else { return nil }
            guard let label = String(data: data[offset..<(offset + length)], encoding: .utf8) else { return nil }
            labels.append(label)
            offset += length
        }
        return labels.isEmpty ? nil : labels.joined(separator: ".").lowercased()
    }

    /// Pierwszy bajt po sekcji pytania (nazwa + QTYPE + QCLASS) albo nil, gdy komunikat jest uszkodzony.
    static func questionEnd(in data: Data) -> Int? {
        var offset = 12
        while offset < data.count {
            let length = Int(data[offset])
            offset += 1
            if length == 0 { return offset + 4 <= data.count ? offset + 4 : nil }
            guard length <= 63, offset + length <= data.count else { return nil }
            offset += length
        }
        return nil
    }

    static func blockedResponse(for query: Data) -> Data {
        guard query.count >= 12 else { return query }
        // Odpowiedź zawiera wyłącznie nagłówek i pytanie — bez rekordów dodatkowych (np. EDNS OPT) z zapytania.
        var response: Data
        if let end = questionEnd(in: query) {
            response = Data(query.prefix(end))
        } else {
            response = Data(query.prefix(12))
            response[4] = 0
            response[5] = 0
        }
        response[2] = (response[2] & 0x79) | 0x80
        response[3] = (response[3] & 0xf0) | 0x80 | 0x03
        response[6] = 0
        response[7] = 0
        response[8] = 0
        response[9] = 0
        response[10] = 0
        response[11] = 0
        return response
    }
}

/// Zlicza zablokowane domeny i co kilka sekund zapisuje 150 ostatnich do kontenera App Group.
/// Format odpowiada `BlockedLogEntry` z MacAdBlockCore (ten target nie linkuje Core).
private final class BlockLog: @unchecked Sendable {
    private struct Entry: Codable { var domain: String; var count: Int; var last: Double }

    private let lock = NSLock()
    private let url: URL?
    private let dailyURL: URL?
    private var daily: [String: Int] = [:]
    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private var entries: [String: Entry] = [:]
    private var lastFlush = Date.distantPast
    private var flushScheduled = false
    private let queue = DispatchQueue(label: "com.italiano88.MacAdBlock.dns-proxy.log", qos: .utility)

    init(appGroupIdentifier: String) {
        url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("Generated/blocked-log.json")
        dailyURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("Generated/blocked-daily.json")
        if let dailyURL, let data = try? Data(contentsOf: dailyURL),
           let stored = try? JSONDecoder().decode([String: Int].self, from: data) {
            daily = stored
        }
        if let url, let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = Dictionary(stored.map { ($0.domain, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    func record(_ domain: String) {
        guard url != nil else { return }
        lock.lock()
        var entry = entries[domain] ?? Entry(domain: domain, count: 0, last: 0)
        entry.count += 1
        entry.last = Date().timeIntervalSince1970
        entries[domain] = entry
        dayFormatter.timeZone = .current
        daily[dayFormatter.string(from: Date()), default: 0] += 1
        let shouldSchedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        if shouldSchedule {
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.flush() }
        }
    }

    private func flush() {
        lock.lock()
        flushScheduled = false
        let newest = entries.values.sorted { $0.last > $1.last }.prefix(150)
        entries = Dictionary(uniqueKeysWithValues: newest.map { ($0.domain, $0) })
        let snapshot = Array(newest)
        // Przechowujemy tylko ostatnie 60 dni.
        if daily.count > 60 { daily = Dictionary(uniqueKeysWithValues: daily.sorted { $0.key > $1.key }.prefix(60).map { ($0.key, $0.value) }) }
        let dailySnapshot = daily
        lock.unlock()
        if let dailyURL, let dailyData = try? JSONEncoder().encode(dailySnapshot) {
            try? FileManager.default.createDirectory(at: dailyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? dailyData.write(to: dailyURL, options: .atomic)
        }
        guard let url, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
