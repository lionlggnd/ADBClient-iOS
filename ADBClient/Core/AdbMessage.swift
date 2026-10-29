import Foundation

/// A packet of the ADB transport protocol (see AOSP `adb/protocol.txt`).
struct AdbMessage {
    static let cnxn: UInt32 = 0x4e58_4e43
    static let auth: UInt32 = 0x4854_5541
    static let open: UInt32 = 0x4e45_504f
    static let okay: UInt32 = 0x5941_4b4f
    static let clse: UInt32 = 0x4553_4c43
    static let wrte: UInt32 = 0x4554_5257
    static let stls: UInt32 = 0x534c_5453

    static let protocolVersion: UInt32 = 0x0100_0001
    static let stlsVersion: UInt32 = 0x0100_0000
    static let maxPayload: UInt32 = 256 * 1024
    static let headerSize = 24

    static let authToken: UInt32 = 1
    static let authSignature: UInt32 = 2
    static let authRSAPublicKey: UInt32 = 3

    var command: UInt32
    var arg0: UInt32
    var arg1: UInt32
    var payload: Data

    init(_ command: UInt32, _ arg0: UInt32, _ arg1: UInt32, _ payload: Data = Data()) {
        self.command = command
        self.arg0 = arg0
        self.arg1 = arg1
        self.payload = payload
    }

    func encoded() -> Data {
        var data = Data(capacity: AdbMessage.headerSize + payload.count)
        data.appendLE(command)
        data.appendLE(arg0)
        data.appendLE(arg1)
        data.appendLE(UInt32(payload.count))
        data.appendLE(payload.reduce(UInt32(0)) { $0 &+ UInt32($1) })
        data.appendLE(command ^ 0xffff_ffff)
        data.append(payload)
        return data
    }
}

extension Data {
    mutating func appendLE(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    func readLE32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(self[startIndex + offset + i]) << (8 * UInt32(i))
        }
        return value
    }

    static func cString(_ string: String) -> Data {
        Data((string + "\0").utf8)
    }
}

enum AdbError: LocalizedError {
    case connectionFailed(String)
    case authRejected
    case protocolError(String)
    case streamOpenFailed(String)
    case closed
    case timeout
    case notConnected
    case pairingFailed(String)
    case commandFailed(String)
    case invalidArgument(String)
    case keyError(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let m): return NSLocalizedString(m, comment: "")
        case .authRejected: return String(localized: "The device rejected the authorization.")
        case .protocolError(let m): return String(localized: "Protocol error: \(m)")
        case .streamOpenFailed(let s): return String(localized: "The device refused the service '\(s)'.")
        case .closed: return String(localized: "Connection closed.")
        case .timeout: return String(localized: "Timed out.")
        case .notConnected: return String(localized: "No device connected.")
        case .pairingFailed(let m): return String(localized: "Pairing failed: \(NSLocalizedString(m, comment: ""))")
        case .commandFailed(let m): return m
        case .invalidArgument(let m): return m
        case .keyError(let m): return String(localized: "ADB key error: \(NSLocalizedString(m, comment: ""))")
        }
    }
}

/// Runs blocking work (sockets, file IO) off the main thread.
func runBlocking<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try work() })
        }
    }
}

/// Calls a C function that fills an error buffer, returning its result and the message.
func withErrorBuffer<T>(_ body: (UnsafeMutablePointer<CChar>, Int) -> T) -> (T, String) {
    var buffer = [CChar](repeating: 0, count: 512)
    let result = buffer.withUnsafeMutableBufferPointer { body($0.baseAddress!, $0.count) }
    return (result, String(cString: buffer))
}

extension String {
    /// Quotes a string for the device's /system/bin/sh.
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
