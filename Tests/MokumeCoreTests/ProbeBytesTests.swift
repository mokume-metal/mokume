// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeProbe

/// 読み込みの口へ壊した入力を渡す道具 (``ProbeBytes``・``Guarded``) の自己の検査 (#3220)。GPU を使わない。
///
/// 道具が誤ると、壊した入力の検査は「壊した」と名乗りながら見本のまま渡すか、止まる入力を待ち続ける。
/// ここでは、壊し方が座標どおりに効くこと・同じ座標なら同じ入力になること・止まる本体を期限で切り離すことを見る。
@Suite("壊した入力を作る道具は、座標どおりに壊し、止まる本体を期限で切り離す")
nonisolated struct ProbeBytesTests {
    static let sample = Array(#"{"a": 12, "b": [3, 45]}"#.utf8)

    @Test("1 バイトの反転・切り詰め・NUL の挿入・桁の巨大化が、それぞれ座標の位置に効く")
    func eachKindActsAtItsPosition() {
        let sample = Self.sample
        // 反転: ちょうど 1 バイトだけが違う (量が半分未満なら 1 bit、以上なら 8 bit)
        for amount in [0.1, 0.9] {
            let flipped = ProbeBytes.mutate(sample, .flip, at: 0.5, amount: amount)
            let differing = zip(sample, flipped).filter { $0 != $1 }
            #expect(flipped.count == sample.count && differing.count == 1)
            #expect(differing.first.map { ($0 ^ $1).nonzeroBitCount } == (amount < 0.5 ? 1 : 8))
        }
        // 切り詰め: 位置が残す割合で、必ず 1 バイト以上を落とす
        #expect(ProbeBytes.mutate(sample, .truncate, at: 0.5, amount: 0) == Array(sample.prefix(sample.count / 2)))
        #expect(ProbeBytes.mutate(sample, .truncate, at: 0, amount: 0).isEmpty)
        #expect(ProbeBytes.mutate(sample, .truncate, at: 0.999, amount: 0).count < sample.count)
        // NUL: ちょうど 1 つ増える
        let nul = ProbeBytes.mutate(sample, .insertNUL, at: 0.3, amount: 0)
        #expect(nul.count == sample.count + 1 && nul.filter { $0 == 0 }.count == 1)
        // 桁: 位置に近い数字の並びが、量に応じた桁数の 9 になる (3〜400)
        let small = String(decoding: ProbeBytes.mutate(sample, .bigNumber, at: 0.3, amount: 0), as: UTF8.self)
        #expect(small.contains(#""a": 999,"#), "\(small)")
        let large = ProbeBytes.mutate(sample, .bigNumber, at: 0.3, amount: 0.999)
        #expect(large.count > 390)
        // 数字が無い見本には挿す
        let bare = ProbeBytes.mutate(Array("abc".utf8), .bigNumber, at: 0.5, amount: 0)
        #expect(String(decoding: bare, as: UTF8.self).contains("999"))
        // 空の見本でも落ちない
        for kind in ProbeBytes.Kind.allCases { _ = ProbeBytes.mutate([], kind, at: 0.5, amount: 0.5) }
    }

    @Test("座標が同じなら同じ入力になり、座標は見本・種類を範囲の中で動かす")
    func sameAxesSameBytes() {
        let samples = [Self.sample, Array("<a/>".utf8)]
        let axes = ProbeBytes.axes(samples: samples.count)
        #expect(axes.map(\.name) == ["sample", "kind", "at", "amount"])
        let input = ProbeInput(axes: axes, values: [1, 2, 0.5, 0.5])
        #expect(ProbeBytes.mutate(samples, input) == ProbeBytes.mutate(samples, input))
        #expect(ProbeBytes.mutate(samples, input) == ProbeBytes.mutate(samples[1], .insertNUL, at: 0.5, amount: 0.5))
        // 種類を縮める先は切り詰めで、残る入力が最も短い側へ寄る
        #expect(axes[1].simplest == Double(ProbeBytes.Kind.truncate.rawValue))
    }

    @Test("生成した入力は case の seed を持ち、縮めた入力も同じ seed を名乗る (落ちる入力を落ちる前に名乗るため)")
    func inputsCarryTheirSeed() {
        let axes = ProbeBytes.axes(samples: 2)
        let input = ProbeInput(axes: axes, seed: 0x5EED)
        #expect(input.seedText == "seed=0x5eed")
        #expect(input.replacing(2, with: 0).seedText == "seed=0x5eed")
        #expect(ProbeInput(axes: axes, values: [0, 0, 0, 0]).seedText.isEmpty)
    }

    @Test("入力の表記は、大きさと頭の一部を、制御文字を逃がして示す")
    func describeEscapes() {
        #expect(ProbeBytes.describe(Array("a\n\u{0}\u{7F}\u{FF}".utf8) + [0xFF]) == #"入力 (7 バイト) "a\n\x00\x7F\xC3\xBF\xFF""#)
        #expect(ProbeBytes.describe([UInt8](repeating: 0x41, count: 150), limit: 10).hasSuffix("AAAAAAAAAA…\""))
    }

    @Test("止まる本体は期限で切り離して nil を返し、返る本体はその結果を返す")
    func guardedCutsAStuckBody() {
        let start = Date()
        let stuck: Int? = Guarded.run("止まる", limit: 0.3) {
            Thread.sleep(forTimeInterval: 3)
            return 1
        }
        #expect(stuck == nil)
        #expect(Date().timeIntervalSince(start) < 2, "期限を越えても待ち続けた")
        #expect(Guarded.run("返る", limit: 5) { 42 } == 42)
    }
}
