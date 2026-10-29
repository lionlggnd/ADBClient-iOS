import SwiftUI

@main
struct ADBClientApp: App {
    @StateObject private var manager: DeviceManager
    @StateObject private var terminal: TerminalModel

    init() {
        let manager = DeviceManager()
        _manager = StateObject(wrappedValue: manager)
        _terminal = StateObject(wrappedValue: TerminalModel(manager: manager))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
                .environmentObject(terminal)
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            DeviceView()
                .tabItem { Label("Dispositivo", systemImage: "antenna.radiowaves.left.and.right") }
            AppsView()
                .tabItem { Label("App", systemImage: "square.grid.2x2") }
            FilesView()
                .tabItem { Label("File", systemImage: "folder") }
            TerminalView()
                .tabItem { Label("Terminale", systemImage: "terminal") }
            SettingsView()
                .tabItem { Label("Impostazioni", systemImage: "gearshape") }
        }
        .liquidGlassTabBar()
    }
}

private extension View {
    /// On iOS 26 the system TabView already renders as Liquid Glass; this also lets it shrink while scrolling.
    @ViewBuilder
    func liquidGlassTabBar() -> some View {
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}
