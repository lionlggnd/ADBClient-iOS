import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var manager: DeviceManager
    @State private var keyName = AdbKeyStore.shared.keyName
    @State private var publicKey = ""
    @State private var confirmRegenerate = false
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nome chiave", text: $keyName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(saveName)
                } header: {
                    Text("Identità")
                } footer: {
                    Text("Nome mostrato sul dispositivo nell'elenco delle autorizzazioni di debug.")
                }

                Section("Chiave pubblica ADB") {
                    Text(publicKey.isEmpty ? "…" : publicKey)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(6)
                    Button {
                        UIPasteboard.general.string = publicKey
                        copied = true
                    } label: {
                        Label(copied ? "Copiata" : "Copia chiave pubblica", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        confirmRegenerate = true
                    } label: {
                        Label("Rigenera chiave", systemImage: "key")
                    }
                }

                Section("File locali") {
                    Text("Push, pull, APK estratti e file scaricati si trovano nella cartella Documenti dell'app: " +
                         "app File > Sul mio iPhone > ADB Client.")
                        .font(.footnote)
                }

                Section("Informazioni") {
                    LabeledContent("Versione", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    LabeledContent("Protocollo ADB", value: "0x01000001")
                    Text("Client ADB nativo: parla direttamente con adbd via TCP/TLS, senza server adb sul computer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Impostazioni")
            .task { loadKey() }
            .onDisappear(perform: saveName)
            .confirmationDialog("Rigenerare la chiave?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
                Button("Rigenera", role: .destructive, action: regenerate)
            } message: {
                Text("Tutti i dispositivi dovranno autorizzare di nuovo l'app (e, con Debug wireless, rifare l'accoppiamento).")
            }
            .errorAlert($error)
        }
    }

    private func saveName() {
        AdbKeyStore.shared.keyName = keyName.trimmed
        keyName = AdbKeyStore.shared.keyName
        loadKey()
    }

    private func loadKey() {
        do {
            publicKey = try AdbKeyStore.shared.publicKey()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func regenerate() {
        manager.disconnect()
        do {
            try AdbKeyStore.shared.regenerate()
            copied = false
            loadKey()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
