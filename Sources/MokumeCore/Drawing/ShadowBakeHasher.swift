// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 影の焼き付けの入力から 64 bit の指紋を取る。
///
/// **速さのために持つ。** 標準の `Hasher` は毎回種が変わるうえ 1 バイトずつ食わせる形で、
/// 頂点と置き場所 (数百 KB〜数 MB) を毎フレーム舐めると、省いた焼き付けより高くつく。
/// ここは 8 バイトずつ掛けて混ぜるだけの、フレームどうしを比べるためだけの指紋である
/// (暗号学的な強さは要らない — 比べる相手は自分の前のフレーム 1 つ)。
///
/// 混ぜ方は乗算と右シフトの xor (SplitMix64 の仕上げに近い形)。語の順序と長さの両方が
/// 効くので、同じ語を並べ替えたものも、末尾を切ったものも別の指紋になる。
///
/// バイト列は **4 本の独立した流れ**に分けて混ぜる。1 本だと語ごとの乗算が前の結果を
/// 待つ鎖になり、頂点 1.5 MB (球 detail 64) で 0.33 ms かかった (実測・4.5 GB/s)。4 本なら
/// 乗算が並んで走る。流れの畳み方は固定なので、同じ入力からは同じ指紋が出る。
struct ShadowBakeHasher {
    private var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    private var length: UInt64 = 0

    @inline(__always)
    private static func step(_ state: UInt64, _ word: UInt64) -> UInt64 {
        var next = (state ^ word) &* 0xFF51_AFD7_ED55_8CCD
        next ^= next >> 32
        return next
    }

    mutating func mix(_ word: UInt64) {
        state = Self.step(state, word)
        length &+= 1
    }

    /// バイト列を 8 バイトずつ食わせる。8 で割り切れない端は 0 で詰めて 1 語にする。
    mutating func mix(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress else { return }
        let words = bytes.count / 8
        var lanes = (
            state, state ^ 0x6A09_E667_F3BC_C909, state ^ 0xBB67_AE85_84CA_A73B,
            state ^ 0x3C6E_F372_FE94_F82B)
        var index = 0
        while index + 4 <= words {
            lanes.0 = Self.step(lanes.0, base.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self))
            lanes.1 = Self.step(lanes.1, base.loadUnaligned(fromByteOffset: index * 8 + 8, as: UInt64.self))
            lanes.2 = Self.step(lanes.2, base.loadUnaligned(fromByteOffset: index * 8 + 16, as: UInt64.self))
            lanes.3 = Self.step(lanes.3, base.loadUnaligned(fromByteOffset: index * 8 + 24, as: UInt64.self))
            index += 4
        }
        // 4 本を畳んでから、余りの語を 1 本で続ける
        state = Self.step(Self.step(Self.step(lanes.0, lanes.1), lanes.2), lanes.3)
        length &+= UInt64(index)
        while index < words {
            mix(base.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self))
            index += 1
        }
        let rest = bytes.count - words * 8
        if rest > 0 {
            var tail: UInt64 = 0
            for offset in 0..<rest {
                tail |= UInt64(base.load(fromByteOffset: words * 8 + offset, as: UInt8.self))
                    << (UInt64(offset) * 8)
            }
            mix(tail)
        }
    }

    func finish() -> UInt64 {
        var value = state ^ (length &* 0xC4CE_B9FE_1A85_EC53)
        value ^= value >> 33
        value &*= 0xFF51_AFD7_ED55_8CCD
        value ^= value >> 33
        return value
    }
}
