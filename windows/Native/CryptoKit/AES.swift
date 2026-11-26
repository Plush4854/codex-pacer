import CWindowsSupport
import Foundation

public struct SymmetricKey: Sendable {
    public let data: Data
    public init(data: Data) { self.data = data }
}

public enum CryptoKitError: Error { case authenticationFailure, incorrectParameterSize }

/// AES-256-GCM, the one authenticated cipher the shared sources open. Windows
/// computes it with CNG instead of carrying a second crypto library.
public enum AES {
    public enum GCM {
        public struct Nonce: ContiguousBytes, Equatable, Sendable {
            public let data: Data
            public init(data: Data) { self.data = data }
            public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try data.withUnsafeBytes(body) }
        }
        public struct SealedBox: Sendable {
            public let nonce: Nonce, ciphertext: Data, tag: Data
            public init(nonce: Nonce, ciphertext: Data, tag: Data) { self.nonce = nonce; self.ciphertext = ciphertext; self.tag = tag }
        }
        private static func sized(_ key: SymmetricKey, nonce: Data, tag: Data) -> Bool {
            key.data.count == 32 && nonce.count == 12 && tag.count == 16
        }
        public static func open(_ box: SealedBox, using key: SymmetricKey) throws -> Data {
            guard sized(key, nonce: box.nonce.data, tag: box.tag), (1...Int(Int32.max)).contains(box.ciphertext.count) else {
                throw CryptoKitError.incorrectParameterSize
            }
            var plain = [UInt8](repeating: 0, count: box.ciphertext.count)
            let count = key.data.withUnsafeBytes { key in box.nonce.data.withUnsafeBytes { nonce in box.tag.withUnsafeBytes { tag in box.ciphertext.withUnsafeBytes { sealed in
                pacer_aes256_gcm_open(key.bindMemory(to: UInt8.self).baseAddress!, nonce.bindMemory(to: UInt8.self).baseAddress!,
                    tag.bindMemory(to: UInt8.self).baseAddress!, sealed.bindMemory(to: UInt8.self).baseAddress!, sealed.count, &plain)
            } } } }
            guard count >= 0 else { throw count == -2 ? CryptoKitError.authenticationFailure : CryptoKitError.incorrectParameterSize }
            return Data(plain)
        }
        public static func seal(_ message: Data, using key: SymmetricKey) throws -> SealedBox {
            guard key.data.count == 32, (1...Int(Int32.max)).contains(message.count) else { throw CryptoKitError.incorrectParameterSize }
            var generator = SystemRandomNumberGenerator()
            let nonce = Data((0..<12).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            var sealed = [UInt8](repeating: 0, count: message.count), tag = [UInt8](repeating: 0, count: 16)
            let count = key.data.withUnsafeBytes { key in nonce.withUnsafeBytes { nonce in message.withUnsafeBytes { plain in
                pacer_aes256_gcm_seal(key.bindMemory(to: UInt8.self).baseAddress!, nonce.bindMemory(to: UInt8.self).baseAddress!,
                    plain.bindMemory(to: UInt8.self).baseAddress!, plain.count, &sealed, &tag)
            } } }
            guard count == message.count else { throw CryptoKitError.incorrectParameterSize }
            return SealedBox(nonce: .init(data: nonce), ciphertext: Data(sealed), tag: Data(tag))
        }
    }
}
