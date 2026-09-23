import CryptoKit
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DownloadMetadata: Codable, Sendable {
    public var eTag: String?
    public var lastModified: String?
    public var sha256: String
    public var updatedAt: Date
    public var byteCount: Int
}

public struct DownloadedFilter: Sendable {
    public let source: FilterSource
    public let data: Data
    public let metadata: DownloadMetadata
    public let wasNotModified: Bool
}

public enum FilterDownloadError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case emptyResponse
    case cacheMissing
    case insecureTransport
    case responseTooLarge
    case cacheCorrupted

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Serwer zwrócił nieprawidłową odpowiedź."
        case .httpStatus(let status): "Pobieranie listy zakończyło się kodem HTTP \(status)."
        case .emptyResponse: "Pobrana lista jest pusta."
        case .cacheMissing: "Serwer zwrócił 304, ale lokalny cache nie istnieje."
        case .insecureTransport: "Lista filtrów musi być pobierana bezpiecznym połączeniem HTTPS."
        case .responseTooLarge: "Pobrana lista przekracza bezpieczny limit rozmiaru."
        case .cacheCorrupted: "Suma SHA-256 lokalnego cache nie zgadza się z metadanymi."
        }
    }
}

public actor FilterDownloader {
    private let storage: SharedStorage
    private let session: URLSession
    private let maximumByteCount: Int
    private var metadataBySource: [String: DownloadMetadata]

    public init(storage: SharedStorage, session: URLSession = .shared, maximumByteCount: Int = 200 * 1_024 * 1_024) {
        self.storage = storage
        self.session = session
        self.maximumByteCount = maximumByteCount
        self.metadataBySource = (try? storage.readJSON([String: DownloadMetadata].self, from: storage.metadataURL)) ?? [:]
    }

    public func download(_ source: FilterSource) async throws -> DownloadedFilter {
        try await download(source, allowConditionalRetry: true)
    }

    private func download(_ source: FilterSource, allowConditionalRetry: Bool) async throws -> DownloadedFilter {
        guard source.url.scheme?.lowercased() == "https" else { throw FilterDownloadError.insecureTransport }
        var request = URLRequest(url: source.url)
        request.timeoutInterval = 45
        request.setValue("MacAdBlock/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/plain, */*;q=0.1", forHTTPHeaderField: "Accept")
        if let metadata = metadataBySource[source.id] {
            if let eTag = metadata.eTag { request.setValue(eTag, forHTTPHeaderField: "If-None-Match") }
            if let lastModified = metadata.lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        }

        // Pobieranie do pliku pozwala sprawdzić rozmiar, zanim cała odpowiedź trafi do pamięci.
        let (temporaryURL, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let httpResponse = response as? HTTPURLResponse else { throw FilterDownloadError.invalidResponse }
        guard httpResponse.url?.scheme?.lowercased() == "https" else { throw FilterDownloadError.insecureTransport }

        if httpResponse.statusCode == 304 {
            let cacheURL = storage.cacheURL(for: source)
            if let cachedData = try? Data(contentsOf: cacheURL), let metadata = metadataBySource[source.id], Self.sha256(cachedData) == metadata.sha256 {
                return DownloadedFilter(source: source, data: cachedData, metadata: metadata, wasNotModified: true)
            }
            guard allowConditionalRetry else { throw FilterDownloadError.cacheMissing }
            metadataBySource[source.id] = nil
            try storage.writeJSON(metadataBySource, to: storage.metadataURL)
            return try await download(source, allowConditionalRetry: false)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw FilterDownloadError.httpStatus(httpResponse.statusCode)
        }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: temporaryURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize <= maximumByteCount else { throw FilterDownloadError.responseTooLarge }
        let receivedData = try Data(contentsOf: temporaryURL)
        guard !receivedData.isEmpty else { throw FilterDownloadError.emptyResponse }
        guard receivedData.count <= maximumByteCount else { throw FilterDownloadError.responseTooLarge }

        let digest = Self.sha256(receivedData)
        let metadata = DownloadMetadata(
            eTag: httpResponse.value(forHTTPHeaderField: "ETag"),
            lastModified: httpResponse.value(forHTTPHeaderField: "Last-Modified"),
            sha256: digest,
            updatedAt: Date(),
            byteCount: receivedData.count
        )
        let sameContent = metadataBySource[source.id]?.sha256 == digest && FileManager.default.fileExists(atPath: storage.cacheURL(for: source).path)
        if !sameContent { try storage.write(receivedData, to: storage.cacheURL(for: source)) }
        metadataBySource[source.id] = metadata
        try storage.writeJSON(metadataBySource, to: storage.metadataURL)
        return DownloadedFilter(source: source, data: receivedData, metadata: metadata, wasNotModified: sameContent)
    }

    public func cached(_ source: FilterSource) -> DownloadedFilter? {
        guard let metadata = metadataBySource[source.id],
              let data = try? Data(contentsOf: storage.cacheURL(for: source)),
              data.count <= maximumByteCount,
              Self.sha256(data) == metadata.sha256 else { return nil }
        return DownloadedFilter(source: source, data: data, metadata: metadata, wasNotModified: true)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
