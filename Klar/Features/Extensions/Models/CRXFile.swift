import CryptoKit
import Foundation
import Security

/// A Chrome extension package in the CRX3 format, as the Chrome Web Store
/// serves it, checked the way Chrome checks one before installing it.
///
/// Layout: `Cr24`, format version 3, the header's length, a protobuf
/// `CrxFileHeader`, then the extension's zip archive. The header carries
/// signatures ("proofs") over the archive, each with the public key that
/// made it. Every proof must hold, one must be by the developer's key (whose
/// SHA-256 names the extension: its ID is the first 16 bytes, 0–f written
/// as a–p), and a store install must also be signed by the Web Store's own
/// key. See Chromium's components/crx_file/crx_verifier.cc.
nonisolated struct CRXFile {
    /// The extension's ID, from the developer's key.
    let extensionID: String
    /// The extension's files, zipped.
    let archive: Data

    enum Error: LocalizedError {
        case notCRX3
        case malformedHeader
        case wrongExtension(expected: String, found: String)
        case missingDeveloperSignature
        case missingStoreSignature
        case invalidSignature

        var errorDescription: String? {
            switch self {
            case .notCRX3: return "The download isn't a Chrome extension package."
            case .malformedHeader: return "The extension package is damaged."
            case .wrongExtension(let expected, let found):
                return "The store sent a different extension (\(found)) than the one asked for (\(expected))."
            case .missingDeveloperSignature: return "The extension package isn't signed by its developer."
            case .missingStoreSignature: return "The extension package isn't signed by the Chrome Web Store."
            case .invalidSignature: return "The extension package's signature doesn't match its contents."
            }
        }
    }

    /// SHA-256 of the Chrome Web Store's publisher key (DER SPKI), which
    /// signs every package the store serves. Chromium's kPublisherKeyHash.
    private static let storePublisherKeyHash: [UInt8] = [
        0x61, 0xf7, 0xf2, 0xa6, 0xbf, 0xcf, 0x74, 0xcd, 0x0b, 0xc1, 0xfe,
        0x24, 0x97, 0xcc, 0x9b, 0x04, 0x25, 0x4c, 0x65, 0x8f, 0x79, 0xf2,
        0x14, 0x53, 0x92, 0x86, 0x7e, 0xa8, 0x36, 0x63, 0x67, 0xcf
    ]

    private static let signatureContext = Array("CRX3 SignedData\0".utf8)

    private enum Algorithm {
        case rsaSHA256, ecdsaSHA256
    }

    /// Parses and verifies `data`. `expectedID`, when given, is the
    /// extension that was asked for.
    init(data: Data, expectedID: String?, requireStoreSignature: Bool) throws {
        let bytes = [UInt8](data)
        guard bytes.count > 12, bytes[0..<4] == [0x43, 0x72, 0x32, 0x34] /* Cr24 */ else { throw Error.notCRX3 }
        guard Self.uint32(bytes, at: 4) == 3 else { throw Error.notCRX3 }
        let headerLength = Int(Self.uint32(bytes, at: 8))
        let headerStart = 12
        guard headerLength > 0, bytes.count > headerStart + headerLength else { throw Error.malformedHeader }
        let header = Array(bytes[headerStart..<(headerStart + headerLength)])
        let archive = data.subdata(in: (headerStart + headerLength)..<data.count)

        // CrxFileHeader: 2 = sha256_with_rsa proofs, 3 = sha256_with_ecdsa
        // proofs (AsymmetricKeyProof: 1 = public_key, 2 = signature),
        // 10000 = signed_header_data (SignedData: 1 = crx_id).
        var proofs: [(algorithm: Algorithm, publicKey: [UInt8], signature: [UInt8])] = []
        var signedHeaderData: [UInt8]?
        for field in try Self.protobufFields(header) {
            switch field.number {
            case 2, 3:
                let proof = try Self.protobufFields(field.value)
                guard let key = proof.first(where: { $0.number == 1 })?.value,
                      let signature = proof.first(where: { $0.number == 2 })?.value else {
                    throw Error.malformedHeader
                }
                proofs.append((field.number == 2 ? .rsaSHA256 : .ecdsaSHA256, key, signature))
            case 10000:
                signedHeaderData = field.value
            default:
                continue
            }
        }
        guard let signedHeaderData,
              let crxID = try Self.protobufFields(signedHeaderData).first(where: { $0.number == 1 })?.value,
              crxID.count == 16 else {
            throw Error.malformedHeader
        }
        let extensionID = Self.extensionID(fromHashPrefix: crxID)
        if let expectedID, expectedID != extensionID {
            throw Error.wrongExtension(expected: expectedID, found: extensionID)
        }

        var signedData = Data(Self.signatureContext)
        var signedHeaderLength = UInt32(signedHeaderData.count).littleEndian
        signedData.append(Data(bytes: &signedHeaderLength, count: 4))
        signedData.append(contentsOf: signedHeaderData)
        signedData.append(archive)

        var hasDeveloperProof = false
        var hasStoreProof = false
        for proof in proofs {
            let keyHash = Array(SHA256.hash(data: proof.publicKey))
            guard Self.verify(proof.signature, of: signedData, publicKey: proof.publicKey, algorithm: proof.algorithm) else {
                throw Error.invalidSignature
            }
            if Array(keyHash.prefix(16)) == crxID { hasDeveloperProof = true }
            if keyHash == Self.storePublisherKeyHash { hasStoreProof = true }
        }
        guard hasDeveloperProof else { throw Error.missingDeveloperSignature }
        if requireStoreSignature, !hasStoreProof { throw Error.missingStoreSignature }

        self.extensionID = extensionID
        self.archive = archive
    }

    /// The ID Chrome derives from `data`: an extension's public key (DER
    /// SPKI, e.g. the `key` field of an unpacked extension's manifest), or,
    /// for an unpacked extension without one, its folder's path.
    static func extensionID(hashing data: Data) -> String {
        extensionID(fromHashPrefix: Array(SHA256.hash(data: data).prefix(16)))
    }

    /// A Chrome extension ID: 32 letters a–p.
    static func isValidExtensionID(_ string: String) -> Bool {
        string.count == 32 && string.allSatisfy { ("a"..."p").contains($0) }
    }

    private static func extensionID(fromHashPrefix bytes: [UInt8]) -> String {
        let a = UInt8(ascii: "a")
        var scalars = String.UnicodeScalarView()
        for byte in bytes {
            scalars.append(UnicodeScalar(a + (byte >> 4)))
            scalars.append(UnicodeScalar(a + (byte & 0x0f)))
        }
        return String(scalars)
    }

    // MARK: - Signatures

    private static func verify(_ signature: [UInt8], of data: Data, publicKey: [UInt8], algorithm: Algorithm) -> Bool {
        switch algorithm {
        case .ecdsaSHA256:
            guard let key = try? P256.Signing.PublicKey(derRepresentation: publicKey),
                  let ecdsaSignature = try? P256.Signing.ECDSASignature(derRepresentation: signature) else {
                return false
            }
            return key.isValidSignature(ecdsaSignature, for: data)
        case .rsaSHA256:
            guard let pkcs1 = rsaPublicKey(fromSPKI: publicKey) else { return false }
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass: kSecAttrKeyClassPublic
            ]
            guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, nil) else {
                return false
            }
            return SecKeyVerifySignature(
                key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, Data(signature) as CFData, nil
            )
        }
    }

    /// The PKCS#1 RSAPublicKey inside a DER SubjectPublicKeyInfo — what
    /// SecKeyCreateWithData takes:
    /// SEQUENCE { SEQUENCE { algorithm, parameters }, BIT STRING { key } }.
    private static func rsaPublicKey(fromSPKI spki: [UInt8]) -> [UInt8]? {
        guard let outer = derElement(spki, at: 0), outer.tag == 0x30,
              let algorithm = derElement(spki, at: outer.content.lowerBound), algorithm.tag == 0x30,
              let bitString = derElement(spki, at: algorithm.end), bitString.tag == 0x03,
              bitString.content.count > 1, spki[bitString.content.lowerBound] == 0 else {
            return nil
        }
        return Array(spki[(bitString.content.lowerBound + 1)..<bitString.content.upperBound])
    }

    private static func derElement(_ bytes: [UInt8], at index: Int) -> (tag: UInt8, content: Range<Int>, end: Int)? {
        guard index + 2 <= bytes.count else { return nil }
        let tag = bytes[index]
        var position = index + 1
        var length = Int(bytes[position])
        position += 1
        if length & 0x80 != 0 {
            let lengthBytes = length & 0x7f
            guard lengthBytes > 0, lengthBytes <= 4, position + lengthBytes <= bytes.count else { return nil }
            length = 0
            for byte in bytes[position..<(position + lengthBytes)] {
                length = length << 8 | Int(byte)
            }
            position += lengthBytes
        }
        guard position + length <= bytes.count else { return nil }
        return (tag, position..<(position + length), position + length)
    }

    // MARK: - Header parsing

    private static func uint32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[index + $1]) << (8 * $1) }
    }

    /// The length-delimited fields of a protobuf message; the CRX header
    /// uses no others, and anything else is skipped.
    private static func protobufFields(_ bytes: [UInt8]) throws -> [(number: Int, value: [UInt8])] {
        var fields: [(number: Int, value: [UInt8])] = []
        var index = 0
        func varint() throws -> Int {
            var result = 0
            var shift = 0
            while true {
                guard index < bytes.count, shift < 64 else { throw Error.malformedHeader }
                let byte = bytes[index]
                index += 1
                result |= Int(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
        }
        while index < bytes.count {
            let key = try varint()
            switch key & 0x7 {
            case 0:
                _ = try varint()
            case 1:
                index += 8
            case 2:
                let length = try varint()
                // Not `index + length`, which a length made up to be huge overflows (a crash)
                guard length >= 0, length <= bytes.count - index else { throw Error.malformedHeader }
                fields.append((key >> 3, Array(bytes[index..<(index + length)])))
                index += length
            case 5:
                index += 4
            default:
                throw Error.malformedHeader
            }
        }
        guard index == bytes.count else { throw Error.malformedHeader }
        return fields
    }
}
