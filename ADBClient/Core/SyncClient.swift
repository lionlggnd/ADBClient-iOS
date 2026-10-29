import Foundation

/// File transfer over the `sync:` service (adb push / pull / ls).
final class SyncClient {
    struct Entry: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let mode: UInt32
        let size: UInt32
        let mtime: UInt32

        var isDirectory: Bool { mode & 0o170000 == 0o040000 }
        var isSymlink: Bool { mode & 0o170000 == 0o120000 }
        var isFile: Bool { mode & 0o170000 == 0o100000 }
        var modified: Date { Date(timeIntervalSince1970: TimeInterval(mtime)) }

        var permissions: String {
            let kind = isDirectory ? "d" : isSymlink ? "l" : "-"
            let chars = Array("rwxrwxrwx")
            let bits = (0..<9).map { mode & (1 << (8 - UInt32($0))) != 0 ? String(chars[$0]) : "-" }
            return kind + bits.joined()
        }
    }

    private static let chunkSize = 64 * 1024
    private let stream: AdbStream

    init(connection: AdbConnection) throws {
        stream = try connection.openStream("sync:")
    }

    func close() {
        var quit = Data("QUIT".utf8)
        quit.appendLE(0)
        try? stream.write(quit)
        stream.close()
    }

    private func request(_ id: String, _ payload: Data) throws {
        var data = Data(id.utf8)
        data.appendLE(UInt32(payload.count))
        data.append(payload)
        try stream.write(data)
    }

    private func readId() throws -> String {
        String(decoding: try stream.readExactly(4), as: UTF8.self)
    }

    private func readU32() throws -> UInt32 {
        try stream.readExactly(4).readLE32(at: 0)
    }

    private func readFailure() throws -> Never {
        let length = Int(try readU32())
        let message = String(decoding: try stream.readExactly(length), as: UTF8.self)
        throw AdbError.commandFailed(message)
    }

    // MARK: Operations

    func stat(_ path: String) throws -> Entry? {
        try request("STAT", Data(path.utf8))
        guard try readId() == "STAT" else { throw AdbError.protocolError("risposta STAT non valida") }
        let mode = try readU32(), size = try readU32(), mtime = try readU32()
        guard mode != 0 else { return nil }
        return Entry(name: (path as NSString).lastPathComponent, mode: mode, size: size, mtime: mtime)
    }

    func list(_ path: String) throws -> [Entry] {
        try request("LIST", Data(path.utf8))
        var entries: [Entry] = []
        while true {
            let id = try readId()
            if id == "FAIL" { try readFailure() }
            let mode = try readU32(), size = try readU32(), mtime = try readU32()
            let nameLength = Int(try readU32())
            if id == "DONE" { break }
            guard id == "DENT" else { throw AdbError.protocolError("risposta LIST non valida (\(id))") }
            let name = String(decoding: try stream.readExactly(nameLength), as: UTF8.self)
            if name != "." && name != ".." {
                entries.append(Entry(name: name, mode: mode, size: size, mtime: mtime))
            }
        }
        return entries
    }

    func push(from url: URL, to remotePath: String, mode: UInt32 = 0o644,
              progress: ((Int64, Int64) -> Void)? = nil) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0

        try request("SEND", Data("\(remotePath),\(0o100000 | mode)".utf8))
        var sent: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: SyncClient.chunkSize) ?? Data()
            if chunk.isEmpty { break }
            try request("DATA", chunk)
            sent += Int64(chunk.count)
            progress?(sent, total)
        }
        var done = Data("DONE".utf8)
        done.appendLE(UInt32(Date().timeIntervalSince1970))
        try stream.write(done)

        let id = try readId()
        if id == "FAIL" { try readFailure() }
        _ = try readU32()
        guard id == "OKAY" else { throw AdbError.protocolError("risposta SEND non valida (\(id))") }
    }

    func pull(_ remotePath: String, to url: URL, progress: ((Int64, Int64) -> Void)? = nil) throws {
        let total = Int64((try? stat(remotePath))?.size ?? 0)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        try request("RECV", Data(remotePath.utf8))
        var received: Int64 = 0
        while true {
            let id = try readId()
            switch id {
            case "DATA":
                let length = Int(try readU32())
                let chunk = try stream.readExactly(length)
                try handle.write(contentsOf: chunk)
                received += Int64(length)
                progress?(received, total)
            case "DONE":
                _ = try readU32()
                return
            case "FAIL":
                try? FileManager.default.removeItem(at: url)
                try readFailure()
            default:
                throw AdbError.protocolError("risposta RECV non valida (\(id))")
            }
        }
    }

    /// Pulls a file or a whole directory tree into `url`.
    func pullRecursive(_ remotePath: String, to url: URL, onFile: ((String) -> Void)? = nil) throws -> Int {
        if let entry = try stat(remotePath), entry.isDirectory || entry.isSymlink,
           let children = try? list(remotePath), entry.isDirectory || !children.isEmpty {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var count = 0
            for child in children {
                let childPath = remotePath.hasSuffix("/") ? remotePath + child.name : remotePath + "/" + child.name
                count += try pullRecursive(childPath, to: url.appendingPathComponent(child.name), onFile: onFile)
            }
            return count
        }
        onFile?(remotePath)
        try pull(remotePath, to: url)
        return 1
    }

    /// Pushes a local file or directory tree to `remotePath`.
    func pushRecursive(from url: URL, to remotePath: String, onFile: ((String) -> Void)? = nil) throws -> Int {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard isDirectory.boolValue else {
            onFile?(url.lastPathComponent)
            try push(from: url, to: remotePath)
            return 1
        }
        var count = 0
        let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        for child in children {
            count += try pushRecursive(from: child, to: remotePath + "/" + child.lastPathComponent, onFile: onFile)
        }
        return count
    }
}
