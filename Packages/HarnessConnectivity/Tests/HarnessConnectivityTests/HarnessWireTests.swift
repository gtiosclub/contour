import CryptoKit
import Foundation
@testable import HarnessConnectivity
import Testing

struct HarnessWireTests {
    @Test func lengthPrefixIsBigEndianAndRejectsUnboundedRecords() throws {
        let payload = Data(repeating: 7, count: 300)
        let frame = try HarnessWire.frame(payload)
        #expect(Array(frame.prefix(4)) == [0, 0, 1, 44])
        #expect(try HarnessWire.length(Data(frame.prefix(4))) == 300)
        #expect(Data(frame.dropFirst(4)) == payload)
        #expect(throws: (any Error).self) { try HarnessWire.length(Data([0, 0, 0, 0])) }
        #expect(throws: (any Error).self) { try HarnessWire.length(Data([0, 1, 0, 1])) }
        #expect(throws: (any Error).self) { try HarnessWire.frame(Data(repeating: 0, count: 65_537)) }
        #expect(throws: (any Error).self) { try HarnessWire.length(Data([1])) }
    }

    @Test func ephemeralDirectionalKeysRoundTripAndRejectTampering() throws {
        let mac = Curve25519.KeyAgreement.PrivateKey()
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let a = try HarnessWire.Cipher(privateKey: mac, remoteKey: phone.publicKey.rawRepresentation,
                                      macHello: Data([1]), phoneHello: Data([2]), isMac: true)
        let b = try HarnessWire.Cipher(privateKey: phone, remoteKey: mac.publicKey.rawRepresentation,
                                      macHello: Data([1]), phoneHello: Data([2]), isMac: false)
        let data = Data("guidance".utf8)
        let encrypted = try a.seal(data)
        #expect(try b.open(encrypted) == data)
        #expect(try a.open(b.seal(data)) == data)
        #expect(throws: (any Error).self) { try a.open(encrypted) }
        var changed = encrypted
        changed[changed.count - 1] ^= 1
        #expect(throws: (any Error).self) { try b.open(changed) }
        let newPhone = Curve25519.KeyAgreement.PrivateKey()
        let c = try HarnessWire.Cipher(privateKey: newPhone, remoteKey: mac.publicKey.rawRepresentation,
                                      macHello: Data([1]), phoneHello: Data([2]), isMac: false)
        #expect(throws: (any Error).self) { try c.open(encrypted) }
    }
}
