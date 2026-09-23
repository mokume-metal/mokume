// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 読み出した画素 (``PixelBuffer``) の検査。値を直に組むので GPU を要さない。
@Suite("読み出した画素")
struct PixelBufferTests {
    /// 幅と高さを違えた小さな画素。縦横を取り違えると範囲の判定がずれる。
    ///
    /// `nonisolated` なのは、検査の引数の並びが隔離の外で組まれるため。
    private nonisolated static let width = 3
    private nonisolated static let height = 2

    /// 位置ごとに違う**不透明な**色。透明で埋めると、範囲の外で内側の値を返しても
    /// 透明と区別が付かず、検査が何も見なくなる。成分は半精度で正確に表せる値にする。
    private static func color(_ x: Int, _ y: Int) -> LinearRGBA {
        LinearRGBA(premultipliedRed: Float(x) / 4, green: Float(y) / 4, blue: 0.5, alpha: 1)
    }

    private static func makeBuffer() -> PixelBuffer {
        var components: [Float16] = []
        for y in 0..<height {
            for x in 0..<width {
                let color = color(x, y)
                components += [color.red, color.green, color.blue, color.alpha].map(Float16.init)
            }
        }
        return PixelBuffer(width: width, height: height, components: components)
    }

    /// 完了条件「範囲の外で読んでも落ちず、透明が返る」(#1436)。
    ///
    /// 4 辺のすぐ外に加えて、掛け算で溢れる大きさの位置も読む — 範囲を見る前に
    /// 置き場の位置を計算すると、そこで落ちる。
    @Test("範囲の外を読んでも落ちず、透明が返る", arguments: [
        (-1, 0), (width, 0), (0, -1), (0, height),
        (width, height), (Int.min, 0), (0, Int.max), (Int.max, Int.max),
    ])
    func readingOutsideReturnsTransparent(_ position: (Int, Int)) {
        let buffer = Self.makeBuffer()
        #expect(buffer[position.0, position.1] == .transparent)
    }

    /// 範囲の端の内側は、入れた値がそのまま返る (範囲の判定が 1 つ内側へずれていない)。
    @Test("範囲の内側の四隅は、入れた値がそのまま返る")
    func cornersInsideReturnWhatWasStored() {
        let buffer = Self.makeBuffer()
        for (x, y) in [(0, 0), (Self.width - 1, 0), (0, Self.height - 1),
                       (Self.width - 1, Self.height - 1)] {
            #expect(buffer[x, y] == Self.color(x, y), "(\(x), \(y))")
        }
    }
}
