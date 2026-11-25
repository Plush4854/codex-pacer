import CryptoKit
import Foundation
import PacerCore
import Security

extension GLMQuotaServices {
    /// ZCode's sealing key from the login keychain, then one request a read.
    /// Reading that one item is the only thing Pacer does in the keychain.
    public static var glmLive: Self {
        .init(credentials: { home in
            let file = home.appendingPathComponent(GLMCredentialStore.recordsFile), files = MacFileSystem()
            guard let info = files.metadata(file), info.isRegularFile, info.size <= 1_048_576 else { return [] }
            let data = try files.read(file, offset: 0, maximumBytes: 1_048_577)
            // ZCode hashes the record file's path to name its keychain item.
            let account = SHA256.hash(data: Data(file.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
            guard let secret = MacCredentialStore(service: "ZCode Credential Encryption", account: account, label: "").read(),
                  let key = GLMCredentialStore.fromBase64url(String(decoding: secret, as: UTF8.self)), key.count == 32 else {
                if GLMCredentialStore.hasPlanRecords(data) { throw GLMQuotaError.keyringUnavailable }
                return []
            }
            return GLMCredentialStore.credentials(in: data, sealingKey: key)
        }, read: { credential in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
            let session = URLSession(configuration: configuration, delegate: GLMQuotaRedirectPolicy(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            return try await GLMUsageClient.read(credential, transport: { try await session.data(for: $0) })
        })
    }
    private final class GLMQuotaRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
