import Foundation

/// Byte transport to adbd: plain TCP, optionally upgraded to TLS (wireless debugging).
final class AdbTransport {
    private let fd: Int32
    private var tls: OpaquePointer?
    private var isClosed = false
    private let writeLock = NSLock()

    init(fd: Int32) {
        self.fd = fd
    }

    func setReadTimeout(ms: Int) {
        _ = adb_fd_set_timeout(fd, Int32(ms))
    }

    func startTLS(key: OpaquePointer) throws {
        let fd = self.fd
        let (handle, message) = withErrorBuffer { adb_tls_handshake(fd, key, $0, $1) }
        guard let handle else { throw AdbError.connectionFailed(message) }
        tls = handle
    }

    func readFully(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let n: Int32 = buffer.withUnsafeMutableBufferPointer { p in
                let ptr = p.baseAddress! + received
                if let tls { return adb_tls_read(tls, ptr, count - received) }
                return adb_fd_read(fd, ptr, count - received)
            }
            if n <= 0 { throw AdbError.closed }
            received += Int(n)
        }
        return Data(buffer)
    }

    func write(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        if isClosed { throw AdbError.closed }
        let result: Int32 = data.withUnsafeBytes { raw in
            guard let ptr = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            if let tls { return adb_tls_write_all(tls, ptr, raw.count) }
            return adb_fd_write_all(fd, ptr, raw.count)
        }
        if result != 0 { throw AdbError.closed }
    }

    func readMessage() throws -> AdbMessage {
        let header = try readFully(AdbMessage.headerSize)
        let command = header.readLE32(at: 0)
        let length = Int(header.readLE32(at: 12))
        guard header.readLE32(at: 20) == command ^ 0xffff_ffff else {
            throw AdbError.protocolError("intestazione non valida")
        }
        guard length <= 16 * 1024 * 1024 else { throw AdbError.protocolError("pacchetto troppo grande") }
        let payload = try readFully(length)
        return AdbMessage(command, header.readLE32(at: 4), header.readLE32(at: 8), payload)
    }

    func writeMessage(_ message: AdbMessage) throws {
        try write(message.encoded())
    }

    /// Unblocks any pending read/write; the reader then calls `finalClose`.
    func shutdown() {
        adb_fd_shutdown(fd)
    }

    func finalClose() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        if let tls { adb_tls_free(tls) }
        tls = nil
        adb_fd_close(fd)
    }
}

/// An authenticated ADB session multiplexing many streams over one transport.
final class AdbConnection {
    static let clientBanner = "host::features=cmd,stat_v2,ls_v2,fixed_push_mkdir,fixed_push_symlink_timestamp,abb_exec"

    let host: String
    let port: Int
    private let transport: AdbTransport
    private(set) var maxPayload = 4096
    private(set) var banner = ""
    private(set) var bannerProperties: [String: String] = [:]
    private(set) var features: Set<String> = []
    private(set) var usesTLS = false

    private let lock = NSLock()
    private var streams: [UInt32: AdbStream] = [:]
    private var nextLocalId: UInt32 = 1
    private var isClosed = false
    private var onClose: ((Error?) -> Void)?

    private init(host: String, port: Int, transport: AdbTransport) {
        self.host = host
        self.port = port
        self.transport = transport
    }

    /// Connects and authenticates (blocking). `onAuthRequired` fires when the user must
    /// confirm the "Allow USB debugging?" prompt on the device.
    static func connect(host: String, port: Int, key: OpaquePointer, keyName: String,
                        onAuthRequired: @escaping () -> Void) throws -> AdbConnection {
        let (fd, message) = withErrorBuffer { adb_tcp_connect(host, Int32(port), 8000, $0, $1) }
        guard fd >= 0 else { throw AdbError.connectionFailed(message) }
        let transport = AdbTransport(fd: fd)

        do {
            transport.setReadTimeout(ms: 15000)
            try transport.writeMessage(AdbMessage(AdbMessage.cnxn, AdbMessage.protocolVersion,
                                                  AdbMessage.maxPayload, .cString(clientBanner)))
            var sentSignature = false
            var sentPublicKey = false
            var tls = false

            while true {
                let message = try transport.readMessage()
                switch message.command {
                case AdbMessage.stls:
                    try transport.writeMessage(AdbMessage(AdbMessage.stls, AdbMessage.stlsVersion, 0))
                    try transport.startTLS(key: key)
                    tls = true

                case AdbMessage.auth:
                    guard message.arg0 == AdbMessage.authToken else {
                        throw AdbError.protocolError("richiesta AUTH inattesa")
                    }
                    if !sentSignature {
                        sentSignature = true
                        let signature = try AdbKeyStore.sign(token: message.payload, key: key)
                        try transport.writeMessage(AdbMessage(AdbMessage.auth, AdbMessage.authSignature, 0, signature))
                    } else if !sentPublicKey {
                        sentPublicKey = true
                        let publicKey = try AdbKeyStore.publicKeyString(key: key, name: keyName)
                        try transport.writeMessage(AdbMessage(AdbMessage.auth, AdbMessage.authRSAPublicKey, 0,
                                                              .cString(publicKey)))
                        transport.setReadTimeout(ms: 120_000)
                        onAuthRequired()
                    } else {
                        throw AdbError.authRejected
                    }

                case AdbMessage.cnxn:
                    transport.setReadTimeout(ms: 0)
                    let connection = AdbConnection(host: host, port: port, transport: transport)
                    connection.maxPayload = max(1024, min(Int(message.arg1), Int(AdbMessage.maxPayload)))
                    connection.usesTLS = tls
                    connection.parseBanner(String(decoding: message.payload, as: UTF8.self))
                    return connection

                default:
                    continue
                }
            }
        } catch {
            transport.finalClose()
            if let adbError = error as? AdbError, case .closed = adbError {
                throw AdbError.connectionFailed(
                    "Il dispositivo ha chiuso la connessione o non ha risposto in tempo. " +
                    "Verifica che il debug sia attivo e, se richiesto, autorizza questo client sul dispositivo.")
            }
            throw error
        }
    }

    /// Starts the reader thread. `onClose` receives nil when closed by `close()`.
    func start(onClose: @escaping (Error?) -> Void) {
        self.onClose = onClose
        let thread = Thread { [self] in self.readLoop() }
        thread.name = "adb-reader-\(host):\(port)"
        thread.start()
    }

    private func parseBanner(_ raw: String) {
        banner = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        guard let range = banner.range(of: "::") else { return }
        for item in banner[range.upperBound...].split(separator: ";") {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            bannerProperties[parts[0]] = parts[1]
            if parts[0] == "features" {
                features = Set(parts[1].split(separator: ",").map(String.init))
            }
        }
    }

    private func readLoop() {
        var failure: Error?
        while true {
            do {
                handle(try transport.readMessage())
            } catch {
                failure = error
                break
            }
        }
        lock.lock()
        let closedByUser = isClosed
        isClosed = true
        let open = Array(streams.values)
        streams.removeAll()
        lock.unlock()

        open.forEach { $0.remoteClosed() }
        transport.finalClose()
        onClose?(closedByUser ? nil : failure)
    }

    private func stream(_ id: UInt32) -> AdbStream? {
        lock.lock()
        defer { lock.unlock() }
        return streams[id]
    }

    private func handle(_ message: AdbMessage) {
        switch message.command {
        case AdbMessage.okay:
            stream(message.arg1)?.didReceiveOkay(remoteId: message.arg0)
        case AdbMessage.wrte:
            if let s = stream(message.arg1) {
                s.didReceive(message.payload)
                try? transport.writeMessage(AdbMessage(AdbMessage.okay, message.arg1, message.arg0))
            } else {
                try? transport.writeMessage(AdbMessage(AdbMessage.clse, message.arg1, message.arg0))
            }
        case AdbMessage.clse:
            lock.lock()
            let s = streams.removeValue(forKey: message.arg1)
            lock.unlock()
            s?.remoteClosed()
        default:
            break
        }
    }

    // MARK: Streams

    func openStream(_ service: String, timeout: TimeInterval = 15) throws -> AdbStream {
        lock.lock()
        if isClosed {
            lock.unlock()
            throw AdbError.notConnected
        }
        let id = nextLocalId
        nextLocalId &+= 1
        let stream = AdbStream(localId: id, connection: self)
        streams[id] = stream
        lock.unlock()

        do {
            try transport.writeMessage(AdbMessage(AdbMessage.open, id, 0, .cString(service)))
            try stream.waitForOpen(service: service, timeout: timeout)
        } catch {
            closeStream(stream)
            throw error
        }
        return stream
    }

    func send(_ message: AdbMessage) throws {
        try transport.writeMessage(message)
    }

    func closeStream(_ stream: AdbStream) {
        lock.lock()
        let registered = streams.removeValue(forKey: stream.localId) != nil
        let closed = isClosed
        lock.unlock()
        if registered && !closed && stream.remoteId != 0 {
            try? send(AdbMessage(AdbMessage.clse, stream.localId, stream.remoteId))
        }
    }

    func close() {
        lock.lock()
        isClosed = true
        lock.unlock()
        transport.shutdown()
    }

    // MARK: Convenience

    /// Runs a service to completion and returns its output as text.
    func run(_ service: String) throws -> String {
        let stream = try openStream(service)
        defer { stream.close() }
        return String(decoding: try stream.readAll(), as: UTF8.self)
    }

    func shell(_ command: String) throws -> String {
        try run("shell:" + command)
    }
}
