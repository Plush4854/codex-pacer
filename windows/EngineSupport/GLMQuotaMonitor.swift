import CryptoKit
import CWindowsSupport
import Foundation
import PacerCore
#if os(Windows)
import FoundationNetworking
#endif

typealias GLMQuotaMonitor = GLMQuotaCoordinator

/// ZCode keeps the key that seals its plan records in the user's credential
/// vault, under the digest of its records file's path. Only that one entry is
/// read, and nothing in the vault is written.
enum WindowsZCodeKeyring {
    private static let service = "ZCode Credential Encryption"
    /// The 32 bytes ZCode seals with, or nil when the vault holds none for this file.
    static func sealingKey(credentialsFile: URL) -> Data? {
        // ZCode hashes the path as the system writes it, with backslashes.
        let path = credentialsFile.standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\")
        let account = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let name = Array((account + "." + service).utf16) + [0]
        var buffer = [UInt8](repeating: 0, count: 256)
        defer { _ = buffer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let count = Int(pacer_read_credential(name, &buffer, buffer.count))
        guard (2...256).contains(count) else { return nil }
        // The vault holds text as UTF-16; a plain byte string is read as UTF-8.
        var units = (0..<count / 2).map { UInt16(buffer[2 * $0]) | UInt16(buffer[2 * $0 + 1]) << 8 }
        let secret = units.allSatisfy { $0 < 128 } ? String(decoding: units, as: UTF16.self) : String(decoding: buffer.prefix(count), as: UTF8.self)
        units.removeAll()
        let text = String(secret.prefix(while: { $0 != "\0" }))
        let key = GLMCredentialStore.fromBase64url(text)
        return key?.count == 32 ? key : nil
    }
}

extension GLMQuotaServices {
    static var live: Self {
        .init(credentials: { home in
            let file = home.appendingPathComponent(GLMCredentialStore.recordsFile), files = WindowsFileSystem()
            guard let info = files.metadata(file), info.isRegularFile, info.size <= 1_048_576 else { return [] }
            let data = try files.read(file, offset: 0, maximumBytes: 1_048_577)
            guard let key = WindowsZCodeKeyring.sealingKey(credentialsFile: file) else {
                if GLMCredentialStore.hasPlanRecords(data) { throw GLMQuotaError.keyringUnavailable }
                return []
            }
            let plans = GLMCredentialStore.credentials(in: data, sealingKey: key)
            if plans.isEmpty, GLMCredentialStore.hasPlanRecords(data) { throw GLMQuotaError.keyringUnavailable }
            return plans
        }, read: { credential in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
            let session = URLSession(configuration: configuration, delegate: GLMRedirectPolicy(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            return try await GLMUsageClient.read(credential, transport: { try await session.data(for: $0) })
        })
    }
    /// Nothing to read and nothing to answer, for fixtures.
    static var offline: Self { .init(credentials: { _ in [] }, read: { _ in throw GLMQuotaError.connectionFailed }) }
    private final class GLMRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
