import Foundation

/// Incremental UTF-8 decoder that never splits multi-byte characters across chunks.
final class UTF8StreamDecoder {
    private var pending: [UInt8] = []

    func decode(_ data: Data) -> String {
        var bytes = pending + [UInt8](data)
        var cut = bytes.count
        var index = bytes.count - 1
        var continuation = 0
        while index >= 0 && continuation < 4 {
            let byte = bytes[index]
            if byte & 0xC0 == 0x80 {
                continuation += 1
                index -= 1
                continue
            }
            if byte >= 0xC0 {
                let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
                if bytes.count - index < needed { cut = index }
            }
            break
        }
        pending = Array(bytes[cut...])
        bytes.removeSubrange(cut...)
        return String(decoding: bytes, as: UTF8.self)
    }
}

enum TerminalSanitizer {
    private static let escapes = try! NSRegularExpression(
        pattern: "\u{1B}(\\[[0-9;?]*[ -/]*[@-~]|\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|[()][A-Za-z0-9]|[=>78NOcDEHMZ])")

    /// Removes ANSI escape sequences and carriage returns from PTY output.
    static func clean(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let stripped = escapes.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return stripped.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "")
    }
}

/// The "platform-tools" console: interprets `adb …` commands and hosts the interactive shell.
@MainActor
final class TerminalModel: ObservableObject {
    @Published private(set) var text = String(localized:
        "ADB Client for iOS — type 'help' for the list of commands.\nLocal files for push/pull/install are in the app's Documents folder (Files app > ADB Client).\n\n")
    @Published var input = ""
    @Published private(set) var isRunning = false
    @Published private(set) var isInteractive = false

    private let manager: DeviceManager
    private var activeStream: AdbStream?
    private let inputQueue = DispatchQueue(label: "terminal.input")
    private var history: [String] = []
    private var historyIndex = 0
    private static let maxLength = 200_000

    init(manager: DeviceManager) {
        self.manager = manager
    }

    // MARK: Output

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        if chunk.contains("\u{8}") {
            for character in chunk {
                if character == "\u{8}" {
                    if !text.isEmpty && text.last != "\n" { text.removeLast() }
                } else {
                    text.append(character)
                }
            }
        } else {
            text += chunk
        }
        if text.utf8.count > Self.maxLength * 5 / 4 {
            text = String(text.suffix(Self.maxLength))
        }
    }

    private func println(_ line: String) {
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        append(line + "\n")
    }

    func clear() {
        text = ""
    }

    // MARK: Input

    func submit() {
        let line = input
        input = ""
        if isInteractive {
            sendRaw(line + "\n")
            return
        }
        let trimmed = line.trimmed
        guard !trimmed.isEmpty, !isRunning else { return }
        if history.last != trimmed { history.append(trimmed) }
        historyIndex = history.count
        println("> " + trimmed)
        Task { await execute(trimmed) }
    }

    func sendRaw(_ string: String) {
        guard let stream = activeStream else { return }
        let data = Data(string.utf8)
        inputQueue.async { try? stream.write(data) }
    }

    /// Sends the text typed so far followed by a control sequence (Tab, Ctrl-C, arrows…).
    func sendKey(_ sequence: String) {
        let typed = input
        input = ""
        sendRaw(typed + sequence)
    }

    func historyPrevious() {
        guard !history.isEmpty, historyIndex > 0 else { return }
        historyIndex -= 1
        input = history[historyIndex]
    }

    func historyNext() {
        guard historyIndex < history.count else { return }
        historyIndex += 1
        input = historyIndex < history.count ? history[historyIndex] : ""
    }

    func cancel() {
        guard let stream = activeStream else { return }
        inputQueue.async { stream.close() }
    }

    // MARK: Commands

    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        var escaping = false
        for character in line {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" && quote != "'" {
                escaping = true
                hasToken = true
                continue
            }
            if let q = quote {
                if character == q { quote = nil } else { current.append(character) }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                hasToken = true
                continue
            }
            if character == " " || character == "\t" {
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
                continue
            }
            current.append(character)
            hasToken = true
        }
        if hasToken { tokens.append(current) }
        return tokens
    }

    private func execute(_ line: String) async {
        var args = Self.tokenize(line)
        if args.first == "adb" { args.removeFirst() }
        // Global options of the real adb (-s, -t, -d, -e) are accepted and ignored: one device at a time.
        while let first = args.first, ["-s", "-t", "-d", "-e", "-a"].contains(first) {
            args.removeFirst()
            if (first == "-s" || first == "-t") && !args.isEmpty { args.removeFirst() }
        }
        guard let command = args.first else { return }
        let rest = Array(args.dropFirst())

        isRunning = true
        defer { isRunning = false }
        do {
            try await dispatch(command, rest)
        } catch {
            println(String(localized: "adb: error: \(error.localizedDescription)"))
        }
    }

    private func requireConnection() throws -> AdbConnection {
        guard let connection = manager.connection else {
            throw AdbError.invalidArgument(String(localized: "no device connected (use 'adb connect <ip>:<port>')"))
        }
        return connection
    }

    private func dispatch(_ command: String, _ args: [String]) async throws {
        switch command {
        case "help", "--help", "-h":
            println(NSLocalizedString(Self.helpText, comment: ""))
        case "clear", "cls":
            clear()
        case "version", "--version":
            println("Android Debug Bridge client for iOS 1.0\nProtocol 0x01000001, max payload \(AdbMessage.maxPayload)")
        case "devices":
            devices(long: args.contains("-l"))
        case "connect":
            try await connect(args)
        case "disconnect":
            if manager.connection == nil {
                println(String(localized: "no device connected"))
            } else {
                let endpoint = manager.endpoint
                manager.disconnect()
                println(String(localized: "disconnected \(endpoint)"))
            }
        case "pair":
            try await pair(args)
        case "shell":
            let connection = try requireConnection()
            if args.isEmpty || args == ["-t"] {
                try await interactiveShell(connection)
            } else {
                let commandArgs = args.first == "-T" || args.first == "-t" || args.first == "-x" ? Array(args.dropFirst()) : args
                try await stream(connection, "shell:" + commandArgs.joined(separator: " "))
            }
        case "exec-out":
            try await stream(requireConnection(), "exec:" + args.joined(separator: " "))
        case "logcat":
            try await stream(requireConnection(), "shell:logcat " + args.map(\.shellQuoted).joined(separator: " "))
        case "install", "install-multiple":
            try await install(args)
        case "uninstall":
            let keep = args.contains("-k")
            let packages = args.filter { $0 != "-k" }
            guard !packages.isEmpty else { throw AdbError.invalidArgument(String(localized: "usage: uninstall [-k] <package>")) }
            for package in packages {
                println(try await manager.shell("pm uninstall \(keep ? "-k " : "")\(package.shellQuoted)").trimmed)
            }
        case "push":
            try await push(args)
        case "pull":
            try await pull(args)
        case "reboot":
            try await service("reboot:" + (args.first ?? ""))
        case "root", "unroot", "remount", "usb", "disable-verity", "enable-verity":
            try await service(command + ":")
        case "tcpip":
            guard let port = args.first, Int(port) != nil else { throw AdbError.invalidArgument(String(localized: "usage: tcpip <port>")) }
            try await service("tcpip:" + port)
        case "get-state":
            println(manager.connection == nil ? "error: no devices/emulators found" : "device")
        case "get-serialno":
            _ = try requireConnection()
            println(manager.info.serial.isEmpty ? manager.endpoint : manager.info.serial)
        case "get-devpath":
            _ = try requireConnection()
            println(manager.endpoint)
        case "features":
            println(try requireConnection().features.sorted().joined(separator: "\n"))
        case "ls-local", "lls":
            listLocal()
        case "wait-for-device":
            _ = try requireConnection()
        case "start-server", "kill-server", "reconnect":
            println(String(localized: "Not needed on iOS: the app talks directly to adbd, without a local server."))
        case "forward", "reverse", "sideload", "backup", "restore", "emu", "sync", "bugreport", "keygen", "mdns", "jdwp":
            println(String(localized: "adb: the '\(command)' command is not supported by this client."))
        default:
            println(String(localized: "adb: unknown command '\(command)'. Type 'help'."))
        }
    }

    // MARK: Command implementations

    private func devices(long: Bool) {
        println("List of devices attached")
        if let connection = manager.connection {
            var line = "\(connection.host):\(connection.port)\tdevice"
            if long {
                let p = connection.bannerProperties
                line += " product:\(p["ro.product.name"] ?? "?") model:\(p["ro.product.model"] ?? "?")" +
                    " device:\(p["ro.product.device"] ?? "?")\(connection.usesTLS ? " tls" : "")"
            }
            println(line)
        }
    }

    private static func parseEndpoint(_ value: String, defaultPort: Int?) throws -> (String, Int) {
        if let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) {
            return (String(value[..<colon]), port)
        }
        guard let defaultPort else { throw AdbError.invalidArgument(String(localized: "specify the port: <ip>:<port>")) }
        return (value, defaultPort)
    }

    private func connect(_ args: [String]) async throws {
        guard let target = args.first else { throw AdbError.invalidArgument(String(localized: "usage: connect <ip>[:port]")) }
        let (host, port) = try Self.parseEndpoint(target, defaultPort: 5555)
        println(String(localized: "connecting to \(host):\(port)…"))
        try await manager.connect(host: host, port: port)
        println(String(localized: "connected to \(host):\(port) — \(manager.info.displayName)"))
    }

    private func pair(_ args: [String]) async throws {
        guard let target = args.first, args.count >= 2 else {
            throw AdbError.invalidArgument(String(localized: "usage: pair <ip>:<port> <code>"))
        }
        let (host, port) = try Self.parseEndpoint(target, defaultPort: nil)
        let guid = try await manager.pair(host: host, port: port, code: args[1])
        println(String(localized: "Successfully paired to \(host):\(port) [guid=\(guid)]"))
        println(String(localized: "Now use 'adb connect \(host):<wireless debugging port>'."))
    }

    private func service(_ name: String) async throws {
        let output = try await manager.service(name).trimmed
        println(output.isEmpty ? "ok" : output)
    }

    /// Streams a service's output live until it ends or the user presses Stop.
    private func stream(_ connection: AdbConnection, _ service: String) async throws {
        let stream = try await runBlocking { try connection.openStream(service) }
        activeStream = stream
        defer { activeStream = nil }
        let decoder = UTF8StreamDecoder()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stream.setHandlers(onData: { data in
                let text = TerminalSanitizer.clean(decoder.decode(data))
                DispatchQueue.main.async { self.append(text) }
            }, onClose: {
                DispatchQueue.main.async { continuation.resume() }
            })
        }
        if !text.hasSuffix("\n") && !text.isEmpty { append("\n") }
    }

    private func interactiveShell(_ connection: AdbConnection) async throws {
        println(String(localized: "Interactive shell started. Type 'exit' to return to the adb console."))
        isInteractive = true
        defer {
            isInteractive = false
            println(String(localized: "[shell ended]"))
        }
        try await stream(connection, "shell:")
    }

    private func localURL(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : LocalFiles.documents.appendingPathComponent(path)
    }

    private func listLocal() {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: LocalFiles.documents.path)) ?? []
        println(items.isEmpty ? String(localized: "(Documents folder is empty)") : items.sorted().joined(separator: "\n"))
    }

    private func push(_ args: [String]) async throws {
        let paths = args.filter { !$0.hasPrefix("-") }
        guard paths.count >= 2 else { throw AdbError.invalidArgument(String(localized: "usage: push <local…> <remote>")) }
        let remote = paths.last!
        let locals = paths.dropLast().map(localURL)
        for url in locals where !FileManager.default.fileExists(atPath: url.path) {
            throw AdbError.invalidArgument(String(localized: "local file not found: \(url.lastPathComponent) (use 'lls')"))
        }
        let start = Date()
        let count = try await manager.sync { client -> Int in
            let target = try client.stat(remote)
            let remoteIsDirectory = remote.hasSuffix("/") || target?.isDirectory == true || locals.count > 1
            var total = 0
            for url in locals {
                let destination = remoteIsDirectory
                    ? (remote.hasSuffix("/") ? remote : remote + "/") + url.lastPathComponent
                    : remote
                total += try client.pushRecursive(from: url, to: destination) { name in
                    DispatchQueue.main.async { self.println("\(name) -> \(destination)") }
                }
            }
            return total
        }
        println(String(localized: "\(count) files pushed in \(String(format: "%.1f", Date().timeIntervalSince(start)))s"))
    }

    private func pull(_ args: [String]) async throws {
        let paths = args.filter { !$0.hasPrefix("-") }
        guard let remote = paths.first else { throw AdbError.invalidArgument(String(localized: "usage: pull <remote> [local]")) }
        let name = (remote as NSString).lastPathComponent
        let destination = paths.count > 1 ? localURL(paths[1]) : LocalFiles.documents.appendingPathComponent(name)
        let start = Date()
        let count = try await manager.sync { client in
            try client.pullRecursive(remote, to: destination) { file in
                DispatchQueue.main.async { self.println(String(localized: "\(file) -> Documents")) }
            }
        }
        println(String(localized: "\(count) files pulled in \(String(format: "%.1f", Date().timeIntervalSince(start)))s → \(destination.lastPathComponent)"))
    }

    private func install(_ args: [String]) async throws {
        let flags = args.filter { $0.hasPrefix("-") }.joined(separator: " ")
        let files = args.filter { !$0.hasPrefix("-") }.map(localURL)
        guard !files.isEmpty else { throw AdbError.invalidArgument(String(localized: "usage: install [-r] [-d] [-g] [-t] <file.apk…>")) }
        for url in files where !FileManager.default.fileExists(atPath: url.path) {
            throw AdbError.invalidArgument(String(localized: "file not found: \(url.lastPathComponent) (use 'lls')"))
        }
        println("Performing Streamed Install")
        let result = try await manager.install(files: files, flags: flags) { _ in }
        println(result)
    }

    static let helpText = """
    Available commands (the 'adb' prefix is optional):

     connect <ip>[:port]         connect (default port 5555)
     pair <ip>:<port> <code>     pair via Wireless debugging (Android 11+)
     disconnect                  close the connection
     devices [-l]                list the connected device
     shell                       interactive shell (type 'exit' to leave)
     shell <command>             run a command and show its output
     exec-out <command>          run a command without a PTY
     logcat [options]            live log (Stop to interrupt)
     install [-r -d -g -t] <apk> install APKs from the Documents folder
     install-multiple <apk…>     install split APKs
     uninstall [-k] <package>    uninstall
     push <local…> <remote>      send files/folders from Documents
     pull <remote> [local]       download files/folders to Documents
     lls                         list the files in Documents
     reboot [bootloader|recovery|sideload|fastboot]
     root | unroot | remount | usb | tcpip <port>
     disable-verity | enable-verity
     get-state | get-serialno | get-devpath | features | version
     clear                       clear the screen
    """
}
