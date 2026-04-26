import Foundation

@MainActor
final class BonjourBrowser: NSObject {
    private var browser: NetServiceBrowser?
    private var pendingServices: [NetService] = []
    private var resolvedDevices: [BigBroDevice] = []
    private var waiters: [CheckedContinuation<[BigBroDevice], Never>] = []
    private var timeoutTask: Task<Void, Never>?
    private var isDiscovering = false

    func discover(timeout: TimeInterval = 5.0) async -> [BigBroDevice] {
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)

            // If a discovery is already running, just join it — both callers will
            // receive the same result when it finishes.
            if isDiscovering {
                print("[BonjourBrowser] Joining in-flight discovery (\(waiters.count) waiter(s))")
                return
            }

            isDiscovering = true
            resolvedDevices = []
            pendingServices = []
            print("[BonjourBrowser] Starting search for _bigbro._tcp.")

            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: "_bigbro._tcp.", inDomain: "local.")
            self.browser = browser

            self.timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.finish()
            }
        }
    }

    private func finish() {
        guard isDiscovering else { return }
        isDiscovering = false
        timeoutTask?.cancel()
        timeoutTask = nil

        // Clear delegates so any in-flight Bonjour callbacks don't bleed into a
        // subsequent discovery, then stop.
        browser?.delegate = nil
        browser?.stop()
        browser = nil
        for service in pendingServices {
            service.delegate = nil
            service.stop()
        }
        pendingServices = []

        let result = resolvedDevices
        let toResume = waiters
        waiters = []
        print("[BonjourBrowser] Discovery finished, found \(result.count) device(s) — resuming \(toResume.count) caller(s)")
        for waiter in toResume {
            waiter.resume(returning: result)
        }
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
        if !resolvedDevices.contains(where: { $0.id == device.id }) {
            resolvedDevices.append(device)
        }
        pendingServices.removeAll { $0 === sender }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        print("[BonjourBrowser] Failed to resolve \(sender.name): \(errorDict)")
        pendingServices.removeAll { $0 === sender }
    }
}
