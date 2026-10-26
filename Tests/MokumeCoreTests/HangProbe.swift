// 使い捨ての診断 (コミットしない・#3263 の専用機でだけ赤になる検査の切り分け用)。
// 協調プールが生きているかを、main を塞いだまま 1 本の Task.detached が走れるかで見る。

import AppKit
import Darwin
import Foundation
import ObjectiveC

nonisolated enum HangProbe {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var reports = 0

    private static func say(_ text: String) {
        FileHandle.standardError.write(Data(("PROBE " + text + "\n").utf8))
    }

    // MARK: - NSAnimation の呼び出し元と窓のアニメーション停止 (#3286 の診断 3)

    private nonisolated(unsafe) static var installed = false
    private nonisolated(unsafe) static var seenCallers = Set<String>()
    private nonisolated(unsafe) static var animationCount = 0

    /// 検査のプロセスの早い所で 1 度だけ呼ぶ (何度呼んでもよい)。
    /// (b) 窓のアニメーションを止める。(a) 止めた後に `NSAnimation` が始まれば、その呼び出し元を書く。
    static func install() {
        lock.lock()
        let first = !installed
        installed = true
        lock.unlock()
        guard first else { return }

        // 比べるための逃げ道: HANG_PROBE_KEEP_ANIMATIONS=1 なら止めず、呼び出し元の記録だけ取る。
        let keep = ProcessInfo.processInfo.environment["HANG_PROBE_KEEP_ANIMATIONS"] == "1"
        if !keep { UserDefaults.standard.set(false, forKey: "NSAutomaticWindowAnimationsEnabled") }
        // 作った窓ごとの animationBehavior = .none の代わりに、読み出しを .none に固定する
        // (窓は SketchApplication・WindowPlacement・検査自身が作るので、作る所は 1 つに絞れない)。
        var swizzled: [String] = []
        if !keep, let method = class_getInstanceMethod(NSWindow.self, NSSelectorFromString("animationBehavior")) {
            let block: @convention(block) (AnyObject) -> Int = { _ in NSWindow.AnimationBehavior.none.rawValue }
            method_setImplementation(method, imp_implementationWithBlock(block))
            swizzled.append("-[NSWindow animationBehavior]->none")
        }
        for name in ["startAnimation", "_runBlocking"] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(NSAnimation.self, selector) else { continue }
            let original = method_getImplementation(method)
            let block: @convention(block) (AnyObject) -> Void = { object in
                animationStarted(name, object)
                typealias Function = @convention(c) (AnyObject, Selector) -> Void
                unsafeBitCast(original, to: Function.self)(object, selector)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
            swizzled.append("-[NSAnimation \(name)]")
        }
        say(
            "animations-off \(keep ? "SKIPPED(keep)" : "NSAutomaticWindowAnimationsEnabled=false"); swizzled=\(swizzled.joined(separator: ", ")); "
                + "threads=\(threadCount())")
    }

    private static func animationStarted(_ name: String, _ object: AnyObject) {
        let symbols = Thread.callStackSymbols.dropFirst(2).prefix(15)
        let key = name + "|" + symbols.joined(separator: "\n")
        lock.lock()
        animationCount += 1
        let total = animationCount
        let isNew = seenCallers.insert(key).inserted
        lock.unlock()
        guard isNew else { return }
        let animation = object as? NSAnimation
        let mode = animation.map { "mode=\($0.animationBlockingMode.rawValue) duration=\($0.duration)" } ?? ""
        say(
            "animation #\(total) via \(name) \(type(of: object)) \(mode) threads=\(threadCount()) "
                + "thread=\(Thread.isMainThread ? "main" : "worker")\n" + symbols.joined(separator: "\n"))
    }

    /// `NSAnimation` の総数と、初めて見た呼び出し元の数を書く。
    static func summary() {
        lock.lock()
        let count = animationCount
        let callers = seenCallers.count
        lock.unlock()
        say("animation total=\(count) distinctCallers=\(callers) threads=\(threadCount())")
    }

    /// main を塞いだまま、プールの Task・グローバルキュー・別スレッドが走れるかを見る。
    static func canary(_ label: String) {
        install()
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
        install()
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
        summary()
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

/// テストバンドルが読み込まれた時点 (どの検査よりも前) に `HangProbe.install()` を呼び、
/// 終わるとき `NSAnimation` の総数を書く。
@section("__DATA,__mod_init_func")
@used
private let hangProbeConstructor: @convention(c) () -> Void = {
    HangProbe.install()
    atexit { HangProbe.summary() }
}
