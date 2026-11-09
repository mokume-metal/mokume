// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin

/// 別のプロセスについて、カーネルに尋ねて分かること (目録の掃除と、検査の置き場の判定が使う)。
nonisolated enum ProcessRecord {
    /// そのプロセスの起動の時刻 (1970 年からのマイクロ秒)。**居なければ `nil`。**
    ///
    /// pid は使い回されるので、pid だけでは「同じプロセスか」を言えない。起動の時刻を添えれば、
    /// 使い回された pid の別のプロセスと見分けられる ([ADR-0049] 決定 3)。
    ///
    /// [ADR-0049]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0049-share-frames-to-other-processes.md
    static func startTime(of pid: pid_t) -> Int64? {
        guard let info = kinfo(of: pid) else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec)
    }

    /// そのプロセスの親の pid。居なければ `nil`。
    static func parent(of pid: pid_t) -> pid_t? {
        kinfo(of: pid).map { $0.kp_eproc.e_ppid }
    }

    /// そのプロセスが居るか。**権限が無くて尋ねられないだけなら居るとみなす** (`EPERM`)。
    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// そのプロセスの起動の引数。読めなければ空。
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return []
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        // 先頭に argc、続いて実行ファイルのパス、0 の詰め物、引数が 0 区切りで並ぶ
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var strings: [String] = []
        var index = MemoryLayout<Int32>.size
        // 実行ファイルのパス
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        while index < size, strings.count < argc {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            strings.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return strings
    }

    private static func kinfo(of pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }
}
