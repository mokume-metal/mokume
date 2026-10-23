// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Dispatch
import Foundation
import Synchronization
import Testing

@testable import MokumeCore

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

    /// 完了条件 2: 数でない値を、複数のスレッドから同時に渡しても落ちず、注意は 1 度だけ出る。
    @Test("複数のスレッドから数でない値を渡しても、落ちず、注意は 1 度だけ出る")
    func warningsAreSaidOnceAcrossThreads() {
        // 検査どうしで共有する控えを数えないよう、この検査だけの控えで文面の組み立てを数える
        let log = SharedWarningLog<Int>()
        let built = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            log.warnOnce(1, { built.withLock { $0 += 1 }; return "concurrent warning once" }())
            log.warnOnce(2, { built.withLock { $0 += 1 }; return "concurrent warning once (2)" }())
        }
        // 文面は言う回にだけ組む (@autoclosure)。1 度ずつだけ
        #expect(log.snapshot.hasWarned(1) && log.snapshot.hasWarned(2))
        #expect(log.snapshot.message(for: 1) == "concurrent warning once")
        #expect(log.snapshot.count { _ in true } == 2)
        #expect(built.withLock { $0 } == 2, "文面を言わない回にも組んだ: \(built.withLock { $0 })")
        // 本物の口も、並べて呼んで落ちず、控えに載る
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            _ = map(Float.nan, 0, 1, 0, 1)
            _ = color(Float.nan, 0, 0)
            _ = lerpColor(color(0), color(255), Float.nan)
        }
        #expect(NumberValues.warnings.hasWarned(.notANumber(.map)))
        #expect(ColorValues.warnings.hasWarned(.notANumber))
        #expect(ColorValues.warnings.hasWarned(.notANumberLerpColor))
    }

    /// 完了条件 5 の形: 全画素を `map`→`color` で埋めるループを、ライブラリの口のまま分けて回せる。
    /// 分けて回した結果が、1 本で回した結果と全画素で一致する。
    @Test("全画素を map と color で埋めるループを分けて回しても、1 本で回したのと一致する")
    func aSplitLoopMatchesTheSerialOne() {
        let width = 192
        let height = 108
        nonisolated func pixel(_ x: Int, _ y: Int) -> Float {
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
