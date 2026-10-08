// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 値がビットまで同じ立体の頂点を、同じ頂点として数える ([#1947])。
///
/// 組み込みの形と、それを記録した保持した形は、三角形ごとに 3 点を持つ (添字を持たない)。球は
/// 1 つの点を 6 枚ほどの三角形が分け合うので、同じ値の頂点が 6 つほど並ぶ。**添字の列で描くなら、
/// 同じ値の頂点は同じ番号で指せる** (``SolidSweep``)。GPU は 1 回の描く呼び出しの中で、同じ番号の
/// 頂点の結果を使い回すので、頂点関数が走る数が減る。`sphere(3, detail: 12)` を保持した形にして
/// 10 万か所に置くと、GPU の時間 (1 フレーム) は、寄せずに写しを足しただけの添字の列で 13.3 ms、寄せて
/// 5.5 ms だった (置き場所ごとに 1 回で描く従来の描き方は 7.9 ms。release・Apple M 系の実測)。
///
/// **寄せるのは、全部の成分がビットまで同じ頂点だけ**である。頂点関数の出力は頂点の値だけで決まるので、
/// 寄せても絵は 1 ビットも変わらない。`-0` と `+0`・数でない値もビットで比べる (値として等しくても、
/// 別の頂点のままにする)。
///
/// **`SolidVertex` に成分を足したら、`key(of:)` にも足す。** 足し忘れると、足した成分だけが違う頂点が
/// 1 つに寄って絵が崩れる。`SolidSweepTests` の `theKeyCoversEveryStoredField` が成分の数を見張る。
///
/// [#1947]: https://github.com/mokume-metal/mokume/issues/1947
enum SolidVertexSharing {
    /// 頂点 1 つの全部の成分を、ビットのまま並べたもの。**ビットで比べる**ので、`-0` と `+0` は違う鍵になる。
    struct Key: Equatable {
        var a, b, c, d, e: SIMD4<UInt32>

        static func == (lhs: Key, rhs: Key) -> Bool {
            lhs.a == rhs.a && lhs.b == rhs.b && lhs.c == rhs.c && lhs.d == rhs.d && lhs.e == rhs.e
        }

        /// 鍵を 1 つの数にまぜる。成分ごとに別の奇数を掛けて足し、桁をかき混ぜる。
        var hash: Int {
            let sum =
                (a &* SIMD4(0x9E37_79B1, 0x85EB_CA77, 0xC2B2_AE3D, 0x27D4_EB2F))
                &+ (b &* SIMD4(0x1656_67B1, 0x9E37_79B9, 0x7F4A_7C15, 0x94D0_49BB))
                &+ (c &* SIMD4(0xBF58_476D, 0x1CE4_E5B9, 0x2545_F491, 0x4F6C_DD1D))
                &+ (d &* SIMD4(0xD6E8_FEB8, 0x6C8E_9CF5, 0x7FB5_D329, 0xA136_AAAD))
                &+ (e &* SIMD4(0x1B87_3593, 0xCC9E_2D51, 0xE654_6B65, 0x5BD1_E995))
            var mixed = UInt64(sum.wrappedSum())
            mixed = (mixed ^ (mixed >> 15)) &* 0x2C1B_3C6D
            mixed = mixed ^ (mixed >> 12)
            return Int(truncatingIfNeeded: mixed)
        }
    }

    /// 頂点 1 つの全部の成分の鍵。
    static func key(of vertex: SolidVertex) -> Key {
        func bits(_ x: Float, _ y: Float, _ z: Float, _ w: Float) -> SIMD4<UInt32> {
            SIMD4(x.bitPattern, y.bitPattern, z.bitPattern, w.bitPattern)
        }
        let position = vertex.position
        let shapePosition = vertex.shapePosition
        let normal = vertex.normal
        let shapeNormal = vertex.shapeNormal
        return Key(
            a: bits(position.x, position.y, position.z, shapePosition.x),
            b: bits(shapePosition.y, shapePosition.z, normal.x, normal.y),
            c: bits(normal.z, normal.w, shapeNormal.x, shapeNormal.y),
            d: bits(shapeNormal.z, vertex.uv.x, vertex.uv.y, vertex.stroke),
            e: bits(vertex.color.x, vertex.color.y, vertex.color.z, vertex.color.w))
    }

    /// 各頂点について、同じ値を持つ最初の頂点の番号 (`vertices` の先頭からの差) を返す。
    ///
    /// 同じ値が無い頂点は自分の番号を返す。頂点の数に比例する (開番地法の表を 1 つ作る)。
    static func firsts(of vertices: UnsafeBufferPointer<SolidVertex>) -> [UInt32] {
        let count = vertices.count
        var firsts = [UInt32](repeating: 0, count: count)
        guard count > 1 else { return firsts }
        var capacity = 16
        while capacity < count * 2 { capacity <<= 1 }
        let mask = capacity - 1
        var slots = [Int32](repeating: -1, count: capacity)
        var keys: [Key] = []
        keys.reserveCapacity(count)
        for number in 0..<count {
            let key = key(of: vertices[number])
            keys.append(key)
            var slot = key.hash & mask
            while true {
                let found = slots[slot]
                if found < 0 {
                    slots[slot] = Int32(number)
                    firsts[number] = UInt32(number)
                    break
                }
                if keys[Int(found)] == key {
                    firsts[number] = UInt32(found)
                    break
                }
                slot = (slot + 1) & mask
            }
        }
        return firsts
    }
}
