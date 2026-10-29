import Foundation

/// Owns the RSA key that identifies this app to Android devices.
final class AdbKeyStore {
    static let shared = AdbKeyStore()

    private let lock = NSLock()
    private var cached: OpaquePointer?

    static var keyURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("adbkey")
    }

    var keyName: String {
        get {
            let name = UserDefaults.standard.string(forKey: "adbKeyName") ?? ""
            return name.isEmpty ? "adbclient@ios" : name
        }
        set { UserDefaults.standard.set(newValue, forKey: "adbKeyName") }
    }

    func key() throws -> OpaquePointer {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        try ensureDirectory()
        let path = AdbKeyStore.keyURL.path
        let (key, message) = withErrorBuffer { adb_key_load_or_create(path, $0, $1) }
        guard let key else { throw AdbError.keyError(message) }
        cached = key
        return key
    }

    /// Replaces the key. Devices will need to authorize (or pair) the app again.
    func regenerate() throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureDirectory()
        let path = AdbKeyStore.keyURL.path
        let (key, message) = withErrorBuffer { adb_key_generate_to(path, $0, $1) }
        guard let key else { throw AdbError.keyError(message) }
        // The old key is intentionally leaked: a live connection may still reference it.
        cached = key
    }

    func publicKey() throws -> String {
        try AdbKeyStore.publicKeyString(key: key(), name: keyName)
    }

    static func publicKeyString(key: OpaquePointer, name: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: 2048)
        let length = buffer.withUnsafeMutableBufferPointer { adb_key_public_string(key, name, $0.baseAddress, $0.count) }
        guard length > 0 else { throw AdbError.keyError("codifica della chiave pubblica fallita") }
        return String(cString: buffer)
    }

    static func sign(token: Data, key: OpaquePointer) throws -> Data {
        var signature = [UInt8](repeating: 0, count: 512)
        let length = token.withUnsafeBytes { raw in
            signature.withUnsafeMutableBufferPointer { out in
                adb_key_sign_token(key, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, out.baseAddress, out.count)
            }
        }
        guard length > 0 else { throw AdbError.keyError("firma del token fallita") }
        return Data(signature[0..<Int(length)])
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: AdbKeyStore.keyURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
    }
}
