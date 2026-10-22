// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 名前の付いた色 (`Color.red` など・[#2595])。CSS 2.1 の 17 色を、CSS と同じ値で持つ。
///
/// 値は原色の移し替えを通した後の作業空間の値で、書き込んである (隔離の外から読めるように)。
/// **書き込んだ値が `color(r, g, b)` で作った色と 1 ビットも変わらない**ことを、17 色すべてで見る —
/// 原色の行列や転送関数を直したとき、書き込んだ値の側が古くなるのをここで捕まえる。
///
/// [#2595]: https://github.com/mokume-metal/mokume/issues/2595
@Suite("名前の付いた色")
struct NamedColorTests {
    /// CSS 2.1 の 17 色と、その sRGB の 0–255 の値 (CSS の仕様のとおり)。
    private static let css: [(name: String, color: Color, r: Int, g: Int, b: Int)] = [
        ("black", .black, 0, 0, 0), ("silver", .silver, 192, 192, 192),
        ("gray", .gray, 128, 128, 128), ("white", .white, 255, 255, 255),
        ("maroon", .maroon, 128, 0, 0), ("red", .red, 255, 0, 0),
        ("purple", .purple, 128, 0, 128), ("fuchsia", .fuchsia, 255, 0, 255),
        ("green", .green, 0, 128, 0), ("lime", .lime, 0, 255, 0),
        ("olive", .olive, 128, 128, 0), ("yellow", .yellow, 255, 255, 0),
        ("navy", .navy, 0, 0, 128), ("blue", .blue, 0, 0, 255),
        ("teal", .teal, 0, 128, 128), ("aqua", .aqua, 0, 255, 255),
        ("orange", .orange, 255, 165, 0),
    ]

    @Test("17 色すべてが、CSS の値で作った色と 1 ビットも変わらない")
    func everyNamedColorEqualsTheColorBuiltFromItsCSSValue() {
        #expect(Self.css.count == 17)
        for entry in Self.css {
            #expect(
                entry.color == color(entry.r, entry.g, entry.b),
                "\(entry.name): \(entry.color) は color(\(entry.r), \(entry.g), \(entry.b)) と違う")
        }
        // 例に挙げた 3 色を、書いた形のままでも見る
        #expect(Color.green == color(0, 128, 0))
        #expect(Color.orange == color(255, 165, 0))
        #expect(Color.white == color(255))
    }

    /// 名前の付いた色は不透明で、17 色とも違う色である (同じ値を 2 つの名前に書き写さない)。
    @Test("17 色はどれも不透明で、互いに違う")
    func namedColorsAreOpaqueAndDistinct() {
        #expect(Self.css.allSatisfy { $0.color.alpha == 1 })
        #expect(Set(Self.css.map(\.color)).count == 17)
    }

    /// `.green` は CSS の暗い緑 (`#008000`) で、明るい緑は `.lime` である (SwiftUI の `.green` とは違う)。
    @Test("green は CSS の暗い緑で、明るい緑は lime")
    func greenIsCSSGreen() {
        #expect(Color.green != Color.lime)
        #expect(Color.green.premultipliedGreen < Color.lime.premultipliedGreen)
    }

    /// 隔離の外 (`nonisolated`) から読める。**この関数が組めることが検査である** — 色が main actor の
    /// 隔離を持ったままだと、読むところがコンパイルエラーになる。
    nonisolated static func readOutsideTheMainActor() -> (Color, Rect, Color) {
        let tile = Rect(left: 24, top: 48, width: 40, height: 14, fill: .orange)
        return (.red, tile, Color.white)
    }

    @Test("main actor の外から読め、値型の fill に渡せる")
    func readableOutsideTheMainActor() async {
        let (red, tile, white) = await Task.detached { Self.readOutsideTheMainActor() }.value
        #expect(red == Color.red)
        #expect(tile.fill == Color.orange)
        #expect(white == Color.white)
        var brick = tile
        brick.fill = .navy
        #expect(brick.fill == Color.navy)
    }

    /// 作例どおりの書き方が組める: `fill(.red)` と `Rect(… fill: .orange)`。組めることを見るだけで、走らせない。
    @MainActor
    private static func spellings(_ canvas: Canvas) {
        canvas.fill(.red)
        canvas.stroke(.white)
        canvas.background(.black)
        _ = Rect(left: 24, top: 48, width: 40, height: 14, fill: .orange)
    }
}
