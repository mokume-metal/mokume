// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// 重力で落ち、足場に立ち、壁で止まる矩形の体 ([#3589])。横スクロールのゲームのアーケード物理。
///
/// 位置と大きさを矩形で渡して作り、速さ (``velocity``) を入力で決めて、`draw()` から ``step(gravity:solids:)``
/// を 1 回呼ぶ。呼ぶ 1 回で 1 歩進み、刻みは `deltaTime`。足場に立っているかは ``isOnFloor`` で読める:
///
/// ```swift
/// final class Platformer: Sketch {
///     var player = ArcadeBody(Rect(left: 40, top: 100, width: 16, height: 24))  // 位置と大きさ。速さは velocity
///     let solids: [Rect] = [Rect(left: 0, top: 200, width: 480, height: 20)]   // 足場と壁
///
///     func draw() {
///         player.velocity.x = keyboard.isPressed(.arrowRight) ? 120 : keyboard.isPressed(.arrowLeft) ? -120 : 0
///         if keyboard.justPressed(.space) && player.isOnFloor { player.velocity.y = -300 }  // 跳べるのは立っているときだけ
///         player.step(gravity: Vector2(0, 900), solids: solids)   // 呼ぶ 1 回で 1 歩。刻みは deltaTime
///         expose("playerY", player.rect.top)
///         expose("grounded", player.isOnFloor)
///
///         background(20)
///         for solid in solids { solid.draw() }
///         player.rect.draw()
///     }
/// }
/// ```
///
/// 剛体物理 (質量・回転・体どうしの衝突) は持たない。体は回らない矩形で、ぶつかる相手は動かない矩形 (`solids`) だけ。
///
/// ## 1 歩の進め方
///
/// 1 歩は次の順で進む (刻み `dt` は呼んだときの ``SketchPart/deltaTime``)。
///
/// 1. 速さに重力を足す (`velocity += gravity * dt`)
/// 2. **横に動かす。** 進む向きにある矩形の手前で止め、横の速さを 0 にする
/// 3. **縦に動かす。** 下へ進んで矩形の上面に当たれば上面に立たせ、上へ進んで下面に当たれば頭を止める。どちらも縦の速さを 0 にする
///
/// 横と縦を分けて動かすので、壁に沿って落ちる・足場の上を歩くといった動きで角に引っかからない。
/// **当たりは動いた道の途中も見る。** 1 歩で薄い足場や壁を飛び越えるほど速くても、通り道にある矩形の手前で止まる。
///
/// **辺が接しているだけでは当たらない。** 足場の上面に立った体は、隣に並べた同じ高さの足場へ、段差に引っかからずに
/// 歩いて移れる。作ったときにすでに矩形と重なっている体は押し出さない (重ならない位置に置く)。
///
/// **時計 (``SketchSettings/clock``) が ``SketchSettings/ClockMode/frames`` なら、刻みは毎回ちょうど 1 / fps 秒**
/// なので、同じ入力を流せば各歩の位置と速さは何度実行しても同じになる。ウィンドウの既定の実時間の時計では、
/// 刻み方が実行ごとに違うので揃わない。
///
/// 走っている実行の外で ``step(gravity:solids:)`` を呼ぶと、`deltaTime` と同じく刻みを 0 として扱い (動かない)、
/// 1 度だけ警告する。
///
/// [#3589]: https://github.com/mokume-metal/mokume/issues/3589
public nonisolated struct ArcadeBody: Sendable {
    /// 体の位置と大きさ。左上 (`left`・`top`) が位置で、``step(gravity:solids:)`` が動かす。
    public private(set) var rect: Rect

    /// 速さ (1 秒あたりの座標)。下向きが正。入力で決めて ``step(gravity:solids:)`` に渡す前に書き換える。
    ///
    /// 矩形に当たった向きの成分は、その歩で 0 になる。
    public var velocity = Vector2(0, 0)

    /// 足場の上面に立っているか。最後の ``step(gravity:solids:)`` が、上へ動いておらず、矩形の上面に足が乗った
    /// 位置で終えたときに真。作った直後は偽。
    public private(set) var isOnFloor = false

    /// 矩形 `rect` の位置と大きさの体を作る。速さは 0。
    ///
    /// ```swift
    /// var player = ArcadeBody(Rect(left: 40, top: 100, width: 16, height: 24))
    /// ```
    public init(_ rect: Rect) {
        self.rect = rect
    }

    /// 重力 `gravity` (1 秒あたりに増える速さ) を掛けて 1 歩進め、`solids` の矩形にめり込まないように止める。
    ///
    /// <!-- example: 文脈 var player = ArcadeBody(Rect(left: 40, top: 100, width: 16, height: 24)) -->
    /// ```swift
    /// player.step(gravity: Vector2(0, 900), solids: [Rect(left: 0, top: 200, width: 480, height: 20)])
    /// ```
    ///
    /// 呼ぶ 1 回で 1 歩。刻みは呼んだときの `deltaTime` を読む。
    @MainActor
    public mutating func step(gravity: Vector2, solids: [Rect]) {
        advance(by: StepLength().value, gravity: gravity, solids: solids)
    }

    // MARK: - 刻みを渡して進める (検査と上の口が使う)

    /// 刻み `dt` 秒で 1 歩進める。
    ///
    /// **比べるのは、体の左上が取りうる位置どうし。** 止める位置 (`solid.left - rect.width` など) と同じ式で
    /// 当たりを判定するので、前の歩で止めた位置は浮動小数の誤差で矩形の内側へ入り込まず、接したままと判定される。
    mutating func advance(by dt: Float, gravity: Vector2, solids: [Rect]) {
        velocity.x += gravity.x * dt
        velocity.y += gravity.y * dt
        moveHorizontally(by: velocity.x * dt, solids: solids)
        moveVertically(by: velocity.y * dt, solids: solids)
        isOnFloor = velocity.y >= 0 && solids.contains { standsOn($0) }
    }

    private mutating func moveHorizontally(by dx: Float, solids: [Rect]) {
        let from = rect.left
        let to = from + dx
        var stop: Float?
        for solid in solids where overlapsVertically(solid) {
            if dx > 0 {
                let limit = solid.left - rect.width
                if limit >= from, limit < to, limit < (stop ?? .infinity) { stop = limit }
            } else if dx < 0 {
                let limit = solid.right
                if limit <= from, limit > to, limit > (stop ?? -.infinity) { stop = limit }
            }
        }
        rect.left = stop ?? to
        if stop != nil { velocity.x = 0 }
    }

    private mutating func moveVertically(by dy: Float, solids: [Rect]) {
        let from = rect.top
        let to = from + dy
        var stop: Float?
        for solid in solids where overlapsHorizontally(solid) {
            if dy > 0 {
                let limit = solid.top - rect.height
                if limit >= from, limit < to, limit < (stop ?? .infinity) { stop = limit }
            } else if dy < 0 {
                let limit = solid.bottom
                if limit <= from, limit > to, limit > (stop ?? -.infinity) { stop = limit }
            }
        }
        rect.top = stop ?? to
        if stop != nil { velocity.y = 0 }
    }

    /// 縦の範囲が `solid` と重なるか (辺が接するだけなら重ならない)。
    private func overlapsVertically(_ solid: Rect) -> Bool {
        rect.top > solid.top - rect.height && rect.top < solid.bottom
    }

    /// 横の範囲が `solid` と重なるか (辺が接するだけなら重ならない)。
    private func overlapsHorizontally(_ solid: Rect) -> Bool {
        rect.left > solid.left - rect.width && rect.left < solid.right
    }

    /// `solid` の上面に足が乗っているか。
    private func standsOn(_ solid: Rect) -> Bool {
        overlapsHorizontally(solid) && rect.top == solid.top - rect.height
    }
}

/// 走っている実行の刻みを、``SketchPart/deltaTime`` と同じ規則で読む。
///
/// ``ArcadeBody`` 自身は ``SketchPart`` を名乗らない (名乗ると `player.circle(…)` のような描く語彙まで生える)。
private struct StepLength: SketchPart {
    @MainActor
    var value: Float { deltaTime }
}
