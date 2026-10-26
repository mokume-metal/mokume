// 使い捨ての診断 (コミットしない・#3263 の専用機でだけ赤になる検査の切り分け用)。
// 協調プールが生きているかを、main を塞いだまま 1 本の Task.detached が走れるかで見る。

import Darwin
import Foundation

nonisolated enum HangProbe {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var reports = 0

    private static func say(_ text: String) {
        FileHandle.standardError.write(Data(("PROBE " + text + "\n").utf8))
    }

    /// main を塞いだまま、プールの Task・グローバルキュー・別スレッドが走れるかを見る。
    static func canary(_ label: String) {
        let started = DispatchTime.now()
        let task = DispatchSemaphore(value: 0)
        Task.detached { task.signal() }
        let taskOK = task.wait(timeout: .now() + 3) == .success
        let taskMs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6

        let queue = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { queue.signal() }
        let queueOK = queue.wait(timeout: .now() + 3) == .success

        say(
            "canary \(label): task=\(taskOK ? "ok" : "STALLED") (\(Int(taskMs)) ms) "
                + "globalQueue=\(queueOK ? "ok" : "STALLED") threads=\(threadCount())")
    }

    static func threadCount() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        task_threads(mach_task_self_, &list, &count)
        if let list {
            vm_deallocate(
                mach_task_self_, vm_address_t(bitPattern: list),
                vm_size_t(count) * vm_size_t(MemoryLayout<thread_act_t>.size))
        }
        return Int(count)
    }

    /// `seconds` 後に、別スレッドで自分のスタックと機械の負荷を書き出す。**塞がれた main には頼らない。**
    static func arm(_ label: String, after seconds: Double = 5) {
        lock.lock()
        let allowed = reports < 4
        if allowed { reports += 1 }
        lock.unlock()
        guard allowed else { return }
        let thread = Thread {
            let override = ProcessInfo.processInfo.environment["HANG_PROBE_DELAY"].flatMap(Double.init)
            Thread.sleep(forTimeInterval: override ?? seconds)
            report(label)
        }
        thread.name = "hang-probe"
        thread.start()
    }

    private static func run(_ path: String, _ arguments: [String], limit: Int = 400) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "(\(path) を起こせない: \(error))" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.prefix(limit).joined(separator: "\n")
            + (lines.count > limit ? "\n… (\(lines.count - limit) 行省略)" : "")
    }

    private static func report(_ label: String) {
        say("===== hang report: \(label) (pid \(getpid())) =====")
        canary("\(label)/+report")
        say("--- uptime / load\n" + run("/usr/bin/uptime", []))
        say(
            "--- ps (CPU 上位)\n"
                + run("/bin/ps", ["-axo", "pid,ppid,%cpu,%mem,etime,state,comm", "-r"], limit: 25))
        say("--- vm_stat\n" + run("/usr/bin/vm_stat", [], limit: 30))
        say("--- memory_pressure\n" + run("/usr/bin/memory_pressure", [], limit: 12))
        let file = NSTemporaryDirectory() + "hang-probe-\(label.replacingOccurrences(of: "/", with: "-")).txt"
        say("--- sample 自分 (1 秒)\n" + run("/usr/bin/sample", ["\(getpid())", "1", "-file", file], limit: 3))
        if let text = try? String(contentsOfFile: file, encoding: .utf8) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            say("--- sample の本文 (\(lines.count) 行)\n" + lines.prefix(900).joined(separator: "\n"))
        } else {
            say("--- sample の本文が読めない: \(file)")
        }
        say("===== end hang report: \(label) =====")
    }
}
