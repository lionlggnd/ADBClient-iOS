import Foundation

/// Installs one APK (`pm install`) or a set of split APKs (`pm install-create/write/commit`).
enum PackageInstaller {
    static func install(connection: AdbConnection, files: [URL], flags: String,
                        progress: @escaping (String) -> Void) throws -> String {
        guard !files.isEmpty else { throw AdbError.invalidArgument(String(localized: "No APK selected.")) }
        var remotePaths: [String] = []
        defer {
            if !remotePaths.isEmpty {
                _ = try? connection.shell("rm -f " + remotePaths.map(\.shellQuoted).joined(separator: " "))
            }
        }

        let sync = try SyncClient(connection: connection)
        do {
            for (index, file) in files.enumerated() {
                let remote = "/data/local/tmp/adbclient-\(UUID().uuidString.prefix(8))-\(index).apk"
                remotePaths.append(remote)
                let name = file.lastPathComponent
                try sync.push(from: file, to: remote) { sent, total in
                    let percent = total > 0 ? Int(sent * 100 / total) : 0
                    progress(String(localized: "Sending \(name): \(percent)%"))
                }
            }
            sync.close()
        } catch {
            sync.close()
            throw error
        }

        progress(String(localized: "Installing…"))
        if remotePaths.count == 1 {
            return try check(connection.shell("pm install \(flags) \(remotePaths[0].shellQuoted)"))
        }

        let created = try connection.shell("pm install-create \(flags)")
        guard let session = sessionId(in: created) else { throw AdbError.commandFailed(created.trimmed) }
        for (index, path) in remotePaths.enumerated() {
            let output = try connection.shell("pm install-write \(session) split_\(index).apk \(path.shellQuoted)")
            if !output.contains("Success") {
                _ = try? connection.shell("pm install-abandon \(session)")
                throw AdbError.commandFailed(output.trimmed)
            }
        }
        return try check(connection.shell("pm install-commit \(session)"))
    }

    private static func check(_ output: String) throws -> String {
        guard output.contains("Success") else { throw AdbError.commandFailed(output.trimmed) }
        return output.trimmed
    }

    private static func sessionId(in output: String) -> String? {
        guard let open = output.firstIndex(of: "["), let close = output[open...].firstIndex(of: "]") else { return nil }
        let id = output[output.index(after: open)..<close]
        return id.allSatisfy(\.isNumber) && !id.isEmpty ? String(id) : nil
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
