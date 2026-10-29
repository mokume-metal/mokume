// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// スケッチの語彙 (``fill(_:)-(LinearRGBA)``・``circle(_:_:_:)``・``mouseX``・``random(_:_:)`` など) を
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
/// 呼び出しの中) だけで、``Sketch`` のメソッドとして呼ぶときと同じ扱いになる。外 — 部品の
/// `init()` の中など — から呼んでも落ちず、読み取りは 0 や空を返し、描く口は何もしない
/// (口ごとに 1 度だけ警告する。[ADR-0020] 決定 5)。面の大きさで決まる値は `setup()` で決める。
/// 例外は返すものを面からしか作れない口である。面から作る資源 (``createGraphics(_:_:)``・
/// ``loadImage(_:)`` など) は、外から呼ぶと型のついたエラー (``RenderFailure/notRunning(call:)``
/// など) を投げる。投げない ``createShape(_:)`` は空の形を返して警告する。面そのもの (``canvas``)
/// だけは、返す値も投げる道も無いので、外から取ると止まる。
///
/// **更新は、語彙を読まずに引数で受ける値の型へ分けられる。** 上の「呼べるのはスケッチが走っている間」
/// のとおり、`update` の中で ``keyboard``・``width``・``random(_:_:)`` を読むと、`init()`・`Task`・テストの
/// ように走っていない所では 0 や空になる。入力と刻みを `draw()` で読んで引数で渡せば、`update` は語彙を
/// 知らない値の更新になり、窓も GPU も無しに確かめられる。
///
/// ```swift
/// struct Paddle: SketchPart {
///     var x: Float = 240
///
///     mutating func update(horizontal: Float, deltaTime: Float) {
///         x += horizontal * 120 * deltaTime
///     }
///
///     func display() { rect(x - 30, 440, 60, 10) }
/// }
///
/// final class Breakout: Sketch {
///     var paddle = Paddle()
///
///     func draw() {
///         let left: Float = keyboard.isPressed(.arrowLeft) ? 1 : 0
///         let right: Float = keyboard.isPressed(.arrowRight) ? 1 : 0
///         paddle.update(horizontal: right - left, deltaTime: deltaTime)
///         background(20)
///         paddle.display()
///     }
/// }
/// ```
///
/// 入力 1・刻み 0.25 秒で `update` を呼ぶと、`x` は 240 から 270 (240 + 1 × 120 × 0.25) になる。
/// `Paddle()` を作って `update` を呼ぶだけの計算なので、スケッチを走らせなくても、窓も GPU も無しに
/// 確かめられる。テストの書き方は [Swift Testing](https://developer.apple.com/documentation/testing)
/// にある。
///
/// **部品の型に置けないもの:**
///
/// - つまみ (`@Param`) は、スケッチの型に直に置いたものだけが出る。部品の中に書いても組めるが、
///   つまみには出ない
/// - 音・カメラ・通信の口 (``Sketch/createSinOsc()``・``Sketch/createCapture(_:_:device:mirrored:)``・
///   ``Sketch/createOSC(listen:send:)`` など) と ``Sketch/params`` は、スケッチの中でだけ使える
/// - 待つ読み込み (``requestImage(_:)`` など) の結果を `Task` の中で書き戻す先は、スケッチの
///   プロパティにする。値の型 (struct) の自分自身へは、`Task` の中から書き戻せない
///
/// 色を作る `color` や `map` のような純粋な計算は、名乗らなくても
/// どこからでも呼べる。名乗らない型の中で ``fill(_:)-(LinearRGBA)`` を書くと、
/// 「`fill` が見つからない」で止まる。
///
/// 置き場の決定は [ADR-0020] 決定 7 にある。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public protocol SketchPart {}
