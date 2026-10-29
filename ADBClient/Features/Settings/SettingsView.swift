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
                    TextField("Key name", text: $keyName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(saveName)
                } header: {
                    Text("Identity")
                } footer: {
                    Text("Name shown on the device in the list of debugging authorizations.")
                }

                Section("ADB public key") {
                    Text(publicKey.isEmpty ? "…" : publicKey)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(6)
                    Button {
                        UIPasteboard.general.string = publicKey
                        copied = true
                    } label: {
                        Label(copied ? String(localized: "Copied") : String(localized: "Copy public key"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        confirmRegenerate = true
                    } label: {
                        Label("Regenerate key", systemImage: "key")
                    }
                }

                Section("Local files") {
                    Text("Push, pull, extracted APKs and downloaded files are in the app's Documents folder: Files app > On My iPhone > ADB Client.")
                        .font(.footnote)
                }

                Section("Information") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    LabeledContent("ADB protocol", value: "0x01000001")
                    Text("Native ADB client: talks directly to adbd over TCP/TLS, without an adb server on a computer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .task { loadKey() }
            .onDisappear(perform: saveName)
            .confirmationDialog("Regenerate the key?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
                Button("Regenerate", role: .destructive, action: regenerate)
            } message: {
                Text("All devices will need to authorize the app again (and, with wireless debugging, pair again).")
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
