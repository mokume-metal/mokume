// 使い捨ての計測 (#1813)。マージしない。release で走らせ、結果を .build/cost-probe/ のファイルと標準出力へ書く。
import Darwin
import Foundation
import Testing

@testable import MokumeCore

private let scratch = FileManager.default.currentDirectoryPath + "/.build/cost-probe"

private func note(_ line: String) {
    let label = ProcessInfo.processInfo.environment["COST_LABEL"] ?? "unlabelled"
    try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    print("[cost-probe \(label)] \(line)")
    let path = "\(scratch)/cost-\(label).txt"
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }
}

private func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

private func cpuMs() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let user = Double(usage.ru_utime.tv_sec) * 1000 + Double(usage.ru_utime.tv_usec) / 1000
    let system = Double(usage.ru_stime.tv_sec) * 1000 + Double(usage.ru_stime.tv_usec) / 1000
    return user + system
}

private func scramble(_ value: UInt64) -> UInt64 {
    var z = value &+ 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
}

private enum Kind: String, CaseIterable {
    case solid = "一色"
    case gradientRandomAlpha = "勾配+alpha乱数"
    case noiseAlpha255 = "RGB乱数+alpha255"
    case noiseAll = "RGBA乱数(専用回路は断る)"
    case noiseSlopingAlpha = "RGB乱数+alpha=x+y(専用回路は断る)"
}

private func make(_ kind: Kind, _ width: Int, _ height: Int) -> DisplayImage {
    let count = width * height * 4
    let bytes = [UInt8](unsafeUninitializedCapacity: count) { buffer, filled in
        for y in 0..<height {
            for x in 0..<width {
                let pixel = y * width + x
                let random = scramble(UInt64(pixel) &+ 1813)
                let at = pixel * 4
                switch kind {
                case .solid:
                    buffer[at] = 200; buffer[at + 1] = 120; buffer[at + 2] = 60; buffer[at + 3] = 255
                case .gradientRandomAlpha:
                    buffer[at] = UInt8(truncatingIfNeeded: x * 255 / width)
                    buffer[at + 1] = UInt8(truncatingIfNeeded: y * 255 / height)
                    buffer[at + 2] = UInt8(truncatingIfNeeded: (x + y) * 255 / (width + height))
                    buffer[at + 3] = UInt8(truncatingIfNeeded: random >> 24)
                case .noiseAlpha255:
                    buffer[at] = UInt8(truncatingIfNeeded: random)
                    buffer[at + 1] = UInt8(truncatingIfNeeded: random >> 8)
                    buffer[at + 2] = UInt8(truncatingIfNeeded: random >> 16)
                    buffer[at + 3] = 255
                case .noiseAll:
                    for c in 0..<4 { buffer[at + c] = UInt8(truncatingIfNeeded: random >> UInt64(c * 8)) }
                case .noiseSlopingAlpha:
                    buffer[at] = UInt8(truncatingIfNeeded: random)
                    buffer[at + 1] = UInt8(truncatingIfNeeded: random >> 8)
                    buffer[at + 2] = UInt8(truncatingIfNeeded: random >> 16)
                    buffer[at + 3] = UInt8(truncatingIfNeeded: x + y)
                }
            }
        }
        filled = count
    }
    return DisplayImage(width: width, height: height, bytes: bytes)
}


/// VTEncoderXPCService (符号化を請け負う別のプロセス) の CPU 時間を、動いている間に拾う。
/// 同じ機械の他のセッションの符号化も混ざりうる。
nonisolated final class ServiceCpuSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var first: [pid_t: Double] = [:]
    private var last: [pid_t: Double] = [:]
    private var running = true
    private var thread: Thread?
    private let done = DispatchSemaphore(value: 0)

    private static let scale: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e6
    }()

    private static func services() -> [(pid_t, Double)] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var found: [(pid_t, Double)] = []
        var path = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(max(0, filled))) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            guard String(cString: path).hasSuffix("VTEncoderXPCService") else { continue }
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard result == 0 else { continue }
            found.append((pid, Double(info.ri_user_time + info.ri_system_time) * scale))
        }
        return found
    }

    init() {
        // 走り出す前に居るものは、その時点の値を基準にする
        for (pid, cpu) in Self.services() { first[pid] = cpu; last[pid] = cpu }
        let thread = Thread { [self] in
            while true {
                lock.lock(); let go = running; lock.unlock()
                if !go { break }
                for (pid, cpu) in Self.services() {
                    lock.lock()
                    if first[pid] == nil { first[pid] = 0 }
                    last[pid] = cpu
                    lock.unlock()
                }
                usleep(15_000)
            }
            done.signal()
        }
        self.thread = thread
        thread.start()
    }

    /// 止めて、走っていた間に増えた CPU 時間 (ms) を返す。
    func stop() -> Double {
        lock.lock(); running = false; lock.unlock()
        done.wait()
        lock.lock(); defer { lock.unlock() }
        return last.reduce(0) { $0 + ($1.value - (first[$1.key] ?? 0)) }
    }
}

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

private func summarise(_ label: String, _ walls: [Double], _ cpus: [Double]) -> String {
    func f(_ v: Double) -> String { String(format: "%.0f", v) }
    return "\(label): wall min \(f(walls.min()!)) med \(f(median(walls))) max \(f(walls.max()!)) ms | cpu min \(f(cpus.min()!)) med \(f(median(cpus))) max \(f(cpus.max()!)) ms"
}

@Suite("cost probe 1813", .enabled(if: MovieFile.isAvailable))
struct CostProbe1813 {

    /// MovieFile を直に: 初期化〜finish の壁時間と CPU 時間。
    @Test("MovieFile 直")
    func direct() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cost-probe-direct")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("p.mov").path
        let frames = Int(ProcessInfo.processInfo.environment["COST_FRAMES"] ?? "40") ?? 40
        let reps = Int(ProcessInfo.processInfo.environment["COST_REPS"] ?? "5") ?? 5
        note("== direct: \(frames) frames, \(reps) reps")

        // 立ち上がりを 1 度捨てる
        do {
            let warm = make(.solid, 640, 360)
            let file = try MovieFile(path: path, width: 640, height: 360, frameRate: 60)
            for i in 0..<frames { try await file.append(warm, at: Double(i) / 60) }
            try await file.finish(lastFrameAt: Double(frames - 1) / 60)
        }

        for (width, height) in [(640, 360), (1920, 1080), (3840, 2160)] {
            for kind in Kind.allCases {
                let image = make(kind, width, height)
                var walls: [Double] = []
                var cpus: [Double] = []
                var failure: String?
                for _ in 0..<reps {
                    let cpu0 = cpuMs()
                    let t0 = nowMs()
                    do {
                        let file = try MovieFile(path: path, width: width, height: height, frameRate: 60)
                        for i in 0..<frames { try await file.append(image, at: Double(i) / 60) }
                        try await file.finish(lastFrameAt: Double(frames - 1) / 60)
                        walls.append(nowMs() - t0)
                        cpus.append(cpuMs() - cpu0)
                    } catch {
                        failure = "\(error)"
                        break
                    }
                }
                let label = "\(width)x\(height) \(kind.rawValue)"
                if let failure {
                    note("\(label): 断られた \(failure)")
                } else {
                    // 別のプロセス (VTEncoderXPCService) の CPU 時間。拾う側が CPU を食うので、上の測定とは別の回で拾う
                    var services: [Double] = []
                    for _ in 0..<3 {
                        let sampler = ServiceCpuSampler()
                        let file = try MovieFile(path: path, width: width, height: height, frameRate: 60)
                        for i in 0..<frames { try await file.append(image, at: Double(i) / 60) }
                        try await file.finish(lastFrameAt: Double(frames - 1) / 60)
                        services.append(sampler.stop())
                    }
                    note(
                        summarise(label, walls, cpus)
                            + String(format: " | xpc-service cpu med %.0f (min %.0f max %.0f) ms", median(services), services.min()!, services.max()!))
                }
            }
        }
    }

    /// MovieWriter に実時間 (60 fps) で送る: フレームの側が受ける遅れ。
    @Test("MovieWriter 実時間")
    func paced() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cost-probe-paced")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("p.mov").path
        let frames = Int(ProcessInfo.processInfo.environment["COST_PACED_FRAMES"] ?? "180") ?? 180
        let reps = 3
        note("== paced 60 fps: \(frames) frames, \(reps) reps")

        for (width, height) in [(1920, 1080), (3840, 2160)] {
            for kind in [Kind.solid, .gradientRandomAlpha, .noiseAlpha255] {
                let image = make(kind, width, height)
                var lateMax: [Double] = []
                var lateTotal: [Double] = []
                var writeMax: [Double] = []
                var cpus: [Double] = []
                var refused: String?
                for _ in 0..<reps {
                    let writer = MovieWriter(path: path, frameRate: 60)
                    let cpu0 = cpuMs()
                    let t0 = nowMs()
                    var maxLate = 0.0
                    var maxWrite = 0.0
                    for frame in 1...frames {
                        let target = t0 + Double(frame - 1) * 1000 / 60
                        while nowMs() < target { usleep(300) }
                        let start = nowMs()
                        maxLate = max(maxLate, start - target)
                        writer.write(image, frame: frame, time: Double(frame - 1) / 60)
                        maxWrite = max(maxWrite, nowMs() - start)
                    }
                    let sent = nowMs() - t0
                    writer.finish()
                    let cpu = cpuMs() - cpu0
                    if let failure = writer.takeFailure() { refused = failure }
                    lateMax.append(maxLate)
                    lateTotal.append(sent - Double(frames - 1) * 1000 / 60)
                    writeMax.append(maxWrite)
                    cpus.append(cpu)
                }
                func f(_ v: Double) -> String { String(format: "%.1f", v) }
                let label = "\(width)x\(height) \(kind.rawValue)"
                note(
                    "\(label): 最も遅れた枚 med \(f(median(lateMax))) ms (max \(f(lateMax.max()!))) | write() の最長 med \(f(median(writeMax))) ms (max \(f(writeMax.max()!))) | 送り終えた遅れの合計 med \(f(median(lateTotal))) ms | cpu(送り〜finish) med \(f(median(cpus))) ms"
                        + (refused.map { " | 断られた: \($0)" } ?? ""))
            }
        }
    }
}
