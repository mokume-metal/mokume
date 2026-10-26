// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 拡大した字形を焼く枠 (``GlyphAtlas/admitScaledBake(_:bytes:frame:deferrable:)``) の判定が、先送りした字形の
/// 全件を走って数える素朴な実装と、どんな順序でも一致すること (#3255)。
///
/// 判定は「自分より長く先送りした字形の分」を除いた残りを使う。かつては先送りの全件を毎回走って数えていた
/// が、いまは先送りの長さ (age) ごとの累積の表から引く。**表は判定の途中で字形が消えるたびに合わせる** —
/// 先送りした字形は `admitScaledBake` で焼けても、`noteBaked` で別の道から焼けても、フレームの途中で消える。
/// 消すのを挟む順で一致することを、種を決めた乱数の操作の列で突き合わせる。GPU を要する (置き場を作る)。
@Suite(
    "拡大した字形の焼く枠は、先送りの全件を走る素朴な判定と一致する",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct GlyphAtlasOwedBudgetTests {
    private func key(_ glyph: Int, step: Int = 0) -> GlyphAtlas.Key {
        GlyphAtlas.Key(fontKey: "owed", size: 12, style: .normal, glyph: UInt16(glyph), step: step)
    }

    /// 全件を走る素朴な判定 (変える前の実装そのまま)。
    struct Naive {
        struct Owed {
            var bytes: Int
            var age: Int
        }
        var perFrame: Int
        var bytesPerFrame: Int
        var budgetFrame = -1
        var bakesThisFrame = 0
        var bytesThisFrame = 0
        var last: [GlyphAtlas.Key: Owed] = [:]
        var this: [GlyphAtlas.Key: Owed] = [:]

        mutating func open(frame: Int) {
            guard budgetFrame != frame else { return }
            budgetFrame = frame
            bakesThisFrame = 0
            bytesThisFrame = 0
            last = this
            this = [:]
        }

        mutating func admit(_ key: GlyphAtlas.Key, bytes: Int, frame: Int, deferrable: Bool) -> Bool {
            open(frame: frame)
            var identity = key
            identity.step = 0
            let age = last[identity]?.age ?? 0
            var allowed = true
            if deferrable {
                var count = 0
                var reserved = 0
                for (other, owed) in last where other != identity && owed.age > age {
                    count += 1
                    reserved += owed.bytes
                }
                let countFits = bakesThisFrame + count < perFrame
                let first = bytesThisFrame == 0 && reserved == 0
                let bytesFit = first || bytesThisFrame + bytes + reserved <= bytesPerFrame
                allowed = countFits && bytesFit
            }
            guard allowed else {
                this[identity] = Owed(bytes: bytes, age: age + 1)
                return false
            }
            bakesThisFrame += 1
            bytesThisFrame += bytes
            last.removeValue(forKey: identity)
            return true
        }

        mutating func noteBaked(_ key: GlyphAtlas.Key, frame: Int) {
            guard !last.isEmpty || !this.isEmpty else { return }
            open(frame: frame)
            var identity = key
            identity.step = 0
            last.removeValue(forKey: identity)
            this.removeValue(forKey: identity)
        }

        var count: Int { last.count + this.count }
    }

    /// 種を決めた乱数 (SplitMix64)。
    struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Int(z % UInt64(bound))
        }
    }

    @Test(
        "どんな操作の順でも、判定と先送りの数が素朴な判定と一致する",
        arguments: [
            (seed: UInt64(1), glyphs: 6, perFrame: 2, bytesPerFrame: 4000),
            (seed: UInt64(2), glyphs: 12, perFrame: 3, bytesPerFrame: 3000),
            (seed: UInt64(3), glyphs: 24, perFrame: 5, bytesPerFrame: 9000),
            (seed: UInt64(4), glyphs: 40, perFrame: 1, bytesPerFrame: 2500),
            (seed: UInt64(5), glyphs: 9, perFrame: 64, bytesPerFrame: 500),
        ])
    func matchesTheNaiveScan(seed: UInt64, glyphs: Int, perFrame: Int, bytesPerFrame: Int) throws {
        let atlas = try GlyphAtlas(gpu: RenderDevice())
        atlas.mayDeferScaledBakes = true
        atlas.scaledBakesPerFrame = perFrame
        atlas.scaledBakeBytesPerFrame = bytesPerFrame
        var naive = Naive(perFrame: perFrame, bytesPerFrame: bytesPerFrame)
        var random = Generator(state: seed)
        var frame = 0
        var refusals = 0
        var removals = 0
        for operation in 0..<4000 {
            switch random.next(10) {
            case 0:
                frame += 1  // 次のフレームへ(先送りが「前のフレームの」履歴になる)
            case 1, 2:
                // 別の道で焼けた/決まった字形: 先送りの履歴から外す(フレームの途中で消える)
                let k = key(random.next(glyphs), step: random.next(4))
                atlas.noteBaked(k, frame: frame)
                naive.noteBaked(k, frame: frame)
                removals += 1
            default:
                let k = key(random.next(glyphs), step: random.next(4))
                let bytes = 200 + random.next(1800)
                let deferrable = random.next(8) != 0
                let expected = naive.admit(k, bytes: bytes, frame: frame, deferrable: deferrable)
                let actual = atlas.admitScaledBake(k, bytes: bytes, frame: frame, deferrable: deferrable)
                #expect(actual == expected, "seed \(seed) 操作 \(operation): 判定が違う")
                if !expected { refusals += 1 }
            }
            #expect(atlas.owedGlyphCount == naive.count, "seed \(seed) 操作 \(operation): 先送りの数が違う")
            if atlas.owedGlyphCount != naive.count { return }
        }
        // 検査の前提: 先送りが何周も続き、消すのを挟んでいる(判定が枠に当たらない列では何も見ていない)
        #expect(refusals > 100, "枠に当たった回数が少ない: \(refusals)")
        #expect(removals > 100)
    }
}
