import Darwin
import Foundation

/// Finds Sonos players on the local network via SSDP (the UPnP discovery
/// multicast). We send an `M-SEARCH` for `ZonePlayer` devices to
/// 239.255.255.250:1900 and collect the IPs from the `LOCATION` headers in the
/// unicast replies.
///
/// One responding player is enough — its ZoneGroupTopology lists every room on
/// the system with its IP — but we return all we hear from for resilience.
///
/// Blocking (BSD sockets); call it off the main thread.
enum SonosDiscovery {

    static func discover(timeout: TimeInterval = 2.0) -> [String] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        // Short per-recv timeout so the loop can re-check the overall deadline.
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var ttl: UInt8 = 4
        setsockopt(fd, Int32(IPPROTO_IP), IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &dest.sin_addr)

        let search = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 1\r
        ST: urn:schemas-upnp-org:device:ZonePlayer:1\r
        \r

        """
        let bytes = Array(search.utf8)

        // Send a few probes — multicast is lossy.
        for _ in 0..<3 {
            _ = withUnsafePointer(to: &dest) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bytes.withUnsafeBytes { raw in
                        sendto(fd, raw.baseAddress, bytes.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            usleep(100_000)
        }

        var found = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n > 0 {
                let text = String(decoding: buffer[0..<n], as: UTF8.self)
                if let ip = locationIP(in: text) { found.insert(ip) }
            }
        }
        return Array(found)
    }

    /// Pulls the host out of the `LOCATION: http://<ip>:1400/…` header.
    private static func locationIP(in response: String) -> String? {
        for rawLine in response.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            let line = rawLine.lowercased()
            guard line.hasPrefix("location:"), let scheme = rawLine.range(of: "http://") else { continue }
            let rest = rawLine[scheme.upperBound...]
            let host = rest.prefix { $0 != ":" && $0 != "/" }
            if !host.isEmpty { return String(host) }
        }
        return nil
    }

    // MARK: - Subnet scan fallback

    /// Scans the local /24 subnet(s) for Sonos players by probing `:1400`
    /// directly. More reliable than SSDP when multicast is filtered on Wi-Fi,
    /// and the unicast requests reliably trigger the macOS Local Network prompt.
    static func scanSubnets() async -> [String] {
        var found: [String] = []
        for prefix in localIPv4Prefixes() {
            let hosts = (1...254).map { "\(prefix).\($0)" }
            for batch in hosts.chunked(into: 64) {
                let hits = await withTaskGroup(of: String?.self) { group in
                    for host in batch {
                        group.addTask { await isSonos(ip: host) ? host : nil }
                    }
                    var out: [String] = []
                    for await hit in group { if let hit { out.append(hit) } }
                    return out
                }
                found.append(contentsOf: hits)
            }
        }
        return found
    }

    /// True if `ip:1400` serves a Sonos device description.
    static func isSonos(ip: String) async -> Bool {
        guard let url = URL(string: "http://\(ip):1400/xml/device_description.xml") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
        let body = String(decoding: data, as: UTF8.self)
        return body.contains("Sonos") || body.contains("ZonePlayer")
    }

    /// The `a.b.c` prefixes of this Mac's active IPv4 interfaces (assumes /24).
    private static func localIPv4Prefixes() -> [String] {
        var prefixes = Set<String>()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }

        var pointer = ifaddr
        while let p = pointer {
            defer { pointer = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard let addr = p.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254"), let dot = ip.range(of: ".", options: .backwards) else { continue }
            prefixes.insert(String(ip[..<dot.lowerBound]))
        }
        return Array(prefixes)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
