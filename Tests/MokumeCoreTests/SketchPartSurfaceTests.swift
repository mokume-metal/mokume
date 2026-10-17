// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

// **アンブレラだけを import する** ([PluginRegistrySurfaceTests](PluginRegistrySurfaceTests.swift) と
// 同じ作法)。`@testable` を使わないので、ここで組めた書き方は利用者のスケッチでもそのまま組める。
import mokume

/// 自作の型が `SketchPart` を名乗ると、その中でスケッチの語彙が使える (#2616)。
///
/// **確かめているのは組めることである。** 下の型が組めなければ、この suite のファイルごと
/// `swift build --build-tests` が赤になる。呼んだときに描かれることは
/// [SketchPartDrawingTests](SketchPartDrawingTests.swift) が GPU で見る。装置にも窓にも
/// 触らないので、この suite にゲートは付かない。
@Suite("部品の型の中の語彙 (公開の面だけ)")
struct SketchPartSurfaceTests {
    /// 描く・入力を読む・乱数を引く・状態を書く口を、struct の中から呼ぶ。
    struct Player: SketchPart {
        var x: Float = 240
        var y: Float = 200

        func display() {
            fill(255)
            circle(x, y, 20)
            text("HP 3", x, y - 16)
        }

        mutating func follow() {
            if isMousePressed { x = mouseX }
            y += random(-1, 1) * deltaTime
        }

        /// 書けるプロパティも、部品の中から書ける (書く先は走っているスケッチ)。
        func turn() {
            orbit.pitch = 0.3
        }
    }

    /// 部品をプロパティに持つスケッチ。`Sketch` の中では何も名乗らずに同じ語彙が使える。
    final class Game: Sketch {
        var player = Player()
        func draw() {
            background(20)
            player.follow()
            player.display()
        }
    }

    @Test("Sketch は SketchPart を継ぐ")
    func sketchIsASketchPart() {
        let part: any SketchPart = Game()
        #expect(part is Game)
    }

    @Test("部品の型は値として作れる (作るだけでは語彙を呼ばない)")
    func partIsAValue() {
        var player = Player()
        player.x = 10
        #expect(player.x == 10)
        #expect(Game().player.x == 240)
    }
}
