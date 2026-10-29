import SwiftUI
import UniformTypeIdentifiers

struct AppsView: View {
    @EnvironmentObject private var manager: DeviceManager
    @StateObject private var model = AppsModel()
    @State private var filter = AppFilter.user
    @State private var search = ""
    @State private var showImporter = false
    @State private var picked: [URL]?
    @State private var pendingInstall: [URL] = []
    @State private var actionResult: String?

    private var visible: [AppPackage] {
        model.packages.filter { app in
            filter.matches(app) && (search.isEmpty || app.id.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if manager.connection == nil {
                    NotConnectedView()
                } else {
                    list
                }
            }
            .navigationTitle("Apps")
            .toolbar {
                if manager.connection != nil {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button { showImporter = true } label: { Label("Install APK…", systemImage: "square.and.arrow.down") }
                            Button { Task { await model.load(manager) } } label: { Label("Refresh list", systemImage: "arrow.clockwise") }
                            Button { Task { await model.trimAllCaches(manager: manager) } } label: {
                                Label("Trim cache of all apps", systemImage: "sparkles")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .sheet(isPresented: $showImporter, onDismiss: {
                // Present the install sheet only once the picker is fully gone.
                guard let urls = picked else { return }
                picked = nil
                let apks = urls.filter { $0.pathExtension.lowercased() == "apk" }
                if apks.isEmpty {
                    model.error = String(localized: "Select one or more .apk files.")
                } else {
                    pendingInstall = apks
                }
            }) {
                DocumentPicker { urls in picked = urls }
                    .ignoresSafeArea()
            }
            .sheet(isPresented: Binding(get: { !pendingInstall.isEmpty }, set: { if !$0 { pendingInstall = [] } })) {
                InstallSheet(files: pendingInstall) { Task { await model.load(manager) } }
                    .environmentObject(manager)
            }
            .task(id: manager.endpoint) {
                if manager.connection != nil { await model.loadIfNeeded(manager) }
            }
            .errorAlert($model.error)
            .infoAlert("Result", message: $actionResult)
            .infoAlert("Cache", message: $model.notice)
        }
    }

    private var list: some View {
        List {
            Picker("Filter", selection: $filter) {
                ForEach(AppFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            if model.isLoading && model.packages.isEmpty {
                HStack { Spacer(); ProgressView("Loading apps…"); Spacer() }
            }
            ForEach(visible) { app in
                NavigationLink {
                    AppDetailView(app: app, model: model)
                } label: {
                    AppRow(app: app)
                }
                .swipeActions(edge: .trailing) {
                    if app.isInstalled {
                        Button { run(.forceStop, app) } label: { Label("Stop", systemImage: "stop.fill") }
                            .tint(.orange)
                    }
                }
                .swipeActions(edge: .leading) {
                    if app.isInstalled {
                        Button { run(.launch, app) } label: { Label("Launch", systemImage: "play.fill") }
                            .tint(.green)
                    }
                }
            }
            if !model.isLoading && visible.isEmpty {
                Text("No apps in this category.").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $search, prompt: "Search package")
        .refreshable { await model.load(manager) }
        .overlay(alignment: .top) {
            if model.isLoading && !model.packages.isEmpty { ProgressView().padding(.top, 4) }
        }
    }

    private func run(_ action: AppAction, _ app: AppPackage) {
        Task { actionResult = await model.perform(action, on: app, manager: manager) }
    }
}

struct AppRow: View {
    let app: AppPackage

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: app.isSystem ? "gearshape.fill" : "app.fill")
                .font(.title2)
                .foregroundStyle(app.isInstalled && app.isEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.id).font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    if app.isSystem { TagLabel("System", .gray) }
                    if !app.isEnabled { TagLabel("Disabled", .red) }
                    if !app.isInstalled { TagLabel("Removed", .orange) }
                }
            }
        }
    }
}

struct TagLabel: View {
    let text: LocalizedStringKey
    let color: Color

    init(_ text: LocalizedStringKey, _ color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct InstallSheet: View {
    let files: [URL]
    var onFinished: () -> Void

    @EnvironmentObject private var manager: DeviceManager
    @Environment(\.dismiss) private var dismiss
    @State private var replace = true
    @State private var downgrade = false
    @State private var grantAll = false
    @State private var allowTest = true
    @State private var status: String?
    @State private var isRunning = false
    @State private var result: String?
    @State private var error: String?

    private var flags: String {
        [replace ? "-r" : nil, downgrade ? "-d" : nil, grantAll ? "-g" : nil, allowTest ? "-t" : nil]
            .compactMap { $0 }.joined(separator: " ")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(files.count > 1 ? LocalizedStringKey("Split APKs (multiple install)") : "APK") {
                    ForEach(files, id: \.self) { Text($0.lastPathComponent).font(.footnote.monospaced()) }
                }
                Section("Options") {
                    Toggle("Replace if already installed (-r)", isOn: $replace)
                    Toggle("Allow downgrade (-d)", isOn: $downgrade)
                    Toggle("Grant all permissions (-g)", isOn: $grantAll)
                    Toggle("Allow test APKs (-t)", isOn: $allowTest)
                }
                Section {
                    Button {
                        Task { await install() }
                    } label: {
                        HStack {
                            Text("Install")
                            Spacer()
                            if isRunning { ProgressView() }
                        }
                    }
                    .disabled(isRunning)
                    if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
                    if let result { Text(result).font(.footnote.monospaced()).foregroundStyle(.green) }
                }
            }
            .navigationTitle("Install APK")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(isRunning) }
            }
            .errorAlert($error)
        }
        .interactiveDismissDisabled(isRunning)
    }

    private func install() async {
        isRunning = true
        result = nil
        defer { isRunning = false }
        do {
            let copies = try LocalFiles.importCopies(of: files)
            defer { copies.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }
            result = try await manager.install(files: copies, flags: flags) { status = $0 }
            status = nil
            onFinished()
        } catch {
            status = nil
            self.error = error.localizedDescription
        }
    }
}
