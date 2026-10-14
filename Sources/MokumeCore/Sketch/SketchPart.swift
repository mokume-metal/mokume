// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// スケッチの語彙 (``fill(_:)``・``circle(_:_:_:)``・``mouseX``・``random(_:)`` など) を
/// 使える型。
///
/// ``Sketch`` はこれを継いでいるので、スケッチの中ではいつでも使える。自分で書いた型も
/// `: SketchPart` と名乗れば、その中から同じ語彙をそのまま呼べる — Processing でタブに書いた
/// クラスの中から `fill()` を呼ぶのと同じ書き方になる。
///
/// ```swift
/// struct Player: SketchPart {
///     var x: Float = 240
///     var y: Float = 200
///
///     func display() {
///         fill(255)
///         circle(x, y, 20)
///         text("HP 3", x, y - 16)
///     }
/// }
///
/// final class Game: Sketch {
///     var player = Player()
///     func draw() {
///         background(20)
///         player.display()
///     }
/// }
/// ```
///
/// **語彙は、走っているスケッチへ描き、そのスケッチの状態を読む。** 部品を名乗った型が
/// どのスケッチに属するかを覚えるのではなく、呼んだ時点で走っているスケッチを見る。
/// 同時に動かすスケッチは 1 つである。
///
/// **呼べるのはスケッチが走っている間** (``Sketch/setup()``・``Sketch/draw()``・入力の
/// 呼び出しの中) だけで、``Sketch`` のメソッドとして呼ぶときと同じ扱いになる。
///
/// 色を作る ``color(_:)`` や ``map(_:_:_:_:_:)`` のような純粋な計算は、名乗らなくても
/// どこからでも呼べる。名乗らない型の中で ``fill(_:)`` を書くと、
/// 「`fill` が見つからない」で止まる。
///
/// 置き場の決定は [ADR-0020] 決定 7 にある。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public protocol SketchPart {}
