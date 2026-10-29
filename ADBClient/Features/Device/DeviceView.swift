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
            .infoAlert("Connection lost", message: $manager.connectionLostMessage)
            .confirmationDialog("Reboot the device?",
                                isPresented: Binding(get: { confirmReboot != nil }, set: { if !$0 { confirmReboot = nil } }),
                                titleVisibility: .visible) {
                Button("Reboot", role: .destructive) {
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
            Section("Device") {
                LabeledContent("Model", value: manager.info.displayName)
                LabeledContent("Android", value: "\(manager.info.androidVersion) (SDK \(manager.info.sdk))")
                if !manager.info.serial.isEmpty { LabeledContent("Serial", value: manager.info.serial) }
                if !manager.info.battery.isEmpty { LabeledContent("Battery", value: "\(manager.info.battery)%") }
                LabeledContent("Address", value: manager.endpoint)
                LabeledContent("Encryption", value: manager.connection?.usesTLS == true
                                ? String(localized: "TLS (Wireless debugging)") : String(localized: "None (ADB TCP)"))
            }
            Section("Actions") {
                Menu {
                    Button("System") { confirmReboot = "" }
                    Button("Recovery") { confirmReboot = "recovery" }
                    Button("Bootloader") { confirmReboot = "bootloader" }
                    Button("Fastboot (userspace)") { confirmReboot = "fastboot" }
                    Button("Sideload") { confirmReboot = "sideload" }
                } label: {
                    Label("Reboot…", systemImage: "restart")
                }
                Button {
                    Task { await runService("tcpip:5555") }
                } label: {
                    Label("Enable ADB over TCP on port 5555", systemImage: "network")
                }
                Button {
                    Task { await manager.refreshInfo() }
                } label: {
                    Label("Refresh information", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    manager.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            }
        }
    }

    private var connectSection: some View {
        Section {
            TextField("IP address (e.g. 192.168.1.50)", text: $host)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Port", text: $port)
                .keyboardType(.numberPad)
            Button {
                Task { await connect(host: host, port: Int(port) ?? 0) }
            } label: {
                Label("Connect", systemImage: "bolt.horizontal.circle")
            }
            .disabled(host.trimmed.isEmpty || manager.status == .connecting || manager.status == .waitingAuthorization)
        } header: {
            Text("Direct connection")
        } footer: {
            Text("Wireless debugging (Android 11+): use the IP and port shown in Developer options > Wireless debugging, after pairing the app. Classic ADB over TCP: port 5555 after 'adb tcpip 5555'.")
        }
    }

    private var pairSection: some View {
        Section {
            TextField("IP address", text: $pairHost)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Pairing port", text: $pairPort)
                .keyboardType(.numberPad)
            TextField("Pairing code (6 digits)", text: $pairCode)
                .keyboardType(.numberPad)
            Button {
                Task { await pair() }
            } label: {
                HStack {
                    Label("Pair", systemImage: "link")
                    Spacer()
                    if isPairing { ProgressView() }
                }
            }
            .disabled(isPairing || pairHost.trimmed.isEmpty || pairPort.isEmpty || pairCode.isEmpty)
        } header: {
            Text("Pair with code")
        } footer: {
            Text("On the phone: Developer options > Wireless debugging > Pair device with pairing code. Keep that screen open while pairing.")
        }
    }

    private var discoveredSection: some View {
        Section {
            if browser.services.isEmpty {
                Text("No services found. Open Wireless debugging on the phone (same Wi-Fi network).")
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
            Text("Discovered on network")
        }
    }

    private var savedSection: some View {
        Section("Recent devices") {
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
        case .connecting: return String(localized: "Connecting…")
        case .waitingAuthorization: return String(localized: "Waiting for authorization")
        case .disconnected: return String(localized: "Not connected")
        }
    }

    private var statusSubtitle: String {
        switch manager.status {
        case .connected: return manager.endpoint
        case .connecting: return "\(host):\(port)"
        case .waitingAuthorization: return String(localized: "Confirm \"Allow debugging\" on the device screen.")
        case .disconnected: return String(localized: "Enter the address or pick a discovered device.")
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
            let suffix = guid.isEmpty ? "" : " (\(guid))"
            notice = String(localized:
                "Pairing succeeded\(suffix).\n\nNow enter the port shown in \"Wireless debugging\" (different from the pairing port) and tap Connect.")
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
