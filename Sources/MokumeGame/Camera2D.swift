// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// 横に長い面を画面の幅で切り取って映すカメラ ([#3590])。相手を追い、面の端で止まり、画面と世界の座標を変換する。
///
/// 面 (世界) の幅を渡して作り、毎フレーム ``follow(_:)`` で追う相手の位置を渡す。カメラの左端の世界の x
/// (``x``) が決まるので、`translate(-camera.x, 0)` してから世界の座標で描く:
///
/// ```swift
/// final class Runner: Sketch {
///     var camera = Camera2D(worldWidth: 1920)   // 画面の幅は width から読む
///     var player = Rect(left: 100, top: 200, width: 32, height: 32)
///
///     func draw() {
///         if keyboard.isPressed(.arrowRight) { player.left += 240 * deltaTime }
///         if keyboard.isPressed(.arrowLeft) { player.left -= 240 * deltaTime }
///         camera.follow(player.center)             // 中央を越えたら追い、面の端で止まる
///         expose("cameraX", camera.x)
///
///         background(20)
///         translate(-camera.x, 0)                  // ここから世界の座標で描く
///         player.draw()
///
///         let aim = camera.toWorld(Vector2(mouseX, mouseY))   // 画面上の位置 → 世界の座標
///         let pointer = camera.toScreen(aim)                  // 同じ点を画面の座標へ戻す
///         expose("pointerX", pointer.x)
///     }
/// }
/// ```
///
/// ## 追い方
///
/// **相手が画面の中央を越えたら追い、面の端では止まる。** 画面の幅を `width` として、``x`` は
/// 「相手の x − `width` / 2」を 0 から「面の幅 − `width`」の間に収めた値になる。面の幅 1920・画面の幅 480 なら、
/// 相手の x が 240 以下の間は 0、240 を越えると「相手の x − 240」、1680 を越えると 1440 で止まる。
/// **面が画面より狭ければ 0 のまま動かない。** 相手の位置が有限の数でない (無限大・NaN) ときも、``x`` は
/// 0 から「面の幅 − `width`」の間に収まる。
///
/// 追うのは横だけで、縦はずらさない (``toWorld(_:)``・``toScreen(_:)`` も y をそのまま返す)。
///
/// 画面の幅は、``follow(_:)`` を呼んだときの ``SketchPart/width`` を読む。走っている実行の外で呼ぶと、`width`
/// と同じく画面の幅を 0 として扱い、1 度だけ警告する。
///
/// **``follow(_:)`` は呼んだ時点の位置へ合わせる。** 時間や前のフレームの値で滑らかにはしないので、
/// 時計 (``SketchSettings/clock``) が ``SketchSettings/ClockMode/frames`` なら、同じ入力を流せば各フレームの
/// ``x`` は何度実行しても同じになる。
///
/// ## 座標の変換
///
/// ``toWorld(_:)`` は画面の座標 (`mouseX`・`mouseY` など) を世界の座標へ、``toScreen(_:)`` は世界の座標を
/// 画面の座標へ変える。どちらもその時点の ``x`` を使うので、``follow(_:)`` の後に呼ぶと、そのフレームで映して
/// いる位置と合う。
///
/// [#3590]: https://github.com/mokume-metal/mokume/issues/3590
public nonisolated struct Camera2D: Sendable {
    /// 面 (世界) の幅。
    private let worldWidth: Float

    /// カメラの左端の、世界の x。画面の左端に映る世界の位置で、`translate(-camera.x, 0)` に渡す。
    ///
    /// 0 から「面の幅 − 画面の幅」の間に収まる。作った直後と、面が画面より狭いときは 0。
    public private(set) var x: Float = 0

    /// 幅 `worldWidth` の面を映すカメラを作る。左端 (``x`` が 0) から映し始める。
    ///
    /// ```swift
    /// var camera = Camera2D(worldWidth: 1920)
    /// ```
    ///
    /// 画面の幅は渡さない。``follow(_:)`` を呼んだときの `width` を読む。
    public init(worldWidth: some ScalarConvertible) {
        self.worldWidth = worldWidth.asFloat
    }

    /// `target` (世界の座標) を追う。画面の中央を越えたら追い、面の端で止まる。
    ///
    /// <!-- example: 文脈 var camera = Camera2D(worldWidth: 1920) -->
    /// <!-- example: 文脈 let player = Rect(left: 100, top: 200, width: 32, height: 32) -->
    /// ```swift
    /// camera.follow(player.center)
    /// translate(-camera.x, 0)
    /// ```
    ///
    /// 画面の幅は呼んだときの `width` を読む。``x`` は「`target.x` − `width` / 2」を 0 から
    /// 「面の幅 − `width`」の間に収めた値になる。縦はずらさない。
    @MainActor
    public mutating func follow(_ target: Vector2) {
        track(target, screenWidth: ScreenWidth().value)
    }

    /// 画面の座標 `point` を、世界の座標にする。横は ``x`` を足し、縦はそのまま。
    ///
    /// <!-- example: 文脈 let camera = Camera2D(worldWidth: 1920) -->
    /// ```swift
    /// let aim = camera.toWorld(Vector2(mouseX, mouseY))
    /// ```
    public func toWorld(_ point: Vector2) -> Vector2 {
        Vector2(point.x + x, point.y)
    }

    /// 世界の座標 `point` を、画面の座標にする。横は ``x`` を引き、縦はそのまま。
    ///
    /// <!-- example: 文脈 let camera = Camera2D(worldWidth: 1920) -->
    /// ```swift
    /// let onScreen = camera.toScreen(Vector2(700, 50))
    /// ```
    public func toScreen(_ point: Vector2) -> Vector2 {
        Vector2(point.x - x, point.y)
    }

    // MARK: - 画面の幅を渡して追う (検査と上の口が使う)

    /// 画面の幅 `screenWidth` で `target` を追う。
    mutating func track(_ target: Vector2, screenWidth: Float) {
        let upper = Swift.max(0, worldWidth - screenWidth)
        // 引数の順は NaN を 0 へ倒すためのもの (`max(0, .nan)` は 0、`max(.nan, 0)` は NaN)
        x = Swift.min(upper, Swift.max(0, target.x - screenWidth / 2))
    }
}

/// 走っている実行の画面の幅を、``SketchPart/width`` と同じ規則で読む。
///
/// ``Camera2D`` 自身は ``SketchPart`` を名乗らない (名乗ると `camera.circle(…)` のような描く語彙まで生える)。
private struct ScreenWidth: SketchPart {
    @MainActor
    var value: Float { width }
}
