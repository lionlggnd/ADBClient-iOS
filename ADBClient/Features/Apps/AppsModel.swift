import Foundation

struct AppPackage: Identifiable, Hashable {
    let id: String
    var apkPath: String
    var isSystem: Bool
    var isEnabled: Bool
    var isInstalled: Bool
}

enum AppFilter: String, CaseIterable, Identifiable {
    case user = "User"
    case system = "System"
    case disabled = "Disabled"
    case uninstalled = "Removed"
    case all = "All"

    var id: String { rawValue }
    // Own table: "Disabled"/"Removed" are plural here but singular on the app tags.
    var title: String { NSLocalizedString(rawValue, tableName: "Filters", comment: "") }

    func matches(_ app: AppPackage) -> Bool {
        switch self {
        case .user: return app.isInstalled && !app.isSystem
        case .system: return app.isInstalled && app.isSystem
        case .disabled: return app.isInstalled && !app.isEnabled
        case .uninstalled: return !app.isInstalled
        case .all: return true
        }
    }
}

enum AppAction: String, Identifiable {
    case launch, forceStop, disable, enable, clearData, clearCache
    case uninstall, uninstallForUser, reinstallExisting, suspend, unsuspend

    var id: String { rawValue }

    var title: String {
        switch self {
        case .launch: return String(localized: "Launch")
        case .forceStop: return String(localized: "Force stop")
        case .disable: return String(localized: "Disable")
        case .enable: return String(localized: "Enable")
        case .clearData: return String(localized: "Clear data")
        case .clearCache: return String(localized: "Clear cache")
        case .uninstall: return String(localized: "Uninstall")
        case .uninstallForUser: return String(localized: "Uninstall for user (keep APK)")
        case .reinstallExisting: return String(localized: "Restore app")
        case .suspend: return String(localized: "Suspend")
        case .unsuspend: return String(localized: "Unsuspend")
        }
    }

    var icon: String {
        switch self {
        case .launch: return "play.fill"
        case .forceStop: return "stop.fill"
        case .disable: return "nosign"
        case .enable: return "checkmark.circle"
        case .clearData: return "trash"
        case .clearCache: return "sparkles"
        case .uninstall, .uninstallForUser: return "xmark.bin"
        case .reinstallExisting: return "arrow.uturn.backward"
        case .suspend: return "pause.circle"
        case .unsuspend: return "playpause"
        }
    }

    var isDestructive: Bool {
        [.clearData, .uninstall, .uninstallForUser, .disable].contains(self)
    }

    func command(for package: String) -> String {
        let p = package.shellQuoted
        switch self {
        case .launch: return "monkey -p \(p) -c android.intent.category.LAUNCHER 1"
        case .forceStop: return "am force-stop \(p)"
        case .disable: return "pm disable-user --user 0 \(p)"
        case .enable: return "pm enable \(p)"
        case .clearData: return "pm clear \(p)"
        case .clearCache: return "pm clear --cache-only \(p)"
        case .uninstall: return "pm uninstall \(p)"
        case .uninstallForUser: return "pm uninstall -k --user 0 \(p)"
        case .reinstallExisting: return "cmd package install-existing \(p)"
        case .suspend: return "pm suspend \(p)"
        case .unsuspend: return "pm unsuspend \(p)"
        }
    }

    static func available(for app: AppPackage) -> [AppAction] {
        guard app.isInstalled else { return [.reinstallExisting] }
        var actions: [AppAction] = [.launch, .forceStop, app.isEnabled ? .disable : .enable,
                                    .clearCache, .clearData, .suspend, .unsuspend]
        actions.append(contentsOf: app.isSystem ? [.uninstallForUser] : [.uninstall, .uninstallForUser])
        return actions
    }
}

struct AppDetails {
    struct Permission: Identifiable, Hashable {
        var id: String { name }
        let name: String
        var granted: Bool
    }

    struct Field: Identifiable, Hashable {
        var id: String { label }
        let label: String
        let value: String
    }

    var fields: [Field] = []
    var permissions: [Permission] = []

    static func parse(_ dump: String) -> AppDetails {
        let wanted: [(key: String, label: String)] = [
            ("versionName=", "Version"), ("versionCode=", "Version code"), ("minSdk=", "Min SDK"),
            ("targetSdk=", "Target SDK"), ("firstInstallTime=", "First installed"),
            ("lastUpdateTime=", "Last updated"), ("installerPackageName=", "Installed by"),
            ("dataDir=", "Data folder"), ("codePath=", "APK path"),
        ]
        var values: [String: String] = [:]
        var permissions: [Permission] = []
        var inRuntimePermissions = false

        for rawLine in dump.components(separatedBy: "\n") {
            let line = rawLine.trimmed
            if line == "runtime permissions:" {
                inRuntimePermissions = true
                continue
            }
            if inRuntimePermissions {
                if let range = line.range(of: ": granted=") {
                    let name = String(line[..<range.lowerBound])
                    let granted = line[range.upperBound...].hasPrefix("true")
                    if !permissions.contains(where: { $0.name == name }) {
                        permissions.append(Permission(name: name, granted: granted))
                    }
                    continue
                }
                inRuntimePermissions = false
            }
            for (key, _) in wanted where values[key] == nil {
                if line.hasPrefix(key) && (key.hasSuffix("Time=") || key.hasSuffix("Path=") || key == "dataDir=") {
                    values[key] = String(line.dropFirst(key.count))
                } else if let range = line.range(of: key), range.lowerBound == line.startIndex || line[line.index(before: range.lowerBound)] == " " {
                    values[key] = String(line[range.upperBound...].prefix { $0 != " " })
                }
            }
        }

        var details = AppDetails()
        details.fields = wanted.compactMap { item in values[item.key].map { Field(label: NSLocalizedString(item.label, comment: ""), value: $0) } }
        details.permissions = permissions.sorted { $0.name < $1.name }
        return details
    }
}

@MainActor
final class AppsModel: ObservableObject {
    @Published var packages: [AppPackage] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var notice: String?
    private var loadedFor: String?

    func loadIfNeeded(_ manager: DeviceManager) async {
        guard loadedFor != manager.endpoint else { return }
        await load(manager)
    }

    func load(_ manager: DeviceManager) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let output = try await manager.shell(
                "pm list packages -f 2>/dev/null; echo '<<SEP>>'; pm list packages -d 2>/dev/null; echo '<<SEP>>'; " +
                "pm list packages -3 2>/dev/null; echo '<<SEP>>'; pm list packages -u 2>/dev/null")
            packages = Self.parse(output)
            loadedFor = manager.endpoint
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func parse(_ output: String) -> [AppPackage] {
        let sections = output.components(separatedBy: "<<SEP>>")
        func entries(_ index: Int) -> [String] {
            guard index < sections.count else { return [] }
            return sections[index].split(whereSeparator: \.isNewline).compactMap { line in
                let text = String(line).trimmed
                return text.hasPrefix("package:") ? String(text.dropFirst("package:".count)) : nil
            }
        }
        let disabled = Set(entries(1))
        let thirdParty = Set(entries(2))
        var result: [String: AppPackage] = [:]

        for entry in entries(0) {
            guard let eq = entry.lastIndex(of: "=") else { continue }
            let name = String(entry[entry.index(after: eq)...])
            result[name] = AppPackage(id: name, apkPath: String(entry[..<eq]), isSystem: !thirdParty.contains(name),
                                      isEnabled: !disabled.contains(name), isInstalled: true)
        }
        for name in entries(3) where result[name] == nil {
            result[name] = AppPackage(id: name, apkPath: "", isSystem: true, isEnabled: !disabled.contains(name),
                                      isInstalled: false)
        }
        return result.values.sorted { $0.id < $1.id }
    }

    /// Runs an action and returns the command output to show to the user.
    func perform(_ action: AppAction, on app: AppPackage, manager: DeviceManager) async -> String {
        do {
            let output = try await manager.shell(action.command(for: app.id)).trimmed
            if action == .clearCache && !output.contains("Success") {
                return String(localized:
                    "This device does not support clearing the cache of a single app (requires Android 14+).\nUse \"Trim cache of all apps\" from the menu instead.\n\n\(output)")
            }
            if [.disable, .enable, .uninstall, .uninstallForUser, .reinstallExisting].contains(action) {
                await load(manager)
            }
            return output.isEmpty ? String(localized: "Done.") : output
        } catch {
            return error.localizedDescription
        }
    }

    func trimAllCaches(manager: DeviceManager) async {
        do {
            let output = try await manager.shell("pm trim-caches 999G").trimmed
            notice = output.isEmpty ? String(localized: "Cache of all apps trimmed.") : output
        } catch {
            self.error = error.localizedDescription
        }
    }

    func details(for app: AppPackage, manager: DeviceManager) async throws -> AppDetails {
        AppDetails.parse(try await manager.shell("dumpsys package \(app.id.shellQuoted)"))
    }

    func setPermission(_ permission: String, granted: Bool, app: AppPackage, manager: DeviceManager) async throws -> String {
        let verb = granted ? "grant" : "revoke"
        return try await manager.shell("pm \(verb) \(app.id.shellQuoted) \(permission.shellQuoted)").trimmed
    }

    /// Pulls base and split APKs into Documents/APK/<package>.
    func extractAPKs(of app: AppPackage, manager: DeviceManager) async throws -> [URL] {
        let output = try await manager.shell("pm path \(app.id.shellQuoted)")
        let paths = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let text = String(line).trimmed
            return text.hasPrefix("package:") ? String(text.dropFirst("package:".count)) : nil
        }
        guard !paths.isEmpty else { throw AdbError.commandFailed(String(localized: "APK path not found.")) }
        let folder = LocalFiles.directory("APK").appendingPathComponent(app.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let single = paths.count == 1
        let packageName = app.id
        return try await manager.sync { client in
            try paths.map { remote in
                let name = single ? "\(packageName).apk" : (remote as NSString).lastPathComponent
                let destination = folder.appendingPathComponent(name)
                try client.pull(remote, to: destination)
                return destination
            }
        }
    }
}
