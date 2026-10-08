import CryptoKit
import Foundation
import Network

/// Length-delimited TCP records. Never allocate from an unchecked remote length.
enum HarnessWire {
    static let maximumRecordSize = 65_536
    enum Failure: Error { case invalidRecord, incompatiblePeer, queueOverflow }

    struct Hello: Codable {
        let protocolName: String
        let role: String
        let name: String
        let publicKey: Data
    }

    static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumRecordSize else { throw Failure.invalidRecord }
        let length = UInt32(payload.count)
        return Data([UInt8(length >> 24), UInt8((length >> 16) & 255),
                     UInt8((length >> 8) & 255), UInt8(length & 255)]) + payload
    }

    static func length(_ header: Data) throws -> Int {
        guard header.count == 4 else { throw Failure.invalidRecord }
        let size = header.reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0, size <= maximumRecordSize else { throw Failure.invalidRecord }
        return size
    }

    static func read(from connection: NetworkConnection<TCP>) async throws -> Data {
        let header = try await connection.receive(exactly: 4)
        let size = try length(header.content)
        let body = try await connection.receive(exactly: size)
        guard body.content.count == size else { throw Failure.invalidRecord }
        return body.content
    }

    static func write(_ data: Data, to connection: NetworkConnection<TCP>) async throws {
        try await connection.send(frame(data))
    }

    /// Ephemeral keys encrypt each connection without installing certificates.
    /// Automatic discovery does not authenticate a device's identity; this is a developer harness.
    struct Cipher: Sendable {
        let sendingKey: SymmetricKey
        let receivingKey: SymmetricKey

        init(privateKey: Curve25519.KeyAgreement.PrivateKey, remoteKey: Data,
             macHello: Data, phoneHello: Data, isMac: Bool) throws {
            let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteKey)
            let secret = try privateKey.sharedSecretFromKeyAgreement(with: remote)
            let salt = Data(SHA256.hash(data: macHello + phoneHello))
            func key(_ direction: String) -> SymmetricKey {
                secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                    sharedInfo: Data(direction.utf8), outputByteCount: 32)
            }
            sendingKey = key(isMac ? "mac-phone" : "phone-mac")
            receivingKey = key(isMac ? "phone-mac" : "mac-phone")
        }

        func seal(_ data: Data) throws -> Data {
            guard let combined = try AES.GCM.seal(data, using: sendingKey).combined else {
                throw Failure.invalidRecord
            }
            return combined
        }

        func open(_ data: Data) throws -> Data {
            try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: receivingKey)
        }
    }
}
