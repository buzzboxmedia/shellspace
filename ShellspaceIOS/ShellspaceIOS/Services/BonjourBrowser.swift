import Foundation
import Network

/// Represents a Shellspace Mac discovered via Bonjour on the local network.
struct DiscoveredHost: Identifiable, Equatable {
    let id: String          // NWBrowser.Result hash or endpoint description
    let name: String        // Bonjour service name (Mac's hostname)
    let host: String        // Resolved IP or hostname
    let port: Int
    let endpoint: NWEndpoint

    var connectionHost: String {
        // Strip port if present, just return the host part
        host
    }
}

/// Browses for _shellspace._tcp services on the local network using NWBrowser.
/// Resolves discovered services to IP addresses for HTTP/WebSocket connection.
@Observable
final class BonjourBrowser {
    var discoveredHosts: [DiscoveredHost] = []
    var isSearching = false

    private var browser: NWBrowser?
    private var connections: [String: NWConnection] = [:]  // For resolving endpoints

    func startBrowsing() {
        stopBrowsing()
        isSearching = true
        discoveredHosts = []

        let params = NWParameters()
        params.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: "_shellspace._tcp", domain: nil), using: params)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isSearching = true
                case .failed(let error):
                    print("[BonjourBrowser] Browse failed: \(error)")
                    self?.isSearching = false
                case .cancelled:
                    self?.isSearching = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor in
                self?.handleResults(results)
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isSearching = false
        // Cancel any pending resolution connections
        for (_, conn) in connections {
            conn.cancel()
        }
        connections = [:]
    }

    // MARK: - Resolution

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        // Remove hosts that are no longer in results
        let currentEndpoints = Set(results.map { endpointId($0.endpoint) })
        discoveredHosts.removeAll { !currentEndpoints.contains($0.id) }

        // Resolve new services
        for result in results {
            let id = endpointId(result.endpoint)
            if discoveredHosts.contains(where: { $0.id == id }) {
                continue  // Already resolved
            }

            let name = serviceName(from: result.endpoint)
            resolveEndpoint(result.endpoint, id: id, name: name)
        }
    }

    private func resolveEndpoint(_ endpoint: NWEndpoint, id: String, name: String) {
        // Create a connection to resolve the Bonjour endpoint to an IP
        let connection = NWConnection(to: endpoint, using: .tcp)

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    // Connection established -- extract the resolved IP
                    if let resolvedEndpoint = connection.currentPath?.remoteEndpoint,
                       let hostPort = self.extractHostPort(from: resolvedEndpoint) {
                        let host = DiscoveredHost(
                            id: id,
                            name: name,
                            host: hostPort.host,
                            port: hostPort.port,
                            endpoint: endpoint
                        )
                        if !self.discoveredHosts.contains(where: { $0.id == id }) {
                            self.discoveredHosts.append(host)
                        }
                    }
                    // Close the resolution connection
                    connection.cancel()
                    self.connections.removeValue(forKey: id)

                case .failed, .cancelled:
                    self.connections.removeValue(forKey: id)

                default:
                    break
                }
            }
        }

        connections[id] = connection
        connection.start(queue: .main)
    }

    // MARK: - Helpers

    private func endpointId(_ endpoint: NWEndpoint) -> String {
        "\(endpoint)"
    }

    private func serviceName(from endpoint: NWEndpoint) -> String {
        if case .service(let name, _, _, _) = endpoint {
            return name
        }
        return "Shellspace"
    }

    private func extractHostPort(from endpoint: NWEndpoint) -> (host: String, port: Int)? {
        if case .hostPort(let host, let port) = endpoint {
            let hostString: String
            switch host {
            case .ipv4(let addr):
                hostString = "\(addr)"
            case .ipv6(let addr):
                let str = "\(addr)"
                // Prefer IPv4-mapped addresses for compatibility
                if str.hasPrefix("::ffff:") {
                    hostString = String(str.dropFirst(7))
                } else {
                    hostString = str
                }
            case .name(let name, _):
                hostString = name
            @unknown default:
                return nil
            }
            return (hostString, Int(port.rawValue))
        }
        return nil
    }
}
