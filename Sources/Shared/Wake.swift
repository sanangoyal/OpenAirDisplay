import Foundation
import Darwin

/// Ethernet-style MAC addresses of this Mac (en* interfaces), lowercase "aa:bb:cc:dd:ee:ff".
func macAddresses() -> [String] {
    var out: [String] = []
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0 else { return [] }
    var p = ifap
    while let a = p {
        defer { p = a.pointee.ifa_next }
        let name = String(cString: a.pointee.ifa_name)
        guard name.hasPrefix("en"), let sa = a.pointee.ifa_addr, Int32(sa.pointee.sa_family) == AF_LINK else { continue }
        sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
            guard Int(dl.pointee.sdl_alen) == 6 else { return }
            let off = Int(dl.pointee.sdl_nlen)
            let bytes: [UInt8] = withUnsafeBytes(of: dl.pointee.sdl_data) { Array($0[off..<(off + 6)]) }
            let s = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
            if s != "00:00:00:00:00:00", !out.contains(s) { out.append(s) }
        }
    }
    freeifaddrs(ifap)
    return out
}

/// Wake-on-LAN: broadcast a magic packet for each MAC on every wired/Thunderbolt/Wi-Fi interface. Returns packets sent.
@discardableResult
func sendMagicPackets(_ macs: [String]) -> Int {
    var packets: [[UInt8]] = []
    for m in macs {
        let b = m.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard b.count == 6 else { continue }
        packets.append([UInt8](repeating: 0xFF, count: 6) + Array((0..<16).map { _ in b }.joined()))
    }
    guard !packets.isEmpty else { return 0 }
    var sent = 0
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0 else { return 0 }
    var p = ifap
    while let a = p {
        defer { p = a.pointee.ifa_next }
        let name = String(cString: a.pointee.ifa_name)
        let fl = Int32(a.pointee.ifa_flags)
        guard (name.hasPrefix("en") || name.hasPrefix("bridge")), fl & IFF_UP != 0, fl & IFF_BROADCAST != 0, fl & IFF_LOOPBACK == 0,
              let sa = a.pointee.ifa_addr, Int32(sa.pointee.sa_family) == AF_INET else { continue }
        var targets: [sockaddr_in] = []
        if let d = a.pointee.ifa_dstaddr {   // subnet broadcast
            targets.append(d.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee })
        }
        var all = sockaddr_in(); all.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); all.sin_family = sa_family_t(AF_INET)
        all.sin_addr.s_addr = INADDR_BROADCAST.bigEndian
        targets.append(all)
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { continue }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var idx = if_nametoindex(name)
        setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size))
        for var t in targets {
            t.sin_port = UInt16(9).bigEndian
            for pk in packets {
                let n = withUnsafePointer(to: &t) { tp in
                    tp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, pk, pk.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                if n > 0 { sent += 1 }
            }
        }
        close(fd)
    }
    freeifaddrs(ifap)
    return sent
}
