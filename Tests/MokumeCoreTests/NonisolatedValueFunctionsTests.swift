// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Dispatch
import Foundation
import MokumeDiagnostics
import Synchronization
import Testing

@testable import MokumeCore

/// 子のタスクへ渡せる、数えるだけの箱 (`Mutex` は複製できず、局所変数のまま渡すと 6.3 が競合を疑う)。
private final class Counter: Sendable {
    let count = Mutex(0)
}

/// 値だけを扱う数と色の関数は、`nonisolated` の文脈から呼べて、main で呼んだのと同じ値を返す
/// ([#2389](https://github.com/mokume-metal/mokume/issues/2389))。
///
/// このモジュールは既定で main actor に隔離される (ADR-0010 決定 1) ので、`concurrentPerform` や
/// TaskGroup の中からは、**隔離を外した口だけが呼べる**。外していなければ、ここに書いた呼び出しは
/// `call to main actor-isolated global function 'map' in a synchronous nonisolated context` で
/// コンパイルできない — つまりこのファイルが組めること自体が、条件 1 の検査になる。
@Suite("数と色の関数は nonisolated の文脈から呼べる")
struct NonisolatedValueFunctionsTests {
    /// 全部の口を 1 回ずつ呼んだ結果。**`nonisolated`** なので、main の外からも呼べる。
    nonisolated static func sample() -> [Float] {
        var out: [Float] = []
        out.append(map(0.5, 0, 1, 0, 10))
        out.append(lerp(0, 10, 0.5))
        out.append(constrain(12, 0, 10))
        out.append(norm(5, 0, 10))
        out.append(smoothstep(0, 1, 0.5))
        out.append(radians(180))
        out.append(degrees(Float.pi))
        out.append(damp(0, 10, 4, 0.016))
        out.append(pingpong(7, 5))
        out.append(lerpAngle(0.1, 6.2, 0.5))
        out.append(dist(0, 0, 3, 4))
        out.append(mag(3, 4))
        out.append(sq(3))
        out.append(fract(2.75))
        out.append(mod(-1, 3))
        out.append(PI + HALF_PI + QUARTER_PI + TWO_PI + TAU)

        func read(_ c: LinearRGBA) {
            out += [red(c), green(c), blue(c), alpha(c), hue(c), saturation(c), brightness(c)]
        }
        read(color(255, 0, 0))
        read(color(128))
        read(color(0, 64))
        read(color(hex: 0xFF8800))
        read(color(hue: 120, saturation: 0.5, brightness: 0.8))
        read(color(color(10, 20, 30), 100))
        read(lerpColor(color(255, 0, 0), color(0, 0, 255), 0.25))
        read(paletteLerp([(color(255, 0, 0), 0), (color(0, 255, 0), 0.5), (color(0, 0, 255), 1)], 0.75))
        read(LinearRGBA.display(red: 0.5, green: 0.25, blue: 0.75, alpha: 1))
        out.append(bezierPoint(0, 10, 10, 0, 0.5))
        // 作業空間から表示形式へ移す出口 (#2389 の反証)。戻す道も同じ型にある
        let pixels = PixelBuffer(
            width: 2, height: 1, components: [0.5, 0.25, 0.75, 1, 0.1, 0.2, 0.3, 0.5])
        let encoded = OutputStage.encode(pixels)
        out += encoded.bytes.map(Float.init)
        out += OutputStage.encode(pixels, brightness: Brightness(exposure: 2, toneMapping: .roll))
            .bytes.map(Float.init)
        out += OutputStage.decode(encoded).flatMap { [Float($0.x), Float($0.y), Float($0.z), Float($0.w)] }
        return out
    }

    private func same(_ a: [Float], _ b: [Float]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern || ($0.isNaN && $1.isNaN) }
    }

    @Test("main の外から呼んでも、main で呼んだのと同じ値を返す")
    func valuesMatchTheMainActor() {
        let onMain = Self.sample()
        let results = Mutex<[[Float]]>([])
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let values = Self.sample()
            results.withLock { $0.append(values) }
        }
        let all = results.withLock { $0 }
        #expect(all.count == 8)
        #expect(!onMain.isEmpty && onMain.contains { $0 != 0 })
        for values in all {
            #expect(same(values, onMain), "main の値と違う: \(values) / \(onMain)")
        }
    }

    /// 完了条件 2: 複数のスレッドから同時に言っても、落ちず、注意は**ちょうど 1 度**出る。
    ///
    /// 控えの型を直に使う。検査どうしで共有する本物の控えだと、先に別の検査が同じ鍵を鳴らしていれば
    /// 並列の呼び出しが無くても緑になるので、この検査だけの控えと溜め場で数える。
    @Test("複数のスレッドから同じ注意を同時に言っても、文面はちょうど 1 度だけ組まれ、1 度だけ出る")
    func warningsAreSaidExactlyOnceAcrossThreads() async {
        let log = SharedWarningLog<Int>()
        let built = Counter()
        let digest = WarningDigest()
        await Diagnostics.$digest.withValue(digest) {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<400 {
                    group.addTask {
                        log.warnOnce(1, { built.count.withLock { $0 += 1 }; return "concurrent warning once" }())
                        log.warnOnce(2, { built.count.withLock { $0 += 1 }; return "concurrent warning twice" }())
                    }
                }
            }
        }
        let said = digest.takeUnreported().sorted()
        #expect(said == ["concurrent warning once", "concurrent warning twice"], "\(said)")
        // 文面は言う回にだけ、鍵ごとに 1 度組む (@autoclosure)
        let counted = built.count.withLock { $0 }
        #expect(counted == 2, "文面を組んだ回数: \(counted)")
        #expect(log.snapshot.message(for: 1) == "concurrent warning once")
        #expect(log.snapshot.count { _ in true } == 2)
    }

    /// 本物の口を並べて呼ぶと、標準エラーの 1 行は口ごとにちょうど 1 度。プロセスの控えは検査どうしで
    /// 共有するので、まっさらな控えを持つ子のプロセスで言わせて数える。
    @Test("本物の口を並べて呼んでも、標準エラーの注意は口ごとにちょうど 1 度だけ出る")
    func realMouthsSayOncePerMouthAcrossThreads() async throws {
        let result = await #expect(processExitsWith: .success, observing: [\.standardErrorContent]) {
            DispatchQueue.concurrentPerform(iterations: 256) { _ in
                _ = map(Float.nan, 0, 1, 0, 1)
                _ = color(Float.nan, 0, 0)
                _ = color(10, 20, 30, 999)
                _ = lerpColor(color(0), color(255), Float.nan)
                _ = lerpColor(color(0), color(255), 7)
                _ = paletteLerp([(color(255, 0, 0), 0), (color(0, 0, 255), 1)], 7)
                _ = mod(1, 0)
            }
        }
        guard let result else { return }
        let errors = String(decoding: result.standardErrorContent, as: UTF8.self)
        let lines = errors.split(separator: "\n").map(String.init)
        for prefix in ["map()", "color()", "lerpColor()", "paletteLerp()", "mod()"] {
            let mine = lines.filter { $0.contains(prefix) }
            // color() は数でない値と不透明度の外の 2 種類、lerpColor() も同じく 2 種類を言う
            let expected = (prefix == "color()" || prefix == "lerpColor()") ? 2 : 1
            #expect(mine.count == expected, "\(prefix): \(mine.count) 行 (\(expected) 行のはず)\n\(errors)")
        }
    }

    /// 文面の中から同じ控えの口を呼んでも、錠の再入で止まらない。
    @Test("文面の組み立てで同じ控えの口を呼んでも、止まらない")
    func buildingAMessageMayCallTheSameLog() {
        let log = SharedWarningLog<Int>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            log.warnOnce(1, { log.warnOnce(2, "inner"); return "outer" }())
            done.signal()
        }
        // 止まったときは、錠を持ったままの控えを読むと検査ごと止まるので、読まずに赤にする
        guard done.wait(timeout: .now() + 10) == .success else {
            Issue.record("文面の中から同じ控えを呼んで止まった")
            return
        }
        #expect(log.snapshot.message(for: 1) == "outer" && log.snapshot.message(for: 2) == "inner")
    }

    /// 文面を組んでいる間 (標準エラーが詰まった間も同じ) も、言い終えた鍵を言う回は止まらない。
    @Test("ある鍵の文面を組んでいる間も、別の鍵の言い終えた回は待たされない")
    func aSlowMessageDoesNotStallTheOthers() {
        let log = SharedWarningLog<Int>()
        log.warnOnce(2, "already said")
        let building = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let slow = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            log.warnOnce(
                1,
                {
                    building.signal()
                    _ = release.wait(timeout: .now() + 20)
                    return "slow"
                }())
            slow.signal()
        }
        #expect(building.wait(timeout: .now() + 10) == .success)
        let quick = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for _ in 0..<1000 { log.warnOnce(2, "already said") }
            // 初めての鍵も、遅い文面の完了を待たずに言える
            log.warnOnce(3, "third")
            quick.signal()
        }
        let progressed = quick.wait(timeout: .now() + 10) == .success
        release.signal()
        _ = slow.wait(timeout: .now() + 10)
        #expect(progressed, "遅い文面を組んでいる間、ほかの回が待たされた")
        #expect(log.snapshot.message(for: 1) == "slow" && log.snapshot.message(for: 3) == "third")
    }

    /// 完了条件 5 の形: 全画素を `map`→`color` で埋めるループを、ライブラリの口のまま分けて回せる。
    /// 分けて回した結果が、1 本で回した結果と全画素で一致する。
    @Test("全画素を map と color で埋めるループを分けて回しても、1 本で回したのと一致する")
    func aSplitLoopMatchesTheSerialOne() {
        let width = 192
        let height = 108
        @Sendable nonisolated func pixel(_ x: Int, _ y: Int) -> Float {
            let c = color(map(x, 0, width, 0, 255), map(y, 0, height, 255, 0), 64)
            return red(c) + 2 * green(c) + 4 * blue(c)
        }
        var serial = [Float](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { serial[y * width + x] = pixel(x, y) } }
        let rows = Mutex([Float](repeating: -1, count: width * height))
        DispatchQueue.concurrentPerform(iterations: height) { y in
            var line = [Float](repeating: 0, count: width)
            for x in 0..<width { line[x] = pixel(x, y) }
            rows.withLock { all in
                for x in 0..<width { all[y * width + x] = line[x] }
            }
        }
        let split = rows.withLock { $0 }
        #expect(serial.contains { $0 > 0 })
        #expect(same(split, serial))
    }
}
