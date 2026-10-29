import SwiftUI
import UIKit

struct TerminalView: View {
    @EnvironmentObject private var terminal: TerminalModel
    @EnvironmentObject private var manager: DeviceManager
    @FocusState private var inputFocused: Bool

    private let keys: [(String, String)] = [
        ("Ctrl-C", "\u{03}"), ("Ctrl-D", "\u{04}"), ("Tab", "\t"), ("Esc", "\u{1B}"),
        ("↑", "\u{1B}[A"), ("↓", "\u{1B}[B"), ("←", "\u{1B}[D"), ("→", "\u{1B}[C"), ("Ctrl-Z", "\u{1A}"),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TerminalTextView(text: terminal.text)
                    .onTapGesture { inputFocused = true }
                if terminal.isInteractive { keyBar }
                inputBar
            }
            .background(Color.black)
            .navigationTitle(terminal.isInteractive ? "Shell" : "Terminale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text(manager.connection == nil ? "offline" : manager.endpoint)
                        .font(.caption.monospaced())
                        .foregroundStyle(manager.connection == nil ? .red : .green)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { terminal.clear() } label: { Label("Pulisci", systemImage: "trash") }
                        Button { UIPasteboard.general.string = terminal.text } label: {
                            Label("Copia output", systemImage: "doc.on.doc")
                        }
                        if !terminal.isRunning {
                            Button { run("shell") } label: { Label("Shell interattiva", systemImage: "terminal") }
                            Button { run("logcat -v time") } label: { Label("Logcat", systemImage: "list.bullet.rectangle") }
                            Button { run("help") } label: { Label("Aiuto", systemImage: "questionmark.circle") }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private var keyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(keys.indices, id: \.self) { index in
                    Button(keys[index].0) { terminal.sendKey(keys[index].1) }
                        .font(.caption.monospaced())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color(white: 0.08))
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Text(terminal.isInteractive ? "$" : "adb>")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.green)
            TextField(terminal.isInteractive ? "comando shell" : "comando (es. shell ls /sdcard)", text: $terminal.input)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.white)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .focused($inputFocused)
                .disabled(terminal.isRunning && !terminal.isInteractive)
                .onSubmit {
                    terminal.submit()
                    inputFocused = true
                }
            if !terminal.isInteractive {
                Button { terminal.historyPrevious() } label: { Image(systemName: "chevron.up") }
                Button { terminal.historyNext() } label: { Image(systemName: "chevron.down") }
            }
            if terminal.isRunning {
                Button { terminal.cancel() } label: { Image(systemName: "stop.circle.fill").foregroundStyle(.red) }
            } else {
                Button { terminal.submit() } label: { Image(systemName: "return") }
            }
        }
        .padding(10)
        .background(Color(white: 0.12))
    }

    private func run(_ command: String) {
        terminal.input = command
        terminal.submit()
    }
}

/// Read-only, auto-scrolling monospaced text view (UITextView handles large output far better than Text).
struct TerminalTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .black
        view.textColor = UIColor(white: 0.92, alpha: 1)
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        view.alwaysBounceVertical = true
        view.dataDetectorTypes = []
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard view.text != text else { return }
        let atBottom = view.contentOffset.y >= view.contentSize.height - view.bounds.height - 40
        view.text = text
        if atBottom || text.utf8.count < 2000 {
            let length = (text as NSString).length
            if length > 0 { view.scrollRangeToVisible(NSRange(location: length - 1, length: 1)) }
        }
    }
}
