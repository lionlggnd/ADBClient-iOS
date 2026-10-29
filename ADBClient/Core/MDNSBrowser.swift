import Foundation

/// Discovers Android "Wireless debugging" endpoints advertised over Bonjour/mDNS.
final class MDNSBrowser: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    enum Kind: String {
        case pairing = "_adb-tls-pairing._tcp."
        case connect = "_adb-tls-connect._tcp."
        case legacy = "_adb._tcp."

        var label: String {
            switch self {
            case .pairing: return "Accoppiamento"
            case .connect: return "Debug wireless"
            case .legacy: return "ADB TCP"
            }
        }
    }

    struct Service: Identifiable, Hashable {
        var id: String { "\(kind.rawValue)|\(name)" }
        let name: String
        let kind: Kind
        let host: String
        let port: Int
    }

    @Published private(set) var services: [Service] = []

    private var browsers: [NetServiceBrowser] = []
    private var resolving: [NetService] = []

    func start() {
        guard browsers.isEmpty else { return }
        for kind in [Kind.pairing, .connect, .legacy] {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: kind.rawValue, inDomain: "local.")
            browsers.append(browser)
        }
    }

    func stop() {
        browsers.forEach { $0.stop() }
        browsers.removeAll()
        resolving.forEach { $0.stop() }
        resolving.removeAll()
        services.removeAll()
    }

    func restart() {
        stop()
        start()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0.name == service.name && $0.kind.rawValue == service.type }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        resolving.removeAll { $0 === sender }
        guard let kind = Kind(rawValue: sender.type), let host = Self.ipv4(from: sender.addresses ?? []) ?? sender.hostName
        else { return }
        let service = Service(name: sender.name, kind: kind, host: host, port: sender.port)
        services.removeAll { $0.id == service.id }
        services.append(service)
        services.sort { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 === sender }
    }

    private static func ipv4(from addresses: [Data]) -> String? {
        for data in addresses {
            let address: String? = data.withUnsafeBytes { raw in
                guard raw.count >= MemoryLayout<sockaddr_in>.size,
                      raw.load(as: sockaddr.self).sa_family == sa_family_t(AF_INET) else { return nil }
                var sin = raw.load(as: sockaddr_in.self)
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                return String(cString: buffer)
            }
            if let address { return address }
        }
        return nil
    }
}
