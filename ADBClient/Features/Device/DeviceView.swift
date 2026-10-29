import SwiftUI

struct DeviceView: View {
    @EnvironmentObject private var manager: DeviceManager
    @StateObject private var browser = MDNSBrowser()

    @AppStorage("lastHost") private var host = ""
    @AppStorage("lastPort") private var port = "5555"
    @State private var pairHost = ""
    @State private var pairPort = ""
    @State private var pairCode = ""
    @State private var isPairing = false
    @State private var error: String?
    @State private var notice: String?
    @State private var confirmReboot: String?

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                if manager.connection != nil {
                    deviceSection
                } else {
                    connectSection
                    pairSection
                }
                discoveredSection
                if !manager.savedDevices.isEmpty { savedSection }
            }
            .navigationTitle("ADB Client")
            .onAppear { browser.start() }
            .refreshable { browser.restart() }
            .errorAlert($error)
            .infoAlert("ADB", message: $notice)
            .infoAlert("Connessione persa", message: $manager.connectionLostMessage)
            .confirmationDialog("Riavviare il dispositivo?",
                                isPresented: Binding(get: { confirmReboot != nil }, set: { if !$0 { confirmReboot = nil } }),
                                titleVisibility: .visible) {
                Button("Riavvia", role: .destructive) {
                    if let target = confirmReboot { reboot(target) }
                }
            }
        }
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: statusIcon)
                    .font(.system(size: 30))
                    .foregroundStyle(statusColor)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle).font(.headline)
                    Text(statusSubtitle).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if manager.status == .connecting || manager.status == .waitingAuthorization { ProgressView() }
            }
            .padding(.vertical, 4)
        }
    }

    private var deviceSection: some View {
        Group {
            Section("Dispositivo") {
                LabeledContent("Modello", value: manager.info.displayName)
                LabeledContent("Android", value: "\(manager.info.androidVersion) (SDK \(manager.info.sdk))")
                if !manager.info.serial.isEmpty { LabeledContent("Seriale", value: manager.info.serial) }
                if !manager.info.battery.isEmpty { LabeledContent("Batteria", value: "\(manager.info.battery)%") }
                LabeledContent("Indirizzo", value: manager.endpoint)
                LabeledContent("Cifratura", value: manager.connection?.usesTLS == true ? "TLS (Debug wireless)" : "Nessuna (ADB TCP)")
            }
            Section("Azioni") {
                Menu {
                    Button("Sistema") { confirmReboot = "" }
                    Button("Recovery") { confirmReboot = "recovery" }
                    Button("Bootloader") { confirmReboot = "bootloader" }
                    Button("Fastboot (userspace)") { confirmReboot = "fastboot" }
                    Button("Sideload") { confirmReboot = "sideload" }
                } label: {
                    Label("Riavvia…", systemImage: "restart")
                }
                Button {
                    Task { await runService("tcpip:5555") }
                } label: {
                    Label("Abilita ADB TCP sulla porta 5555", systemImage: "network")
                }
                Button {
                    Task { await manager.refreshInfo() }
                } label: {
                    Label("Aggiorna informazioni", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    manager.disconnect()
                } label: {
                    Label("Disconnetti", systemImage: "xmark.circle")
                }
            }
        }
    }

    private var connectSection: some View {
        Section {
            TextField("Indirizzo IP (es. 192.168.1.50)", text: $host)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Porta", text: $port)
                .keyboardType(.numberPad)
            Button {
                Task { await connect(host: host, port: Int(port) ?? 0) }
            } label: {
                Label("Connetti", systemImage: "bolt.horizontal.circle")
            }
            .disabled(host.trimmed.isEmpty || manager.status == .connecting || manager.status == .waitingAuthorization)
        } header: {
            Text("Connessione diretta")
        } footer: {
            Text("Debug wireless (Android 11+): usa IP e porta mostrati in Opzioni sviluppatore > Debug wireless, " +
                 "dopo aver accoppiato l'app. ADB TCP classico: porta 5555 dopo 'adb tcpip 5555'.")
        }
    }

    private var pairSection: some View {
        Section {
            TextField("Indirizzo IP", text: $pairHost)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Porta di accoppiamento", text: $pairPort)
                .keyboardType(.numberPad)
            TextField("Codice di accoppiamento (6 cifre)", text: $pairCode)
                .keyboardType(.numberPad)
            Button {
                Task { await pair() }
            } label: {
                HStack {
                    Label("Accoppia", systemImage: "link")
                    Spacer()
                    if isPairing { ProgressView() }
                }
            }
            .disabled(isPairing || pairHost.trimmed.isEmpty || pairPort.isEmpty || pairCode.isEmpty)
        } header: {
            Text("Accoppiamento con codice")
        } footer: {
            Text("Sul telefono: Opzioni sviluppatore > Debug wireless > Accoppia dispositivo con codice di accoppiamento. " +
                 "Tieni aperta quella schermata mentre accoppi.")
        }
    }

    private var discoveredSection: some View {
        Section {
            if browser.services.isEmpty {
                Text("Nessun servizio trovato. Apri Debug wireless sul telefono (stessa rete Wi-Fi).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(browser.services) { service in
                Button {
                    select(service)
                } label: {
                    HStack {
                        Image(systemName: service.kind == .pairing ? "link.circle" : "wifi")
                        VStack(alignment: .leading) {
                            Text(service.name).font(.subheadline).foregroundStyle(.primary)
                            Text("\(service.kind.label) · \(service.host):\(service.port)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Rilevati in rete")
        }
    }

    private var savedSection: some View {
        Section("Dispositivi recenti") {
            ForEach(manager.savedDevices) { device in
                Button {
                    Task { await connect(host: device.host, port: device.port) }
                } label: {
                    VStack(alignment: .leading) {
                        Text(device.name).foregroundStyle(.primary)
                        Text(device.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .disabled(manager.connection != nil)
            }
            .onDelete { offsets in
                offsets.map { manager.savedDevices[$0] }.forEach(manager.forget)
            }
        }
    }

    // MARK: Status

    private var statusIcon: String {
        switch manager.status {
        case .connected: return "checkmark.circle.fill"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .waitingAuthorization: return "hand.raised.fill"
        case .disconnected: return "bolt.horizontal.circle"
        }
    }

    private var statusColor: Color {
        switch manager.status {
        case .connected: return .green
        case .connecting: return .blue
        case .waitingAuthorization: return .orange
        case .disconnected: return .secondary
        }
    }

    private var statusTitle: String {
        switch manager.status {
        case .connected: return manager.info.displayName
        case .connecting: return "Connessione in corso…"
        case .waitingAuthorization: return "In attesa di autorizzazione"
        case .disconnected: return "Non connesso"
        }
    }

    private var statusSubtitle: String {
        switch manager.status {
        case .connected: return manager.endpoint
        case .connecting: return "\(host):\(port)"
        case .waitingAuthorization: return "Conferma \"Consenti debug\" sullo schermo del dispositivo."
        case .disconnected: return "Inserisci l'indirizzo o scegli un dispositivo rilevato."
        }
    }

    // MARK: Actions

    private func select(_ service: MDNSBrowser.Service) {
        switch service.kind {
        case .pairing:
            pairHost = service.host
            pairPort = String(service.port)
        case .connect, .legacy:
            host = service.host
            port = String(service.port)
            if manager.connection == nil {
                Task { await connect(host: service.host, port: service.port) }
            }
        }
    }

    private func connect(host: String, port: Int) async {
        do {
            try await manager.connect(host: host, port: port)
            self.host = host
            self.port = String(port)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func pair() async {
        isPairing = true
        defer { isPairing = false }
        do {
            let guid = try await manager.pair(host: pairHost, port: Int(pairPort) ?? 0, code: pairCode)
            pairCode = ""
            host = pairHost.trimmed
            if let connectService = browser.services.first(where: { $0.kind == .connect && $0.host == host }) {
                port = String(connectService.port)
            } else {
                port = ""
            }
            notice = "Accoppiamento riuscito\(guid.isEmpty ? "" : " (\(guid))").\n\n" +
                "Ora inserisci la porta indicata in \"Debug wireless\" (diversa da quella di accoppiamento) e premi Connetti."
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reboot(_ target: String) {
        Task { await runService("reboot:" + target) }
    }

    private func runService(_ name: String) async {
        do {
            let output = try await manager.service(name).trimmed
            if !output.isEmpty { notice = output }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
