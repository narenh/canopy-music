import Foundation
import Network

/// Triggers (and waits for) the Local Network permission prompt by browsing for a Bonjour
/// service, so a fresh install asks as soon as the server starts. Without the permission the
/// `music.local` announcement doesn't work, while the IP address keeps working.
@MainActor
final class LocalNetworkPermission {
    private let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: .tcp)
    private var continuation: CheckedContinuation<Bool, Never>?

    /// Returns true once allowed, false if denied. While the prompt is up, this waits.
    static func request() async -> Bool {
        await LocalNetworkPermission().run()
    }

    private func run() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            browser.stateUpdateHandler = { [self] state in
                MainActor.assumeIsolated {
                    #if DEBUG
                    print("[local-network] browser state \(state)")
                    #endif
                    switch state {
                    case .waiting(let error), .failed(let error):
                        #if DEBUG
                        print("[local-network] browser \(state): \(error)")
                        #endif
                        if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                            finish(false)
                        }
                    default:
                        break
                    }
                }
            }
            // Any result means Bonjour works, i.e. permission is granted (Canopy's own service
            // shows up once allowed).
            browser.browseResultsChangedHandler = { [self] results, _ in
                MainActor.assumeIsolated {
                    if !results.isEmpty { finish(true) }
                }
            }
            browser.start(queue: .main)
            Task { [self] in
                try? await Task.sleep(for: .seconds(60))
                finish(false)
            }
        }
    }

    private func finish(_ allowed: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        browser.cancel()
        continuation.resume(returning: allowed)
    }
}
