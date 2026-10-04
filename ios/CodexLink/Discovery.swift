import Foundation
import Darwin

struct DiscoveredMac: Identifiable {
    let id: String
    let name: String
    let pin: String
    let addresses: [String]
    let port: Int
}

final class Discovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var found: [ObjectIdentifier: DiscoveredMac] = [:]
    var onChange: (([DiscoveredMac]) -> Void)?
    var onError: ((String) -> Void)?

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        stop()
        browser.searchForServices(ofType: "_codexlink._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        services.forEach { $0.stopMonitoring(); $0.stop() }
        services.removeAll()
        found.removeAll()
        publish()
    }

    func refreshAddresses() {
        // DHCP may change the Mac's IPv4 without changing the iPhone's path or TXT.
        services.forEach { $0.resolve(withTimeout: 5) }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
        service.startMonitoring()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        for item in services.filter({ $0 == service }) {
            item.stopMonitoring(); item.stop()
            found.removeValue(forKey: ObjectIdentifier(item))
        }
        services.removeAll { $0 == service }
        publish()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        onError?("局域网发现失败，请在 iOS 设置中允许 codex-link 访问局域网")
    }

    func netServiceDidResolveAddress(_ sender: NetService) { update(sender) }
    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) { update(sender) }

    private func update(_ service: NetService) {
        guard let txt = service.txtRecordData() else { return }
        let record = NetService.dictionary(fromTXTRecord: txt)
        func field(_ key: String) -> String { record[key].flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        let id = field("id"), pin = field("pin")
        guard field("v") == "1", UUID(uuidString: id) != nil,
              pin.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              (1...65535).contains(service.port) else { return }
        let addresses: [String] = (service.addresses ?? []).compactMap { data in
            data.withUnsafeBytes { buffer -> String? in
                guard let base = buffer.baseAddress, data.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                let address = base.assumingMemoryBound(to: sockaddr.self)
                guard address.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(data.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(cString: host)
            }
        }
        guard !addresses.isEmpty else { return }
        found[ObjectIdentifier(service)] = DiscoveredMac(id: id, name: service.name, pin: pin,
                                                        addresses: addresses, port: service.port)
        publish()
    }

    private func publish() {
        // One Mac may appear on multiple LAN interfaces; merge only equal pins.
        var grouped: [String: DiscoveredMac] = [:]
        for mac in found.values {
            let key = mac.id + mac.pin
            if let old = grouped[key] {
                grouped[key] = DiscoveredMac(id: mac.id, name: mac.name, pin: mac.pin,
                    addresses: Array(Set(old.addresses + mac.addresses)).sorted(), port: mac.port)
            } else { grouped[key] = mac }
        }
        onChange?(grouped.values.sorted { $0.name < $1.name })
    }
}
