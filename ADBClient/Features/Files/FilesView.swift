import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class FilesModel: ObservableObject {
    @Published var path = "/sdcard"
    @Published var entries: [SyncClient.Entry] = []
    @Published var isLoading = false
    @Published var progress: String?
    @Published var error: String?

    func child(_ name: String) -> String {
        path == "/" ? "/" + name : path + "/" + name
    }

    var parent: String {
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }

    func load(_ manager: DeviceManager) async {
        isLoading = true
        defer { isLoading = false }
        let target = path
        do {
            let list = try await manager.sync { try $0.list(target) }
            entries = list.sorted { a, b in
                let aDir = a.isDirectory || a.isSymlink, bDir = b.isDirectory || b.isSymlink
                return aDir != bDir ? aDir : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        } catch {
            entries = []
            self.error = error.localizedDescription
        }
    }

    func pull(_ entry: SyncClient.Entry, manager: DeviceManager) async -> URL? {
        let remote = child(entry.name)
        let destination = LocalFiles.directory("Pull").appendingPathComponent(entry.name)
        try? FileManager.default.removeItem(at: destination)
        do {
            let name = entry.name
            try await manager.sync { client in
                if entry.isDirectory {
                    _ = try client.pullRecursive(remote, to: destination) { file in
                        DispatchQueue.main.async { self.progress = String(localized: "Downloading \((file as NSString).lastPathComponent)…") }
                    }
                } else {
                    try client.pull(remote, to: destination) { done, total in
                        DispatchQueue.main.async { self.progress = Self.describe(name, done, total) }
                    }
                }
            }
            progress = nil
            return destination
        } catch {
            progress = nil
            self.error = error.localizedDescription
            return nil
        }
    }

    func upload(_ urls: [URL], manager: DeviceManager) async {
        let directory = path
        do {
            let copies = try LocalFiles.importCopies(of: urls)
            defer { copies.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }
            try await manager.sync { client in
                for url in copies {
                    let name = url.lastPathComponent
                    let remote = directory == "/" ? "/" + name : directory + "/" + name
                    try client.push(from: url, to: remote) { done, total in
                        DispatchQueue.main.async { self.progress = Self.describe(name, done, total) }
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
        progress = nil
        await load(manager)
    }

    func shellAction(_ command: String, manager: DeviceManager) async {
        do {
            let output = try await manager.shell(command + " 2>&1").trimmed
            if !output.isEmpty { error = output }
        } catch {
            self.error = error.localizedDescription
        }
        await load(manager)
    }

    nonisolated static func describe(_ name: String, _ done: Int64, _ total: Int64) -> String {
        total > 0 ? "\(name): \(done.byteString) / \(total.byteString)" : "\(name): \(done.byteString)"
    }
}

struct FilesView: View {
    @EnvironmentObject private var manager: DeviceManager
    @StateObject private var model = FilesModel()
    @State private var showImporter = false
    @State private var shared: SharedFiles?
    @State private var newFolder = false
    @State private var goTo = false
    @State private var nameInput = ""
    @State private var renaming: SyncClient.Entry?
    @State private var deleting: SyncClient.Entry?
    @State private var installResult: String?

    var body: some View {
        NavigationStack {
            Group {
                if manager.connection == nil {
                    NotConnectedView()
                } else {
                    browser
                }
            }
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: $showImporter) {
                DocumentPicker { urls in Task { await model.upload(urls, manager: manager) } }
                    .ignoresSafeArea()
            }
            .sheet(item: $shared) { ShareSheet(items: $0.urls) }
            .alert("New folder", isPresented: $newFolder) {
                TextField("Name", text: $nameInput).textInputAutocapitalization(.never)
                Button("Create") { run("mkdir -p \(model.child(nameInput).shellQuoted)") }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Go to path", isPresented: $goTo) {
                TextField("/sdcard/Download", text: $nameInput).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Open") { navigate(nameInput.trimmed) }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("New name", text: $nameInput).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Rename") {
                    if let entry = renaming {
                        run("mv \(model.child(entry.name).shellQuoted) \(model.child(nameInput).shellQuoted)")
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete \(deleting?.name ?? "")?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let entry = deleting { run("rm -rf \(model.child(entry.name).shellQuoted)") }
                }
            }
            .task(id: manager.endpoint) {
                if manager.connection != nil { await model.load(manager) }
            }
            .errorAlert($model.error)
            .infoAlert("Installation", message: $installResult)
        }
    }

    private var browser: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "folder")
                    Text(model.path).font(.footnote.monospaced()).lineLimit(2).textSelection(.enabled)
                }
                if model.path != "/" {
                    Button { navigate(model.parent) } label: { Label("..", systemImage: "arrow.turn.left.up") }
                }
                if let progress = model.progress {
                    HStack { ProgressView(); Text(progress).font(.footnote) }
                }
            }
            Section {
                ForEach(model.entries) { entry in
                    row(entry)
                }
                if model.isLoading && model.entries.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if model.entries.isEmpty {
                    Text("Empty or inaccessible folder.").foregroundStyle(.secondary)
                }
            }
        }
        .refreshable { await model.load(manager) }
    }

    @ViewBuilder
    private func row(_ entry: SyncClient.Entry) -> some View {
        let isFolder = entry.isDirectory || entry.isSymlink
        Button {
            if isFolder { navigate(model.child(entry.name)) } else { download(entry) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.isDirectory ? "folder.fill" : entry.isSymlink ? "link" : "doc")
                    .foregroundStyle(isFolder ? Color.accentColor : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).foregroundStyle(.primary).lineLimit(1)
                    Text("\(entry.permissions)  \(entry.isDirectory ? "" : Int64(entry.size).byteString)  " +
                         entry.modified.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contextMenu {
            Button { download(entry) } label: { Label("Download and share", systemImage: "square.and.arrow.down") }
            if entry.name.lowercased().hasSuffix(".apk") {
                Button { install(entry) } label: { Label("Install APK", systemImage: "shippingbox") }
            }
            Button {
                nameInput = entry.name
                renaming = entry
            } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { deleting = entry } label: { Label("Delete", systemImage: "trash") }
        }
        .swipeActions {
            Button(role: .destructive) { deleting = entry } label: { Label("Delete", systemImage: "trash") }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            if manager.connection != nil {
                Menu {
                    Button { showImporter = true } label: { Label("Upload files here", systemImage: "square.and.arrow.up") }
                    Button {
                        nameInput = ""
                        newFolder = true
                    } label: { Label("New folder", systemImage: "folder.badge.plus") }
                    Button {
                        nameInput = model.path
                        goTo = true
                    } label: { Label("Go to path…", systemImage: "arrow.right.circle") }
                    Divider()
                    ForEach(["/sdcard", "/sdcard/Download", "/data/local/tmp", "/"], id: \.self) { p in
                        Button(p) { navigate(p) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private func navigate(_ path: String) {
        guard !path.isEmpty else { return }
        model.path = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        Task { await model.load(manager) }
    }

    private func run(_ command: String) {
        Task { await model.shellAction(command, manager: manager) }
    }

    private func download(_ entry: SyncClient.Entry) {
        Task {
            if let url = await model.pull(entry, manager: manager) { shared = SharedFiles(urls: [url]) }
        }
    }

    private func install(_ entry: SyncClient.Entry) {
        Task {
            do {
                installResult = try await manager.shell("pm install -r -t \(model.child(entry.name).shellQuoted)").trimmed
            } catch {
                model.error = error.localizedDescription
            }
        }
    }
}
