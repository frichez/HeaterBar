import CommonCrypto
import CryptoKit
import Foundation

/// The encryption Philips air devices use on their local CoAP API. Each message
/// starts with an 8-hex-digit counter: MD5("JiangPan" + counter) gives the
/// AES-128-CBC key (first half) and IV (second half), and a SHA-256 over the
/// counter and ciphertext closes the message.
enum PhilipsCrypto {
    private static let secret = "JiangPan"

    static func encrypt(_ plaintext: String, counter: String) -> String? {
        let (key, iv) = keyAndIV(for: counter)
        guard let ciphertext = aes(CCOperation(kCCEncrypt), Data(plaintext.utf8), key: key, iv: iv) else { return nil }
        let body = counter + ciphertext.hexString
        return body + SHA256.hash(data: Data(body.utf8)).hexString
    }

    static func decrypt(_ message: String) -> String? {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard message.count > 72 else { return nil }
        let counter = String(message.prefix(8))
        let ciphertextHex = String(message.dropFirst(8).dropLast(64))
        guard SHA256.hash(data: Data((counter + ciphertextHex).utf8)).hexString == String(message.suffix(64)),
              let ciphertext = Data(hexString: ciphertextHex) else { return nil }
        let (key, iv) = keyAndIV(for: counter)
        guard let plaintext = aes(CCOperation(kCCDecrypt), ciphertext, key: key, iv: iv) else { return nil }
        return String(data: plaintext, encoding: .utf8)
    }

    /// Every command moves the counter on by one, wrapping like the device does.
    static func nextCounter(after counter: String) -> String {
        String(format: "%08X", (UInt32(counter, radix: 16) ?? 0) &+ 1)
    }

    private static func keyAndIV(for counter: String) -> (Data, Data) {
        let hex = Insecure.MD5.hash(data: Data((secret + counter).utf8)).hexString
        return (Data(hex.prefix(16).utf8), Data(hex.suffix(16).utf8))
    }

    private static func aes(_ operation: CCOperation, _ input: Data, key: Data, iv: Data) -> Data? {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var produced = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, v.baseAddress,
                                inp.baseAddress, input.count, out.baseAddress, capacity, &produced)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(produced)
    }
}

/// Just enough of CoAP (RFC 7252) for the heaters: requests with Uri-Path and
/// Observe options, and parsing whatever comes back.
struct CoAPMessage {
    enum Kind: UInt8 { case confirmable = 0, nonConfirmable = 1, acknowledgement = 2, reset = 3 }

    static let get: UInt8 = 0x01
    static let post: UInt8 = 0x02
    static let content: UInt8 = 0x45  // 2.05

    var kind: Kind
    var code: UInt8
    var messageID: UInt16
    var token: [UInt8]
    var options: [(number: Int, value: [UInt8])] = []
    var payload: [UInt8] = []

    /// The heaters answer non-confirmable requests promptly; confirmable ones
    /// can sit for seconds before the first reply.
    static func request(_ code: UInt8, path: String, messageID: UInt16, token: [UInt8],
                        observe: Bool = false, deregister: Bool = false, payload: String = "") -> CoAPMessage {
        var options: [(number: Int, value: [UInt8])] = observe ? [(6, deregister ? [1] : [])] : []
        options += path.split(separator: "/").map { (11, Array($0.utf8)) }
        return CoAPMessage(kind: .nonConfirmable, code: code, messageID: messageID, token: token,
                           options: options, payload: Array(payload.utf8))
    }

    /// Options must already be in ascending order, which `request` guarantees.
    func encoded() -> [UInt8] {
        var out: [UInt8] = [0x40 | kind.rawValue << 4 | UInt8(token.count), code,
                            UInt8(messageID >> 8), UInt8(messageID & 0xff)]
        out += token
        var previous = 0
        for option in options {
            let (deltaNibble, deltaExtra) = Self.nibble(option.number - previous)
            let (lengthNibble, lengthExtra) = Self.nibble(option.value.count)
            out.append(deltaNibble << 4 | lengthNibble)
            out += deltaExtra + lengthExtra + option.value
            previous = option.number
        }
        if !payload.isEmpty { out += [0xff] + payload }
        return out
    }

    private static func nibble(_ value: Int) -> (UInt8, [UInt8]) {
        if value < 13 { return (UInt8(value), []) }
        if value < 269 { return (13, [UInt8(value - 13)]) }
        return (14, [UInt8((value - 269) >> 8), UInt8((value - 269) & 0xff)])
    }
}

extension CoAPMessage {
    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 4, bytes[0] >> 6 == 1 else { return nil }
        let tokenLength = Int(bytes[0] & 0x0f)
        guard tokenLength <= 8, bytes.count >= 4 + tokenLength,
              let kind = Kind(rawValue: (bytes[0] >> 4) & 0x03) else { return nil }
        self.kind = kind
        code = bytes[1]
        messageID = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        token = Array(bytes[4..<4 + tokenLength])
        var index = 4 + tokenLength
        var number = 0
        while index < bytes.count {
            if bytes[index] == 0xff {
                payload = Array(bytes[(index + 1)...])
                break
            }
            let header = bytes[index]
            index += 1
            guard let delta = Self.extended(Int(header >> 4), bytes, &index),
                  let length = Self.extended(Int(header & 0x0f), bytes, &index),
                  index + length <= bytes.count else { return nil }
            number += delta
            options.append((number, Array(bytes[index..<index + length])))
            index += length
        }
    }

    private static func extended(_ nibble: Int, _ bytes: [UInt8], _ index: inout Int) -> Int? {
        switch nibble {
        case 13:
            guard index < bytes.count else { return nil }
            index += 1
            return Int(bytes[index - 1]) + 13
        case 14:
            guard index + 1 < bytes.count else { return nil }
            index += 2
            return (Int(bytes[index - 2]) << 8 | Int(bytes[index - 1])) + 269
        case 15:
            return nil
        default:
            return nibble
        }
    }
}

extension Sequence where Element == UInt8 {
    var hexString: String { map { String(format: "%02X", $0) }.joined() }
}

extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
