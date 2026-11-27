import CryptoKit
import Foundation
import Security

/// Client side of the pairing handshake and message encryption spoken by
/// Apple's PasswordManagerBrowserExtensionHelper. Mirrors the `SecretSession`
/// in Apple's iCloud Passwords browser extension: SRP-6a over the RFC 5054
/// 3072-bit group with SHA-256 and RFC 2945 M/HAMK verification, the
/// verification code the helper displays as the SRP password, and
/// AES-128-GCM (key = first 16 bytes of K) for every message after pairing.
///
/// Values travel as "0x"-prefixed hex, or as base64 when the helper's
/// capabilities say `shouldUseBase64`.
///
/// Owned by PasswordManager, which only hands it to a detached task for the
/// slow exponentiations and never uses it from two places at once.
nonisolated final class SRPSession: @unchecked Sendable {
    enum SessionError: Error, LocalizedError {
        case malformedMessage(String)
        case unsupportedProtocol
        case incorrectCode
        case helperError(Int)
        case verificationFailed
        case notPaired

        var errorDescription: String? {
            switch self {
            case .malformedMessage(let detail): return "Unexpected message from Passwords: \(detail)"
            case .unsupportedProtocol: return "Passwords uses an unsupported pairing protocol."
            case .incorrectCode: return "The verification code was incorrect."
            case .helperError(let code): return "Passwords rejected pairing (error \(code))."
            case .verificationFailed: return "Couldn't verify the connection to Passwords."
            case .notPaired: return "Klar isn't connected to Passwords."
            }
        }
    }

    private static let protocolVersion = "1.0"
    /// SRPWithRFCVerification; the legacy variant (0) isn't implemented.
    private static let rfcVerification = 1
    private static let ivLength = 16

    private let useBase64: Bool
    private let username: Data          // I
    private let privateKey: [UInt32]    // a
    private let publicKey: Data         // A, minimal big-endian
    private var salt: Data?
    private var serverPublicKey: Data?  // B, minimal big-endian
    private var proofKey: Data?         // K while waiting for the server proof
    private var expectedServerProof: Data?
    private var sessionKey: SymmetricKey?

    var isPaired: Bool { sessionKey != nil }

    /// Session identifier the helper uses to route messages; also SRP's I.
    var tid: String { encode(username, prefixed: true) }

    init(useBase64: Bool) {
        self.useBase64 = useBase64
        // The extension serialises I as a bignum, which drops leading zero
        // bytes; a non-zero first byte keeps the bytes and the string in step.
        var username = Self.randomBytes(16)
        while username[0] == 0 { username = Self.randomBytes(16) }
        self.username = username
        let privateKey = SRPGroup.limbs(fromBigEndian: Self.randomBytes(32))
        self.privateKey = privateKey
        publicKey = SRPGroup.bigEndianBytes(SRPGroup.shared.power(SRPGroup.generator, privateKey))
    }

    /// What a paired session needs to go on in another Klar process
    /// (ApplePasswordsHandover): I, the message key and the encoding.
    struct Pairing: Codable {
        let username: Data
        let key: Data
        let useBase64: Bool
    }

    var pairing: Pairing? {
        sessionKey.map { key in
            Pairing(username: username, key: key.withUnsafeBytes { Data($0) }, useBase64: useBase64)
        }
    }

    /// A session paired in an earlier Klar process, with the same helper.
    init(resuming pairing: Pairing) {
        useBase64 = pairing.useBase64
        username = pairing.username
        // Only pairing uses the key pair, and this one is paired.
        privateKey = []
        publicKey = Data()
        sessionKey = SymmetricKey(data: pairing.key)
    }

    // MARK: - Pairing

    /// MSG0: the client's public key. Base64 JSON for the `PAKE` field.
    func clientHello() throws -> String {
        try Self.base64JSON([
            "TID": tid,
            "MSG": 0,
            "A": encode(publicKey, prefixed: true),
            "VER": Self.protocolVersion,
            "PROTO": [Self.rfcVerification]
        ])
    }

    /// Reads MSG1 (salt and server public key). The helper shows the
    /// verification code once it has sent this.
    func receiveServerHello(_ pake: String) throws {
        let message = try parsePAKE(pake, expecting: 1)
        if let code = Self.integer(message["ErrCode"]), code != 0 {
            throw SessionError.helperError(code)
        }
        if let proto = Self.integer(message["PROTO"]), proto != Self.rfcVerification {
            throw SessionError.unsupportedProtocol
        }
        guard
            let saltString = message["s"] as? String, let salt = decode(saltString),
            let keyString = message["B"] as? String, let serverKey = decode(keyString)
        else {
            throw SessionError.malformedMessage("server hello is missing s or B")
        }
        let key = SRPGroup.stripLeadingZeros(serverKey)
        guard !key.isEmpty, key.count <= SRPGroup.byteCount,
              SRPGroup.compare(SRPGroup.limbs(fromBigEndian: key), SRPGroup.shared.modulus) < 0
        else {
            throw SessionError.malformedMessage("invalid server public key")
        }
        self.salt = salt
        serverPublicKey = key
    }

    /// MSG2: proof that the client knows `code`. Base64 JSON for `PAKE`.
    /// Runs two 3072-bit modular exponentiations; call off the main thread.
    func clientProof(code: String) throws -> String {
        guard let salt, let serverPublicKey else {
            throw SessionError.malformedMessage("no server hello received")
        }
        let group = SRPGroup.shared
        let modulusBytes = SRPGroup.bigEndianBytes(group.modulus)
        let paddedGenerator = SRPGroup.padded(SRPGroup.bigEndianBytes(SRPGroup.generator))

        let x = Self.sha256(salt + Self.sha256(Data("\(tid):\(code)".utf8)))
        let k = Self.sha256(modulusBytes + paddedGenerator)
        let u = Self.sha256(SRPGroup.padded(publicKey) + SRPGroup.padded(serverPublicKey))

        // S = (B - k·g^x) ^ (a + u·x) mod N
        let verifier = group.power(SRPGroup.generator, SRPGroup.limbs(fromBigEndian: x))
        let kv = group.multiply(SRPGroup.limbs(fromBigEndian: k), verifier)
        let b = SRPGroup.limbs(fromBigEndian: serverPublicKey)
        let base = SRPGroup.compare(b, kv) >= 0
            ? SRPGroup.subtract(b, kv)
            : SRPGroup.subtract(group.modulus, SRPGroup.subtract(kv, b))
        guard base.contains(where: { $0 != 0 }) else {
            throw SessionError.malformedMessage("degenerate server public key")
        }
        let exponent = SRPGroup.add(
            privateKey,
            SRPGroup.product(SRPGroup.limbs(fromBigEndian: u), SRPGroup.limbs(fromBigEndian: x))
        )
        let premaster = group.power(base, exponent)
        let key = Self.sha256(SRPGroup.bigEndianBytes(premaster))

        let hashedModulus = Self.sha256(modulusBytes)
        let hashedGenerator = Self.sha256(paddedGenerator)
        let groupHash = Data(zip(hashedModulus, hashedGenerator).map { $0 ^ $1 })
        let proof = Self.sha256(
            groupHash + Self.sha256(Data(tid.utf8)) + salt + publicKey + serverPublicKey + key
        )
        proofKey = key
        expectedServerProof = Self.sha256(publicKey + proof + key)

        return try Self.base64JSON([
            "TID": tid,
            "MSG": 2,
            "M": encode(proof, prefixed: false)
        ])
    }

    /// Reads MSG3 and, if the helper's proof checks out, completes pairing.
    func receiveServerProof(_ pake: String) throws {
        let message = try parsePAKE(pake, expecting: 3)
        let code = Self.integer(message["ErrCode"]) ?? -1
        switch code {
        case 0: break
        case 1: throw SessionError.incorrectCode
        default: throw SessionError.helperError(code)
        }
        guard
            let proofString = message["HAMK"] as? String,
            let proof = decode(proofString),
            let expectedServerProof, let proofKey,
            proof == expectedServerProof
        else {
            throw SessionError.verificationFailed
        }
        sessionKey = SymmetricKey(data: proofKey.prefix(16))
        self.proofKey = nil
        self.expectedServerProof = nil
    }

    // MARK: - Encrypted messages

    /// Wraps a request body in the `SMSG` envelope, as a JSON string.
    func seal(_ body: [String: Any]) throws -> String {
        guard let sessionKey else { throw SessionError.notPaired }
        let plaintext = try JSONSerialization.data(withJSONObject: body)
        let iv = Self.randomBytes(Self.ivLength)
        let box = try AES.GCM.seal(plaintext, using: sessionKey, nonce: AES.GCM.Nonce(data: iv))
        // Outgoing layout is ciphertext ‖ tag ‖ IV.
        let sealed = box.ciphertext + box.tag + iv
        let envelope = try JSONSerialization.data(withJSONObject: [
            "TID": tid,
            "SDATA": encode(sealed, prefixed: false)
        ])
        return String(decoding: envelope, as: UTF8.self)
    }

    /// Opens an `SMSG` envelope (JSON string or object) from the helper.
    func open(_ envelope: Any?) throws -> [String: Any] {
        guard let sessionKey else { throw SessionError.notPaired }
        var object = envelope
        if let string = envelope as? String {
            object = try? JSONSerialization.jsonObject(with: Data(string.utf8))
        }
        guard
            let dictionary = object as? [String: Any],
            let messageTID = dictionary["TID"] as? String,
            let sdata = dictionary["SDATA"] as? String,
            let sealed = decode(sdata),
            sealed.count > Self.ivLength + 16
        else {
            throw SessionError.malformedMessage("invalid SMSG")
        }
        guard sameIdentifier(messageTID) else {
            throw SessionError.malformedMessage("SMSG for another session")
        }
        // Incoming layout is IV ‖ ciphertext ‖ tag.
        let iv = sealed.prefix(Self.ivLength)
        let body = sealed.dropFirst(Self.ivLength)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: iv),
            ciphertext: body.dropLast(16),
            tag: body.suffix(16)
        )
        let plaintext = try AES.GCM.open(box, using: sessionKey)
        guard let decoded = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw SessionError.malformedMessage("SMSG body is not an object")
        }
        return decoded
    }

    // MARK: - Encoding

    private func encode(_ data: Data, prefixed: Bool) -> String {
        if useBase64 { return data.base64EncodedString() }
        return (prefixed ? "0x" : "") + data.map { String(format: "%02x", $0) }.joined()
    }

    private func decode(_ string: String) -> Data? {
        if useBase64 { return Data(base64Encoded: string) }
        var hex = string.replacingOccurrences(of: "0x", with: "")
        hex.removeAll(where: \.isWhitespace)
        if hex.count % 2 == 1 { hex = "0" + hex }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// TIDs are compared as numbers, like the extension does.
    private func sameIdentifier(_ other: String) -> Bool {
        guard let bytes = decode(other) else { return false }
        return SRPGroup.stripLeadingZeros(bytes) == username
    }

    private func parsePAKE(_ pake: String, expecting messageType: Int) throws -> [String: Any] {
        guard
            let json = Data(base64Encoded: pake),
            let message = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else {
            throw SessionError.malformedMessage("PAKE is not base64 JSON")
        }
        guard let messageTID = message["TID"] as? String, sameIdentifier(messageTID) else {
            throw SessionError.malformedMessage("PAKE for another session")
        }
        // macOS sends MSG as a number, iCloud for Windows as a string.
        guard Self.integer(message["MSG"]) == messageType else {
            throw SessionError.malformedMessage("expected MSG\(messageType)")
        }
        return message
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func base64JSON(_ object: [String: Any]) throws -> String {
        try JSONSerialization.data(withJSONObject: object).base64EncodedString()
    }

    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }
}

/// Arithmetic modulo the RFC 5054 3072-bit prime. Numbers are little-endian
/// arrays of 32-bit limbs; exponentiation uses Montgomery multiplication so
/// no general-purpose division is needed.
nonisolated private struct SRPGroup {
    static let shared = SRPGroup()
    static let limbCount = 96
    static let byteCount = limbCount * 4
    static let generator: [UInt32] = [5]

    let modulus: [UInt32]
    /// -N⁻¹ mod 2³²
    private let inverse: UInt32
    /// R² mod N, with R = 2^3072
    private let rSquared: [UInt32]

    private init() {
        let hex = """
            FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74\
            020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437\
            4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED\
            EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05\
            98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB\
            9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B\
            E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718\
            3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33\
            A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7\
            ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864\
            D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2\
            08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
            """
        var limbs = [UInt32]()
        var end = hex.endIndex
        while end > hex.startIndex {
            let start = hex.index(end, offsetBy: -8)
            limbs.append(UInt32(hex[start..<end], radix: 16)!)
            end = start
        }
        modulus = limbs

        // Newton's iteration doubles the correct low bits each step.
        var inverse: UInt32 = 1
        for _ in 0..<5 { inverse = inverse &* (2 &- limbs[0] &* inverse) }
        self.inverse = 0 &- inverse

        // R² mod N by doubling 1 a total of 2·3072 times.
        var value = [UInt32](repeating: 0, count: Self.limbCount + 1)
        value[0] = 1
        let wideModulus = limbs + [0]
        for _ in 0..<(2 * Self.limbCount * 32) {
            var carry: UInt32 = 0
            for i in 0..<value.count {
                let next = value[i] >> 31
                value[i] = (value[i] << 1) | carry
                carry = next
            }
            if Self.compare(value, wideModulus) >= 0 {
                value = Self.subtract(value, wideModulus)
            }
        }
        rSquared = Array(value.prefix(Self.limbCount))
    }

    /// base^exponent mod N, for base < N.
    func power(_ base: [UInt32], _ exponent: [UInt32]) -> [UInt32] {
        let montgomeryBase = montgomeryProduct(Self.resized(base), rSquared)
        var result = montgomeryProduct([1] + [UInt32](repeating: 0, count: Self.limbCount - 1), rSquared)
        for limb in exponent.reversed() {
            for bit in stride(from: 31, through: 0, by: -1) {
                result = montgomeryProduct(result, result)
                if (limb >> UInt32(bit)) & 1 == 1 {
                    result = montgomeryProduct(result, montgomeryBase)
                }
            }
        }
        return montgomeryProduct(result, [1] + [UInt32](repeating: 0, count: Self.limbCount - 1))
    }

    /// a·b mod N, for a, b < N.
    func multiply(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        montgomeryProduct(montgomeryProduct(Self.resized(a), Self.resized(b)), rSquared)
    }

    /// a·b·R⁻¹ mod N (CIOS Montgomery multiplication), for a, b < N.
    private func montgomeryProduct(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        let n = Self.limbCount
        var t = [UInt32](repeating: 0, count: n + 2)
        a.withUnsafeBufferPointer { a in
        b.withUnsafeBufferPointer { b in
        modulus.withUnsafeBufferPointer { m in
        t.withUnsafeMutableBufferPointer { t in
            for i in 0..<n {
                var carry: UInt64 = 0
                let ai = UInt64(a[i])
                for j in 0..<n {
                    let sum = UInt64(t[j]) + ai * UInt64(b[j]) + carry
                    t[j] = UInt32(truncatingIfNeeded: sum)
                    carry = sum >> 32
                }
                var sum = UInt64(t[n]) + carry
                t[n] = UInt32(truncatingIfNeeded: sum)
                t[n + 1] = UInt32(sum >> 32)

                let factor = UInt64(t[0] &* inverse)
                sum = UInt64(t[0]) + factor * UInt64(m[0])
                carry = sum >> 32
                for j in 1..<n {
                    sum = UInt64(t[j]) + factor * UInt64(m[j]) + carry
                    t[j - 1] = UInt32(truncatingIfNeeded: sum)
                    carry = sum >> 32
                }
                sum = UInt64(t[n]) + carry
                t[n - 1] = UInt32(truncatingIfNeeded: sum)
                t[n] = t[n + 1] + UInt32(sum >> 32)
                t[n + 1] = 0
            }
        }
        }
        }
        }
        var result = Array(t.prefix(n + 1))
        let wideModulus = modulus + [0]
        if Self.compare(result, wideModulus) >= 0 {
            result = Self.subtract(result, wideModulus)
        }
        return Array(result.prefix(n))
    }

    // MARK: - Plain unsigned arithmetic

    static func limbs(fromBigEndian data: Data) -> [UInt32] {
        let bytes = [UInt8](data)
        var limbs = [UInt32](repeating: 0, count: max(1, (bytes.count + 3) / 4))
        for (offset, byte) in bytes.reversed().enumerated() {
            limbs[offset / 4] |= UInt32(byte) << (8 * UInt32(offset % 4))
        }
        return limbs
    }

    /// Minimal big-endian bytes, as the extension's bignum `toBits()` gives.
    static func bigEndianBytes(_ limbs: [UInt32]) -> Data {
        var bytes = [UInt8]()
        for limb in limbs.reversed() {
            bytes += [UInt8(limb >> 24), UInt8(truncatingIfNeeded: limb >> 16),
                      UInt8(truncatingIfNeeded: limb >> 8), UInt8(truncatingIfNeeded: limb)]
        }
        return stripLeadingZeros(Data(bytes))
    }

    static func stripLeadingZeros(_ data: Data) -> Data {
        Data(data.drop(while: { $0 == 0 }))
    }

    /// Left-pads to the modulus length (PAD() in RFC 5054).
    static func padded(_ data: Data) -> Data {
        Data(repeating: 0, count: max(0, byteCount - data.count)) + data
    }

    static func compare(_ a: [UInt32], _ b: [UInt32]) -> Int {
        for i in stride(from: max(a.count, b.count) - 1, through: 0, by: -1) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    /// a - b, for a ≥ b; the result has a's length.
    static func subtract(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var result = a
        var borrow: Int64 = 0
        for i in 0..<a.count {
            var difference = Int64(a[i]) - Int64(i < b.count ? b[i] : 0) - borrow
            borrow = difference < 0 ? 1 : 0
            if difference < 0 { difference += 1 << 32 }
            result[i] = UInt32(difference)
        }
        return result
    }

    static func add(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var result = [UInt32](repeating: 0, count: max(a.count, b.count) + 1)
        var carry: UInt64 = 0
        for i in 0..<(result.count - 1) {
            let sum = UInt64(i < a.count ? a[i] : 0) + UInt64(i < b.count ? b[i] : 0) + carry
            result[i] = UInt32(truncatingIfNeeded: sum)
            carry = sum >> 32
        }
        result[result.count - 1] = UInt32(carry)
        return result
    }

    static func product(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var result = [UInt32](repeating: 0, count: a.count + b.count)
        for i in 0..<a.count {
            var carry: UInt64 = 0
            for j in 0..<b.count {
                let sum = UInt64(result[i + j]) + UInt64(a[i]) * UInt64(b[j]) + carry
                result[i + j] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
            }
            result[i + b.count] = UInt32(carry)
        }
        return result
    }

    private static func resized(_ limbs: [UInt32]) -> [UInt32] {
        if limbs.count >= limbCount { return Array(limbs.prefix(limbCount)) }
        return limbs + [UInt32](repeating: 0, count: limbCount - limbs.count)
    }
}
