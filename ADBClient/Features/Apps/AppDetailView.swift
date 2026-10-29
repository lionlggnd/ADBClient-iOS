import SwiftUI

struct AppDetailView: View {
    let app: AppPackage
    @ObservedObject var model: AppsModel

    @EnvironmentObject private var manager: DeviceManager
    @State private var details: AppDetails?
    @State private var isBusy = false
    @State private var confirm: AppAction?
    @State private var result: String?
    @State private var error: String?
    @State private var shared: SharedFiles?

    private var current: AppPackage {
        model.packages.first { $0.id == app.id } ?? app
    }

    var body: some View {
        List {
            headerSection
            actionsSection
            if let details {
                infoSection(details)
                if !details.permissions.isEmpty { permissionsSection(details) }
            } else {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            }
        }
        .navigationTitle(current.id.components(separatedBy: ".").last ?? current.id)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if isBusy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .task { await loadDetails() }
        .refreshable { await loadDetails() }
        .confirmationDialog(confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible) {
            if let action = confirm {
                Button(action.title, role: .destructive) { run(action) }
            }
        } message: {
            Text("Confermi l'operazione su \(current.id)?")
        }
        .infoAlert("Risultato", message: $result)
        .errorAlert($error)
        .sheet(item: $shared) { ShareSheet(items: $0.urls) }
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(current.id).font(.headline).textSelection(.enabled)
                HStack {
                    TagLabel(current.isSystem ? "Sistema" : "Utente", current.isSystem ? .gray : .blue)
                    TagLabel(current.isEnabled ? "Attiva" : "Disattivata", current.isEnabled ? .green : .red)
                    if !current.isInstalled { TagLabel("Rimossa per l'utente", .orange) }
                }
            }
        }
    }

    private var actionsSection: some View {
        Section("Azioni") {
            ForEach(AppAction.available(for: current)) { action in
                actionButton(action)
            }
            if current.isInstalled {
                Button {
                    Task { await extract() }
                } label: {
                    Label("Estrai APK", systemImage: "square.and.arrow.up")
                }
                .disabled(isBusy)
            }
        }
    }

    private func infoSection(_ details: AppDetails) -> some View {
        Section("Informazioni") {
            ForEach(details.fields) { field in
                LabeledContent(field.label) {
                    Text(field.value)
                        .font(.footnote)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private func permissionsSection(_ details: AppDetails) -> some View {
        Section("Permessi runtime") {
            ForEach(details.permissions) { permission in
                permissionToggle(permission)
            }
        }
    }

    private func permissionToggle(_ permission: AppDetails.Permission) -> some View {
        let binding = Binding<Bool>(
            get: { permission.granted },
            set: { value in Task { await setPermission(permission, value) } })
        let name = permission.name.replacingOccurrences(of: "android.permission.", with: "")
        return Toggle(isOn: binding) {
            Text(name).font(.footnote)
        }
        .disabled(isBusy)
    }

    private func actionButton(_ action: AppAction) -> some View {
        let role: ButtonRole? = action.isDestructive ? .destructive : nil
        return Button(role: role) {
            if action.isDestructive {
                confirm = action
            } else {
                run(action)
            }
        } label: {
            Label(action.title, systemImage: action.icon)
        }
        .disabled(isBusy)
    }

    private func run(_ action: AppAction) {
        Task {
            isBusy = true
            result = await model.perform(action, on: current, manager: manager)
            isBusy = false
            await loadDetails()
        }
    }

    private func loadDetails() async {
        do {
            details = try await model.details(for: current, manager: manager)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func setPermission(_ permission: AppDetails.Permission, _ granted: Bool) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let output = try await model.setPermission(permission.name, granted: granted, app: current, manager: manager)
            if !output.isEmpty { result = output }
            await loadDetails()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func extract() async {
        isBusy = true
        defer { isBusy = false }
        do {
            shared = SharedFiles(urls: try await model.extractAPKs(of: current, manager: manager))
        } catch {
            self.error = error.localizedDescription
        }
    }
}
