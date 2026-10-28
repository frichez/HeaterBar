import Darwin
import Foundation

/// Finds Philips devices by asking every address on the Mac's local networks
/// for `/sys/dev/info`. Blocking; call it off the main thread.
enum HeaterDiscovery {
    struct Device {
        let host: String
        let deviceID: String
        let name: String
        let model: String
    }

    static func scan(listenFor timeout: TimeInterval = 3) -> [Device] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        let request = CoAPMessage.request(CoAPMessage.get, path: "sys/dev/info", messageID: 1, token: [0x48, 0x42])
            .encoded()
        for host in candidateHosts() {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(5683).bigEndian
            address.sin_addr.s_addr = host.bigEndian
            _ = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, request, request.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            usleep(1_000)  // A burst of hundreds of datagrams can overrun the send buffer.
        }

        var wait = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var found: [String: Device] = [:]
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLength)
                }
            }
            guard count > 0, let message = CoAPMessage(Array(buffer[0..<count])),
                  let info = try? JSONSerialization.jsonObject(with: Data(message.payload)) as? [String: Any],
                  let deviceID = info["device_id"] as? String else { continue }
            let host = String(cString: inet_ntoa(from.sin_addr))
            found[deviceID] = Device(host: host, deviceID: deviceID,
                                     name: info["name"] as? String ?? host,
                                     model: info["modelid"] as? String ?? "")
        }
        return Array(found.values)
    }

    /// Every other address on each IPv4 network this Mac is on, limited to
    /// home-sized networks (/22 or smaller).
    private static func candidateHosts() -> [UInt32] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var hosts = Set<UInt32>()
        var cursor = list
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let netmask = entry.ifa_netmask else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            guard mask >= 0xFFFF_FC00, mask != 0xFFFF_FFFF, ip >> 16 != 0xA9FE else { continue }
            let network = ip & mask
            for host in (network + 1)..<(network | ~mask) where host != ip {
                hosts.insert(host)
            }
        }
        return Array(hosts)
    }
}
