// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

/// スマホから届く、この Mac の LAN の IPv4 アドレス。
///
/// 起きているインターフェースのうち、ループバックとリンクローカル (`169.254.*`、DHCP が取れなかった口)
/// を除く。`en0` (内蔵の Wi-Fi・iPhone のテザリングもここ) を先に並べる — QR に載せるのは先頭の 1 つ。
nonisolated enum LANAddresses {
    /// インターフェースの名前とアドレス。
    struct Entry: Equatable {
        let interface: String
        let address: String
    }

    static func current() -> [String] {
        ordered(interfaces()).map(\.address)
    }

    /// 並べ方。`en0` を先に、それ以外は名前の順。同じアドレスは 1 度だけ。
    static func ordered(_ entries: [Entry]) -> [Entry] {
        var seen: Set<String> = []
        return entries
            .filter { !$0.address.hasPrefix("127.") && !$0.address.hasPrefix("169.254.") }
            .sorted { lhs, rhs in
                if (lhs.interface == "en0") != (rhs.interface == "en0") { return lhs.interface == "en0" }
                return lhs.interface < rhs.interface
            }
            .filter { seen.insert($0.address).inserted }
    }

    private static func interfaces() -> [Entry] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var entries: [Entry] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = pointer.pointee
            let flags = Int32(item.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                    NI_NUMERICHOST) == 0
            else { continue }
            let text = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            entries.append(Entry(interface: String(cString: item.ifa_name), address: text))
        }
        return entries
    }
}
