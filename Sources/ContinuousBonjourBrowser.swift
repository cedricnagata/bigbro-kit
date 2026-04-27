import Foundation

enum BrowseEvent: Sendable {
    case appeared(BigBroDevice)
    case disappeared(String)
}

/// Long-lived Bonjour browser. Emits events as services appear and disappear.
/// Independent of `BonjourBrowser` so the one-shot discovery flow is unaffected.
@MainActor
final class ContinuousBonjourBrowser: NSObject {
    private var browser: NetServiceBrowser?
    private var pendingServices: [NetService] = []
    private var resolved: [String: BigBroDevice] = [:]   // service name → device
    private var continuation: AsyncStream<BrowseEvent>.Continuation?

    func start() -> AsyncStream<BrowseEvent> {
        stop()
        let (stream, cont) = AsyncStream<BrowseEvent>.makeStream(of: BrowseEvent.self)
        self.continuation = cont

        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: "_bigbro._tcp.", inDomain: "local.")
        self.browser = browser
        print("[ContinuousBrowser] Started")
        return stream
    }

    func stop() {
        guard browser != nil || !pendingServices.isEmpty || continuation != nil else { return }
        print("[ContinuousBrowser] Stopping")
        browser?.delegate = nil
        browser?.stop()
        browser = nil
        for s in pendingServices { s.delegate = nil; s.stop() }
        pendingServices = []
        resolved = [:]
        continuation?.finish()
        continuation = nil
    }
}

extension ContinuousBonjourBrowser: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService,
                           moreComing: Bool) {
        print("[ContinuousBrowser] Found: \(service.name)")
        pendingServices.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didRemove service: NetService,
                           moreComing: Bool) {
        print("[ContinuousBrowser] Removed: \(service.name)")
        let name = service.name
        if resolved.removeValue(forKey: name) != nil {
            continuation?.yield(.disappeared(name))
        }
        pendingServices.removeAll { $0 === service }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didNotSearch errorDict: [String: NSNumber]) {
        print("[ContinuousBrowser] Search error: \(errorDict)")
        stop()
    }
}

extension ContinuousBonjourBrowser: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, sender.port > 0 else { return }
        let device = BigBroDevice(id: sender.name, name: sender.name, host: host, port: sender.port)
        if resolved[sender.name] == nil {
            resolved[sender.name] = device
            continuation?.yield(.appeared(device))
            print("[ContinuousBrowser] Appeared: \(device.name) at \(host):\(sender.port)")
        }
        pendingServices.removeAll { $0 === sender }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        print("[ContinuousBrowser] Failed to resolve \(sender.name): \(errorDict)")
        pendingServices.removeAll { $0 === sender }
    }
}
