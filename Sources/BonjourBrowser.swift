import Foundation

final class BonjourBrowser: NSObject, @unchecked Sendable {
    private var browser: NetServiceBrowser?
    private var pendingServices: [NetService] = []
    private var resolvedDevices: [BigBroDevice] = []
    private var continuation: CheckedContinuation<[BigBroDevice], Never>?
    private var timeoutTask: Task<Void, Never>?

    func discover(timeout: TimeInterval = 5.0) async -> [BigBroDevice] {
        resolvedDevices = []
        pendingServices = []
        print("[BonjourBrowser] Starting search for _bigbro._tcp.")

        return await withCheckedContinuation { continuation in
            self.continuation = continuation

            DispatchQueue.main.async {
                let browser = NetServiceBrowser()
                browser.delegate = self
                browser.searchForServices(ofType: "_bigbro._tcp.", inDomain: "local.")
                self.browser = browser
            }

            self.timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.finish()
            }
        }
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        DispatchQueue.main.async {
            self.browser?.stop()
            self.browser = nil
        }
        print("[BonjourBrowser] Discovery finished, found \(resolvedDevices.count) device(s): \(resolvedDevices.map { "\($0.name) \($0.host):\($0.port)" })")
        continuation.resume(returning: resolvedDevices)
    }
}

extension BonjourBrowser: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService,
                           moreComing: Bool) {
        print("[BonjourBrowser] Found service: \(service.name) type=\(service.type) domain=\(service.domain)")
        pendingServices.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didNotSearch errorDict: [String: NSNumber]) {
        print("[BonjourBrowser] Search error: \(errorDict)")
        finish()
    }
}

extension BonjourBrowser: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        print("[BonjourBrowser] Resolved: \(sender.name) host=\(sender.hostName ?? "nil") port=\(sender.port)")
        guard let hostName = sender.hostName, sender.port > 0 else {
            print("[BonjourBrowser] Skipping \(sender.name) — missing host or port")
            return
        }
        let device = BigBroDevice(id: sender.name, name: sender.name, host: hostName, port: sender.port)
        resolvedDevices.append(device)
        pendingServices.removeAll { $0 === sender }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        print("[BonjourBrowser] Failed to resolve \(sender.name): \(errorDict)")
        pendingServices.removeAll { $0 === sender }
    }
}
