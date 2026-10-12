// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 性能レビュー (#1744 の子) の G5Plumbing 群: #2378 / #2382 / #2383 の、いまの費用の大きさを測る下書き。
// 置き場の予定は perf/PerfDrafts/G5Plumbing.swift (worktree のガードが書き込みを止めたので、ここへ置いた)。
//
// **前後比較ではない。** 58eea05c の実装のまま、場面ごとの所要・syscalls・page fault を出す。
// 出力は 1 行 1 値で `PERF\t<Issue>\t<場面>\t<指標>\t<値>\t<単位>`。`grep ^PERF` で集める。
//
// 走らせ方 (後の段で 1 本ずつ):
//   swift test -c release -Xswiftc -enable-testing --filter "PerfReviewG5Plumbing"
// **--filter を必ず付ける。** Swift Testing は別の Suite を同じプロセスで並行に走らせるので、
// 他の Suite が同時に走ると時間も task 全体の syscalls / fault の数も汚れる。
//
// GPU を使うのは #2378 の 1 本だけ (`representativeFrameSplit`)。ほかは GPU も窓も使わない。

import Darwin
import Foundation
import Metal
import Testing
import os

@testable import MokumeCore

// MARK: - 計測の道具

private func perf(_ issue: Int, _ scene: String, _ metric: String, _ value: Double, _ unit: String) {
    print("PERF\t\(issue)\t\(scene)\t\(metric)\t\(String(format: "%.4f", value))\t\(unit)")
}

extension Duration {
    fileprivate var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }
}

/// 標本を溜めて、中央値・p90・最小を出す。
private struct Samples {
    private(set) var values: [Double] = []

    mutating func add(_ value: Double) { values.append(value) }

    func quantile(_ q: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        return sorted[Int((Double(sorted.count - 1) * q).rounded())]
    }

    var median: Double { quantile(0.5) }
    var p90: Double { quantile(0.9) }
    var minimum: Double { values.min() ?? .nan }

    /// `scale` を掛けて `unit` で出す (秒 → µs なら 1e6)。
    func emit(_ issue: Int, _ scene: String, _ metric: String, scale: Double = 1, unit: String) {
        perf(issue, scene, "\(metric).median", median * scale, unit)
        perf(issue, scene, "\(metric).p90", p90 * scale, unit)
        perf(issue, scene, "\(metric).min", minimum * scale, unit)
    }
}

/// task 全体の出来事の累計 (`TASK_EVENTS_INFO`)。
///
/// **数えるのは task 全体である** — 測っている糸のほかに、Swift Testing・GCD・Metal の糸の分も
/// 入る。だから 1 回ではなく中央値で読み、`--filter` で他の Suite を止めて走らせる。
private struct TaskEvents {
    var syscallsUnix = 0
    var syscallsMach = 0
    var faults = 0
    var contextSwitches = 0

    static func now() -> TaskEvents {
        var info = task_events_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_events_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_EVENTS_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return TaskEvents() }
        return TaskEvents(
            syscallsUnix: Int(info.syscalls_unix), syscallsMach: Int(info.syscalls_mach),
            faults: Int(info.faults), contextSwitches: Int(info.csw))
    }

    static func - (lhs: TaskEvents, rhs: TaskEvents) -> TaskEvents {
        TaskEvents(
            syscallsUnix: lhs.syscallsUnix - rhs.syscallsUnix,
            syscallsMach: lhs.syscallsMach - rhs.syscallsMach,
            faults: lhs.faults - rhs.faults,
            contextSwitches: lhs.contextSwitches - rhs.contextSwitches)
    }
}

/// 最適化で消されないように値を飲み込む。
@inline(never)
private func blackHole<T>(_ value: T) {
    withExtendedLifetime(value) {}
}

/// 1 回ぶんの所要と出来事。
private struct Run {
    var seconds: Double
    var events: TaskEvents
}

/// 暖機してから測る。`setup` と `teardown` は時間に入れない。
private func measureRuns<State>(
    warmup: Int = 3, runs: Int = 20,
    setup: () throws -> State,
    body: (inout State) throws -> Void,
    teardown: (State) -> Void = { _ in }
) rethrows -> [Run] {
    var result: [Run] = []
    for round in 0..<(warmup + runs) {
        var state = try setup()
        let before = TaskEvents.now()
        let started = ContinuousClock.now
        try body(&state)
        let elapsed = ContinuousClock.now - started
        let after = TaskEvents.now()
        teardown(state)
        if round >= warmup { result.append(Run(seconds: elapsed.seconds, events: after - before)) }
    }
    return result
}

private func emitRuns(
    _ runs: [Run], _ issue: Int, _ scene: String, _ metric: String,
    perItem items: Int = 1, scale: Double = 1e6, unit: String = "us"
) {
    var time = Samples()
    var unix = Samples()
    var mach = Samples()
    var faults = Samples()
    for run in runs {
        time.add(run.seconds / Double(items))
        unix.add(Double(run.events.syscallsUnix) / Double(items))
        mach.add(Double(run.events.syscallsMach) / Double(items))
        faults.add(Double(run.events.faults) / Double(items))
    }
    time.emit(issue, scene, metric, scale: scale, unit: unit)
    perf(issue, scene, "\(metric).syscallsUnix.median", unix.median, "count")
    perf(issue, scene, "\(metric).syscallsMach.median", mach.median, "count")
    perf(issue, scene, "\(metric).faults.median", faults.median, "count")
}

private func makeScratch(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mokume-perf-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

// MARK: - Suite

@Suite("PerfReview G5Plumbing", .serialized)
@MainActor
struct PerfReviewG5Plumbing {

    // MARK: #2383 入力管と外部の受け口

    /// 道具が書く行と同じもの (`InputEvent.wireLine`)。mouseMoved の 1 行は約 40 バイト。
    private static func wireBlob(lines count: Int) -> Data {
        var text = ""
        text.reserveCapacity(count * 48)
        for index in 0..<count {
            let x = Float(index % 960) + 0.25
            let y = Float(index % 540) + 0.5
            text += InputEvent.mouseMoved(x: x, y: y).wireLine
        }
        return Data(text.utf8)
    }

    /// 管が空の刻み。`pollStopSignal()` (takeDeparture) と `collectInput()` (drain) で
    /// 1 刻みに 2 回 `readAvailable()` が走り、そのたびに 4 KB を 0 で埋めて確保し、
    /// `read` が EAGAIN で返る。窓を持つ道具に起こされた子の、入力が無いときの定常費用。
    @Test("#2383 管が空の刻みごとの読みの費用")
    func stdinIdleTick() throws {
        var descriptors: [Int32] = [0, 0]
        try #require(pipe(&descriptors) == 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        let reader = StandardInputEvents(descriptor: descriptors[0])
        let state = InputState()
        let ticks = 1000
        let runs = measureRuns(runs: 20, setup: { () }) { _ in
            for _ in 0..<ticks {
                _ = reader.takeDeparture()
                reader.drain(into: state)
            }
        }
        #expect(!reader.isClosed)
        #expect(reader.accepted == 0)
        emitRuns(runs, 2383, "idle-tick", "takeDeparture+drain", perItem: ticks, scale: 1e9, unit: "ns")
    }

    /// 1 フレームに `lines` 行が溜まっていた場面。
    ///
    /// **読み口は一時ファイル。** 管は 64 KB で詰まり、書く側が非閉塞だと溢れたぶんは捨てられる
    /// (`WatchSession.send`) ので、約 1,500 行を越える量は管では作れない。ファイルなら EOF まで
    /// 4 KB ずつ読めて、読む側の手順 (`readAvailable` の 4 KB の読み) は管と同じになる。EOF で
    /// `isClosed` が立つので、`takeDeparture()` が読みの段だけ、続く `drain(into:)` が行を切って
    /// 解いて合流点へ入れる段だけになる。
    ///
    /// 10,000 行は、管では 1 刻みに溜まらないが**取りに来ない間は `takeDeparture()` だけが読み進める**
    /// 場面 (録りを閉じている間・外から `pause()` している間・`pendingLimit` 1 MB まで溜まる)
    /// の上限側を表す。InputState の上限 4096 を越えるので `removeFirst()` の写しも入る。
    @Test("#2383 1 フレームに溜まった行を引き取る所要", arguments: [10, 100, 1_000, 10_000])
    func stdinBurst(lines: Int) throws {
        let scratch = try makeScratch("stdin")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("input.ndjson")
        let blob = Self.wireBlob(lines: lines)
        try blob.write(to: file)
        perf(2383, "burst-\(lines)", "bytes", Double(blob.count), "B")

        struct Opened {
            let descriptor: Int32
            let reader: StandardInputEvents
            let state: InputState
        }
        func openFile() throws -> Opened {
            let descriptor = Darwin.open(file.path, O_RDONLY)
            try #require(descriptor >= 0)
            return Opened(
                descriptor: descriptor, reader: StandardInputEvents(descriptor: descriptor),
                state: InputState())
        }

        // 読みの段だけ (4 KB ずつ read して pending へ足す)
        let reading = try measureRuns(runs: 15, setup: openFile) { opened in
            _ = opened.reader.takeDeparture()
        } teardown: { close($0.descriptor) }
        emitRuns(reading, 2383, "burst-\(lines)", "read", unit: "us")

        // 行を切る・解く・合流点へ入れる段 (読みは済ませてから測る)
        var accepted = 0
        let splitting = try measureRuns(
            runs: 15,
            setup: { () throws -> Opened in
                let opened = try openFile()
                _ = opened.reader.takeDeparture()
                return opened
            }
        ) { opened in
            opened.reader.drain(into: opened.state)
            accepted = opened.reader.accepted
        } teardown: { close($0.descriptor) }
        #expect(accepted == lines)
        emitRuns(splitting, 2383, "burst-\(lines)", "drain", unit: "us")
        emitRuns(splitting, 2383, "burst-\(lines)", "drain.perLine", perItem: lines, scale: 1e9, unit: "ns")
    }

    /// `drain` の内訳。行ごとの decoder・残りの写し・合流点の上限を分けて見る。
    ///
    /// (iii) は `takeLine()` (private) と同じ形を検査の中に書き写したもので、(iv) は写さずに
    /// 添字で進めたときの下限 (参照)。どちらも製品の経路ではない。
    @Test("#2383 drain の内訳", arguments: [100, 1_000, 10_000])
    func stdinComponents(lines: Int) throws {
        let blob = Self.wireBlob(lines: lines)
        let split = blob.split(separator: UInt8(ascii: "\n")).map { Data($0) }
        let scene = "parts-\(lines)"

        // (i) いまの形: 行ごとに JSONDecoder を作る
        let freshDecoder = measureRuns(runs: 15, setup: { () }) { _ in
            for line in split {
                blackHole(try? JSONDecoder().decode(RawInputEvent.self, from: line))
            }
        }
        emitRuns(freshDecoder, 2383, scene, "decode.freshDecoder.perLine", perItem: lines, scale: 1e9, unit: "ns")

        // (ii) decoder を使い回したとき
        let decoder = JSONDecoder()
        let sharedDecoder = measureRuns(runs: 15, setup: { () }) { _ in
            for line in split {
                blackHole(try? decoder.decode(RawInputEvent.self, from: line))
            }
        }
        emitRuns(sharedDecoder, 2383, scene, "decode.sharedDecoder.perLine", perItem: lines, scale: 1e9, unit: "ns")

        // (iii) いまの切り方の写し: 行を取るたびに残りを丸ごと写す
        let copying = measureRuns(runs: 15, setup: { blob }) { pending in
            var total = 0
            while let index = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(pending[pending.startIndex..<index])
                pending = Data(pending[pending.index(after: index)...])
                total &+= line.count
            }
            blackHole(total)
        }
        emitRuns(copying, 2383, scene, "split.copyRest", unit: "us")

        // (iv) 参照: 写さずに添字で進める下限
        let indexing = measureRuns(runs: 15, setup: { blob }) { pending in
            var total = 0
            var start = pending.startIndex
            while let index = pending[start...].firstIndex(of: UInt8(ascii: "\n")) {
                total &+= pending[start..<index].count
                start = pending.index(after: index)
            }
            blackHole(total)
        }
        emitRuns(indexing, 2383, scene, "split.indexOnly", unit: "us")

        // (v) 合流点へ入れる段だけ (上限 4096 を越えると removeFirst が先頭を詰め直す)
        let events = (0..<lines).map { InputEvent.mouseMoved(x: Float($0 % 960), y: Float($0 % 540)) }
        let enqueue = measureRuns(runs: 15, setup: { InputState() }) { state in
            for event in events { state.enqueue(event) }
        }
        emitRuns(enqueue, 2383, scene, "inputState.enqueue", unit: "us")
    }

    /// 外部の受け口 (OSC・TextPort) の 1 フレーム。届いた `count` 件を `send` で入れ、
    /// フレームの頭で `take()` が全部取る。
    ///
    /// **`take()` の所要は、そのまま送り手の糸を塞ぐ時間である。** 連結 (`ring[head...] +
    /// ring[..<head]`)・`.map`・`removeAll()` (中身の解放を含む) は全部 `withLock` の中で走る。
    /// 値は 15 バイトを越える String にして、OSCMessage と同じく参照を数える値にする。
    @Test("#2383 外部の受け口の 1 フレーム", arguments: [100, 1_000, 4_096, 10_000])
    func externalQueueFrame(count: Int) throws {
        let queue = ExternalQueue<String>(
            name: "perf", state: .running, capacity: 4096, warn: { _ in }, now: { 0 })
        let messages = (0..<count).map { "/mokume/fader/\($0 % 16)/value \(Float($0) * 0.001)" }
        let scene = "queue-\(count)"

        // 送る側 (OS のコールバックの糸に当たる)。容量を毎フレーム捨てるので、毎回 0 から育つ
        var lastTaken = 0
        let sends = measureRuns(runs: 20, setup: { () }) { _ in
            for message in messages { queue.send(message, hostTime: 1) }
        } teardown: { _ in
            lastTaken = queue.take().count
        }
        #expect(lastTaken == min(count, 4096))
        emitRuns(sends, 2383, scene, "send.perMessage", perItem: count, scale: 1e9, unit: "ns")

        // 取る側 (main・錠を握っている時間)
        let takes = measureRuns(
            runs: 20,
            setup: { for message in messages { queue.send(message, hostTime: 1) } }
        ) { _ in
            blackHole(queue.take())
        }
        emitRuns(takes, 2383, scene, "take", unit: "us")
    }

    // MARK: #2382 @Param を毎フレーム書く

    /// つまみ 4 つ (ParameterExchangeTests.Knobbed と同じ数 + 動かす `phase`)。
    final class FourKnobs: Sketch {
        @Param(0...200) var radius: Double = 80
        @Param(1...8) var count: Int = 3
        @Param var spinning: Bool = true
        @Param var phase: Double = 0
    }

    /// つまみ 13 個 (Sketches/KnobsAndValues.swift と同じ型の並び)。
    final class ThirteenKnobs: Sketch {
        @Param(1...12) var columns: Int = 6
        @Param(1...10) var rows: Int = 4
        @Param(4...140) var size: Double = 56
        @Param(-2...2) var spin: Double = 0.35
        @Param var phase: Double = 0
        @Param(0...8, name: "weight") var outlineWeight: Float = 2
        @Param var filled: Bool = true
        @Param(choices: ["circle", "square", "triangle"]) var shape: String = "square"
        @Param var tint: LinearRGBA = LinearRGBA(straightRed: 0.98, green: 0.62, blue: 0.24, alpha: 1)
        @Param(-1...1) var drift: SIMD2<Float> = SIMD2(0, 0)
        @Param(0...80) var backdrop: SIMD3<Float> = SIMD3(18, 20, 28)
        @Param(name: "caption") var captionText: String = "knobs and values"
        @Param var seed: Int = 7
    }

    /// つまみの数に応じたスケッチと、`draw()` の中で値を 1 つ進める操作・同じ値を書き直す操作。
    private static func knobbed(_ knobs: Int) -> (
        sketch: any Sketch, animate: () -> Void, rewriteSame: () -> Void
    ) {
        if knobs == 4 {
            let sketch = FourKnobs()
            return (sketch, { sketch.phase += 0.01 }, { sketch.radius = sketch.radius })
        }
        let sketch = ThirteenKnobs()
        return (sketch, { sketch.phase += 0.01 }, { sketch.size = sketch.size })
    }

    /// `draw()` の中で @Param を 1 つ進めるスケッチを `mokume watch` の下で走らせた 1 フレームの、
    /// 区画の側の費用 (`collectInput()` の `params?.drain()`)。
    @Test("#2382 値を毎フレーム書くときの、応答 1 回の所要と syscalls", arguments: [4, 13])
    func paramPublishPerFrame(knobs: Int) throws {
        let facet = try makeScratch("params")
        defer { try? FileManager.default.removeItem(at: facet) }
        let (sketch, animate, _) = Self.knobbed(knobs)
        let registry = ParamRegistry(of: sketch)
        let surface = ParamSurface(directory: facet, registry: registry)
        surface.start()
        let first = surface.revision ?? 0

        var published = 0
        let runs = measureRuns(runs: 30, setup: { animate() }) { _ in
            if surface.drain() != nil { published += 1 }
        }
        // 毎フレーム書き直している (暖機の 3 回を含む)
        #expect(published == 33)
        #expect(surface.revision == first + 33)
        let scene = "publish-\(knobs)knobs"
        emitRuns(runs, 2382, scene, "drain", unit: "us")
        let report = WorkDirectory.reportURL(under: facet)
        let size = (try? FileManager.default.attributesOfItem(atPath: report.path)[.size] as? Int) ?? -1
        perf(2382, scene, "reportBytes", Double(size), "B")

        // 値が変わらないフレーム: 要求の lstat 1 回だけのはず
        let idle = measureRuns(runs: 30, setup: { () }) { _ in
            blackHole(surface.drain())
        }
        emitRuns(idle, 2382, scene, "drain.unchanged", scale: 1e9, unit: "ns")
    }

    /// **同じ値を書き直しても応答を書き直す。** ParamBox の setter は等しさを見ずに知らせる
    /// (`ParamBox.swift` の説明・@Observable の展開と同じ)。`size = min(size, 100)` のように
    /// 値を保つ書き方も毎フレームの公開になる。
    @Test("#2382 同じ値を毎フレーム書き直すときも公開する", arguments: [13])
    func paramRewriteSameValue(knobs: Int) throws {
        let facet = try makeScratch("params-same")
        defer { try? FileManager.default.removeItem(at: facet) }
        let (sketch, _, rewriteSame) = Self.knobbed(knobs)
        let surface = ParamSurface(directory: facet, registry: ParamRegistry(of: sketch))
        surface.start()
        var published = 0
        let runs = measureRuns(runs: 30, setup: { rewriteSame() }) { _ in
            if surface.drain() != nil { published += 1 }
        }
        #expect(published == 33)
        perf(2382, "rewrite-same-\(knobs)knobs", "publishedFrames", Double(published), "of33")
        emitRuns(runs, 2382, "rewrite-same-\(knobs)knobs", "drain", unit: "us")
    }

    /// 公開 1 回の内訳と、道具の側・保存の側の 1 フレーム。
    @Test("#2382 公開の内訳・道具の読み直し・保存の刻み", arguments: [4, 13])
    func paramPublishParts(knobs: Int) throws {
        let facet = try makeScratch("params-parts")
        defer { try? FileManager.default.removeItem(at: facet) }
        let (sketch, animate, _) = Self.knobbed(knobs)
        let registry = ParamRegistry(of: sketch)
        let scene = "parts-\(knobs)knobs"

        // (a) 宣言を組む (publish と、見張りの張り直しで 1 回ずつ・保存の張り直しでもう 1 回)
        let declare = measureRuns(runs: 30, setup: { () }) { _ in
            blackHole(registry.declarations)
        }
        emitRuns(declare, 2382, scene, "declarations", scale: 1e9, unit: "ns")

        // (b) JSON に組む (AtomicFile.writeJSON と同じ設定。encoder も毎回作る)
        let report = ParamReport(
            revision: 1, id: nil, params: registry.declarations, rejected: [], clamped: [],
            discarded: [])
        var encoded = Data()
        let encode = try measureRuns(runs: 30, setup: { () }) { _ in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
            encoded = try encoder.encode(report)
        }
        emitRuns(encode, 2382, scene, "encode.prettySorted", unit: "us")
        perf(2382, scene, "encodedBytes", Double(encoded.count), "B")

        // (b') 参照: 整形も並べ替えもしない、使い回しの encoder
        let plainEncoder = JSONEncoder()
        let plain = try measureRuns(runs: 30, setup: { () }) { _ in
            blackHole(try plainEncoder.encode(report))
        }
        emitRuns(plain, 2382, scene, "encode.plainReused", unit: "us")

        // (c) 原子的に置く (ディレクトリの作成・一時ファイル・差し替え)
        let target = facet.appendingPathComponent("report.json")
        let place = try measureRuns(runs: 30, setup: { () }) { _ in
            try AtomicFile.write(encoded, to: target)
        }
        emitRuns(place, 2382, scene, "atomicWrite", unit: "us")

        // (d) 道具の側: 応答が変わるたびに lstat + 読み + decode (`RemoteParams.refresh`)
        let surface = ParamSurface(directory: facet, registry: registry)
        surface.start()
        let remote = RemoteParams(directory: facet)
        remote.refresh()
        let reread = measureRuns(
            runs: 30,
            setup: {
                animate()
                surface.drain()
            }
        ) { _ in
            remote.refresh()
        }
        emitRuns(reread, 2382, scene, "tool.refresh.changed", unit: "us")
        let toolIdle = measureRuns(runs: 30, setup: { () }) { _ in
            remote.refresh()
        }
        emitRuns(toolIdle, 2382, scene, "tool.refresh.unchanged", scale: 1e9, unit: "ns")

        // (e) 比較: 保存の側は動いている間は書かない (30 フレーム静まるまで待つ)
        let saved = facet.appendingPathComponent("state/params.json")
        let store = try #require(ParamStore.makeIfNeeded(for: registry, at: saved))
        // **見張りは restore() が張る** (SketchRuntime と同じ順)。張らないと tick() は変化に
        // 気付かず即座に返り、0 ns を測ってしまう (下書きの 1 回目がそうだった)
        store.restore()
        let tick = measureRuns(runs: 30, setup: { animate() }) { _ in
            store.tick()
        }
        // 動いている間は書かない
        #expect(!FileManager.default.fileExists(atPath: saved.path))
        emitRuns(tick, 2382, scene, "store.tick", scale: 1e9, unit: "ns")
        // 静まれば 30 刻みで書く (tick が変化を見ていたことの裏付け。時間は測らない)
        for _ in 0..<ParamStore.quietFrames { store.tick() }
        #expect(FileManager.default.fileExists(atPath: saved.path))
    }

    // MARK: #2378 いま測れるもの

    /// signpost の区間を 1 フレームに 3 つ (draw / flush / present) 張ったときの費用。
    /// Instruments が付いていない状態の値 (完了条件 2 の代償の見積もり)。
    @Test("#2378 OSSignposter の区間の費用 (記録していないとき)")
    func signposterOverhead() {
        let signposter = OSSignposter(subsystem: "dev.mokume.perf-review", category: "frame")
        let frames = 10_000
        let runs = measureRuns(runs: 20, setup: { () }) { _ in
            for _ in 0..<frames {
                let draw = signposter.beginInterval("draw", id: signposter.makeSignpostID())
                signposter.endInterval("draw", draw)
                let flush = signposter.beginInterval("flush", id: signposter.makeSignpostID())
                signposter.endInterval("flush", flush)
                let present = signposter.beginInterval("present", id: signposter.makeSignpostID())
                signposter.endInterval("present", present)
            }
        }
        perf(2378, "signposter", "isEnabled", signposter.isEnabled ? 1 : 0, "bool")
        emitRuns(runs, 2378, "signposter", "threeIntervalsPerFrame", perItem: frames, scale: 1e9, unit: "ns")
    }

    /// 最大メモリは新しい仕掛けなしで読める (`task_vm_info.ledger_phys_footprint_peak`)。
    /// 観測の `memoryMB` (`RuntimeLoad.physicalFootprintMB`) はいまの値で、最大ではない。
    @Test("#2378 いまの足跡と最大の足跡を読む費用")
    func footprintPeak() {
        func read() -> (current: UInt64, peak: UInt64)? {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            return (info.phys_footprint, UInt64(info.ledger_phys_footprint_peak))
        }
        let reads = 1000
        let runs = measureRuns(runs: 20, setup: { () }) { _ in
            for _ in 0..<reads { blackHole(read()) }
        }
        if let sample = read() {
            perf(2378, "footprint", "currentMB", Double(sample.current) / 1_048_576, "MB")
            perf(2378, "footprint", "peakMB", Double(sample.peak) / 1_048_576, "MB")
        }
        emitRuns(runs, 2378, "footprint", "taskVMInfo", perItem: reads, scale: 1e9, unit: "ns")
    }

    /// いまの口だけで 1 フレームを分けて測る: CPU の組み立て (`draw` が返るまで) と、
    /// GPU の決着まで (`settle`)。GPU 時間の口が無いので、差は「GPU + 待ちの機構」であって
    /// GPU の実行時間そのものではない。計数 (`drawCallsInLastFrame` ほか) も並べる。
    @Test(
        "#2378 代表的な 1 フレームを、いまの口だけで分けて測る",
        .enabled(if: RenderDevice.isAvailable, "GPU が無い"))
    func representativeFrameSplit() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 960, height: 540)
        func scene() {
            canvas.background(LinearRGBA.linear(red: 0.08, green: 0.09, blue: 0.11))
            for index in 0..<2000 {
                canvas.fill(LinearRGBA.linear(red: 0.4, green: 0.85, blue: 1))
                canvas.circle(Float(index % 50) * 19 + 10, Float(index / 50) * 13 + 10, 12)
            }
        }
        let cpu = try measureRuns(runs: 20, setup: { try gpu.settle() }) { _ in
            try canvas.draw { scene() }
        }
        let wall = try measureRuns(runs: 20, setup: { try gpu.settle() }) { _ in
            try canvas.draw { scene() }
            try gpu.settle()
        }
        emitRuns(cpu, 2378, "circles-2000", "cpuUntilDrawReturns", scale: 1e3, unit: "ms")
        emitRuns(wall, 2378, "circles-2000", "wallUntilSettled", scale: 1e3, unit: "ms")
        perf(2378, "circles-2000", "drawCallsInLastFrame", Double(canvas.drawCallsInLastFrame), "count")
        perf(2378, "circles-2000", "drawsEncodedInLastFrame", Double(canvas.drawsEncodedInLastFrame), "count")
        perf(2378, "circles-2000", "flatVerticesInLastFrame", Double(canvas.flatVerticesInLastFrame), "count")
        perf(2378, "circles-2000", "slotWaits", Double(gpu.slotWaits), "count")
        perf(2378, "circles-2000", "blockingWaits", Double(gpu.blockingWaits), "count")
        perf(2378, "circles-2000", "ringWaits", Double(gpu.ringWaits), "count")
    }
}
