import Foundation

struct DeviceInfo {
    var manufacturer = ""
    var model = ""
    var androidVersion = ""
    var sdk = ""
    var serial = ""
    var device = ""
    var battery = ""

    var displayName: String {
        let name = [manufacturer, model].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? "Dispositivo Android" : name
    }
}

struct SavedDevice: Codable, Identifiable, Hashable {
    var id: String { "\(host):\(port)" }
    var host: String
    var port: Int
    var name: String
}

/// App-wide state of the (single) active ADB connection.
@MainActor
final class DeviceManager: ObservableObject {
    enum Status: Equatable {
        case disconnected, connecting, waitingAuthorization, connected
    }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var connection: AdbConnection?
    @Published private(set) var info = DeviceInfo()
    @Published private(set) var savedDevices: [SavedDevice] = []
    @Published var connectionLostMessage: String?

    private static let savedKey = "savedDevices"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.savedKey),
           let devices = try? JSONDecoder().decode([SavedDevice].self, from: data) {
            savedDevices = devices
        }
    }

    var endpoint: String {
        guard let connection else { return "" }
        return "\(connection.host):\(connection.port)"
    }

    // MARK: Connection

    func connect(host rawHost: String, port: Int) async throws {
        let host = rawHost.trimmed
        guard !host.isEmpty else { throw AdbError.invalidArgument("Inserisci l'indirizzo IP del dispositivo.") }
        guard (1...65535).contains(port) else { throw AdbError.invalidArgument("Porta non valida.") }
        disconnect()
        status = .connecting
        do {
            let key = try AdbKeyStore.shared.key()
            let keyName = AdbKeyStore.shared.keyName
            let connection = try await runBlocking {
                try AdbConnection.connect(host: host, port: port, key: key, keyName: keyName) {
                    DispatchQueue.main.async { [weak self] in
                        if self?.status == .connecting { self?.status = .waitingAuthorization }
                    }
                }
            }
            self.connection = connection
            status = .connected
            connection.start { [weak self, weak connection] error in
                DispatchQueue.main.async {
                    guard let self, let connection, self.connection === connection else { return }
                    self.connection = nil
                    self.status = .disconnected
                    self.info = DeviceInfo()
                    if let error {
                        self.connectionLostMessage =
                            "Connessione con \(connection.host):\(connection.port) persa: \(error.localizedDescription)"
                    }
                }
            }
            await refreshInfo()
            remember(host: host, port: port)
        } catch {
            status = .disconnected
            throw error
        }
    }

    func disconnect() {
        guard let connection else { return }
        self.connection = nil
        status = .disconnected
        info = DeviceInfo()
        connection.close()
    }

    /// Pairs with a device using the 6-digit code from "Wireless debugging > Pair device with pairing code".
    func pair(host rawHost: String, port: Int, code rawCode: String) async throws -> String {
        let host = rawHost.trimmed
        let code = rawCode.trimmed
        guard !host.isEmpty, (1...65535).contains(port) else {
            throw AdbError.invalidArgument("Indirizzo o porta di accoppiamento non validi.")
        }
        guard !code.isEmpty else { throw AdbError.invalidArgument("Inserisci il codice di accoppiamento.") }
        let key = try AdbKeyStore.shared.key()
        let keyName = AdbKeyStore.shared.keyName
        return try await runBlocking {
            var peer = [CChar](repeating: 0, count: 8192)
            var error = [CChar](repeating: 0, count: 512)
            let result = peer.withUnsafeMutableBufferPointer { p in
                error.withUnsafeMutableBufferPointer { e in
                    adb_pair(host, Int32(port), code, key, keyName, p.baseAddress, p.count, e.baseAddress, e.count)
                }
            }
            guard result == 0 else { throw AdbError.pairingFailed(String(cString: error)) }
            return String(cString: peer)
        }
    }

    func refreshInfo() async {
        guard let output = try? await shell(
            "getprop ro.product.manufacturer; getprop ro.product.model; getprop ro.build.version.release; " +
            "getprop ro.build.version.sdk; getprop ro.serialno; getprop ro.product.device; " +
            "dumpsys battery 2>/dev/null | grep -m1 level") else { return }
        let lines = output.components(separatedBy: "\n").map(\.trimmed)
        func line(_ i: Int) -> String { i < lines.count ? lines[i] : "" }
        var info = DeviceInfo()
        info.manufacturer = line(0)
        info.model = line(1)
        info.androidVersion = line(2)
        info.sdk = line(3)
        info.serial = line(4)
        info.device = line(5)
        info.battery = line(6).replacingOccurrences(of: "level:", with: "").trimmed
        self.info = info
    }

    // MARK: Saved devices

    private func remember(host: String, port: Int) {
        let device = SavedDevice(host: host, port: port, name: info.displayName)
        savedDevices.removeAll { $0.id == device.id }
        savedDevices.insert(device, at: 0)
        persistSaved()
    }

    func forget(_ device: SavedDevice) {
        savedDevices.removeAll { $0.id == device.id }
        persistSaved()
    }

    private func persistSaved() {
        if let data = try? JSONEncoder().encode(savedDevices) {
            UserDefaults.standard.set(data, forKey: Self.savedKey)
        }
    }

    // MARK: Device operations

    func requireConnection() throws -> AdbConnection {
        guard let connection else { throw AdbError.notConnected }
        return connection
    }

    func shell(_ command: String) async throws -> String {
        let connection = try requireConnection()
        return try await runBlocking { try connection.shell(command) }
    }

    /// Runs a raw adbd service such as `reboot:`, `root:` or `tcpip:5555`.
    func service(_ name: String) async throws -> String {
        let connection = try requireConnection()
        return try await runBlocking { try connection.run(name) }
    }

    func sync<T>(_ body: @escaping (SyncClient) throws -> T) async throws -> T {
        let connection = try requireConnection()
        return try await runBlocking {
            let client = try SyncClient(connection: connection)
            defer { client.close() }
            return try body(client)
        }
    }

    func install(files: [URL], flags: String, progress: @escaping (String) -> Void) async throws -> String {
        let connection = try requireConnection()
        let report: (String) -> Void = { message in DispatchQueue.main.async { progress(message) } }
        return try await runBlocking {
            try PackageInstaller.install(connection: connection, files: files, flags: flags, progress: report)
        }
    }
}

enum LocalFiles {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func directory(_ name: String) -> URL {
        let url = documents.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Copies files picked from the Files app (security-scoped) into a temporary folder.
    static func importCopies(of urls: [URL]) throws -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try urls.map { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let destination = dir.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        }
    }
}
