// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 折れ目の形の式 (``Canvas/joinRim(toward:_:half:join:)``) の数値 ([#1644])。GPU を要さない。
/// 描いた絵で見る検査は `PolylineJoinTests` にある。
///
/// [#1644]: https://github.com/mokume-metal/mokume/issues/1644
@Suite("折れ目の形の式")
struct JoinRimTests {
    /// 同じ向きへ折り返す角では cos が −1 になる。丸めで −1 を越えると平方根が数でなく
    /// なっていた (整数の向き 1640 通りのうち 296 通り)。
    @Test("同じ向きへ折り返す角でも、どの向きでも数でない点を返さず、帯を同じ長さだけ延ばす", arguments: [StrokeJoin.miter, .bevel])
    func foldsNeverProduceNaN(_ join: StrokeJoin) {
        var broken: [SIMD2<Int>] = []
        var reaches: [Float] = []
        for x in 1...40 {
            for y in 0...40 {
                let length = Float(x * x + y * y).squareRoot()
                let direction = SIMD2(Float(x) / length, Float(y) / length)
                let rim = Canvas.joinRim(toward: direction, direction, half: 10, join: join)
                guard rim.count == 5, !rim.contains(where: { !$0.x.isFinite || !$0.y.isFinite })
                else {
                    broken.append(SIMD2(x, y))
                    continue
                }
                // 切り口 (周の 3 つ目) が、帯の先へどれだけ延びたか
                reaches.append(-simd_dot(rim[2], direction))
            }
        }
        #expect(broken.isEmpty, "\(broken.count) 通り: \(broken.prefix(5))")
        // 長さ 1 の向きどうしの cos は −1 の手前 (丸めの 1 目盛り) にも落ち、半角の余弦
        // √((1 + cos) / 2) がそこで 10⁻⁴ ほどになる。延びる長さはその分だけ (太さの半分 10 に
        // 対して 0.003 画素まで) 短くなる。形は角度に連続なので、出っ張りが出たり消えたりは
        // しない。見るのは、それより大きく飛ばないこと
        let reach: Float = join == .miter ? 10 * Float(2).squareRoot() : 10
        let off = reaches.filter { abs($0 - reach) > 0.01 }
        #expect(off.isEmpty, "\(off.count) 通りが \(reach) からずれる: \(off.prefix(5))")
    }
}
