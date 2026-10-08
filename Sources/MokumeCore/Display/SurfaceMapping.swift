// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 窓の座標を、キャンバスの座標へ写す規則。
///
/// 窓は描く解像度と独立に大きさが変わり、縦横比を保つために帯が入る (``ViewportFit``)。
/// **窓が拾った操作を合流点へ流すには、その逆をたどって描く解像度の座標へ戻す必要がある。**
/// 外から送られる出来事は「キャンバスの座標で送る」と決めてあるので、窓側もそこへ揃える —
/// 揃えて初めて、外から動かして確かめたことが人が触ったときにも成り立つ。
///
/// ## 帯の上は丸めない
///
/// 帯の上を指すと結果は面の外を指し、**負にも幅超えにもなる**。丸めない理由は 2 つ:
///
/// - **外から送る経路も範囲外を作れる。** 送られた値に範囲の検査は無い (`RawInputEvent`)。
///   ここで丸めると窓側だけが丸まり、揃えたはずの 2 経路が座標の取りうる範囲で食い違う
/// - **引きずったまま面の外へ出たときに止まる。** 丸めると ``InputState/dragX`` の
///   積み上がりが端で頭打ちになり、引きずって回す道具が窓の外で固まる
struct SurfaceMapping: Equatable {
    /// 面の大きさ (点)。
    var viewWidth: Double
    var viewHeight: Double
    /// 面の実際の画素数。**点とは別物**で、Retina では倍になる。
    var drawableWidth: Double
    var drawableHeight: Double
    /// 描く解像度。
    var canvasWidth: Double
    var canvasHeight: Double

    /// 窓の座標 (左下原点・点) を、キャンバスの座標 (左上原点・画素) へ写す。
    ///
    /// 3 段を**この順で**踏む。順が違うと Retina と帯で合わない:
    ///
    /// 1. **縦軸を反転する — 点のまま。** `NSView` は左下原点、キャンバスは左上原点
    /// 2. **点 → 画素。** 面の画素数と点の比を掛ける
    /// 3. **帯を外す。** 収まった矩形の原点を引き、その大きさで割り、描く解像度を掛ける
    ///
    /// 1 と 2 を入れ替えて、画素の空間で `drawableHeight - y × 倍率` と反転すると上下に
    /// ずれる。`CAMetalLayer` は `drawableSize` を整数へ丸めるので、**実際の比は画面の
    /// 倍率そのものではない** — 反転を点の空間で済ませ、そのあとに実際の比を掛ければ、
    /// 丸めた分は両端へ等しく散る。
    ///
    /// - Returns: 写した座標。大きさのどれかが 0 なら `nil` — 0 で割った座標を合流点へ
    ///   流すくらいなら、その 1 件は届かないほうがよい。
    func canvasPoint(x: Double, y: Double) -> (x: Float, y: Float)? {
        guard let fit else { return nil }

        // 1. 縦軸を反転する (点のまま)
        let flipped = viewHeight - y
        // 2. 点 → 画素
        let pixelX = x * (drawableWidth / viewWidth)
        let pixelY = flipped * (drawableHeight / viewHeight)
        // 3. 帯を外す
        let canvasX = (pixelX - fit.x) / fit.width * canvasWidth
        let canvasY = (pixelY - fit.y) / fit.height * canvasHeight
        return (Float(canvasX), Float(canvasY))
    }

    /// 窓の上で動いた量 (点・**縦軸は下向き**) を、描く解像度の画素の量へ写す
    /// ([#1144](https://github.com/mokume-metal/mokume/issues/1144))。
    ///
    /// カーソルを捕まえている間は位置が動かないので、窓は位置の代わりにこれを送る。**位置と
    /// 同じ比で写す** — 点 → 画素 → 描く解像度。違うのは 2 つだけで、どちらも量だからである:
    ///
    /// - **帯の原点を引かない。** 量は場所を持たない
    /// - **縦軸を反転しない。** 受け取る量は下向きを正とする約束である。窓の出来事をそう読んで
    ///   渡すのは呼ぶ側 (`SketchSurface`) で、そこに読み方の理由がある
    ///
    /// 同じ比で写すので、捕まえる前と後で同じ手つきが同じ量になる — 捕まえたかどうかで
    /// `deltaX` の単位が変わると、同じ名前で値の体系が割れる (ADR-0020 決定 1 の 2026-09-09 改訂)。
    ///
    /// - Returns: 写した量。大きさのどれかが 0 なら `nil` (``canvasPoint(x:y:)`` と同じ)。
    func canvasDelta(dx: Double, dy: Double) -> (dx: Float, dy: Float)? {
        guard let fit else { return nil }
        let pixelX = dx * (drawableWidth / viewWidth)
        let pixelY = dy * (drawableHeight / viewHeight)
        return (Float(pixelX / fit.width * canvasWidth), Float(pixelY / fit.height * canvasHeight))
    }

    /// 絵が収まった矩形 (面の画素)。大きさのどれかが 0 なら `nil` — 0 で割った値を合流点へ
    /// 流すくらいなら、その 1 件は届かないほうがよい。
    private var fit: ViewportFit? {
        guard viewWidth > 0, viewHeight > 0, canvasWidth > 0, canvasHeight > 0 else {
            return nil
        }
        let fit = ViewportFit.fit(
            contentAspect: canvasWidth / canvasHeight,
            surfaceWidth: drawableWidth, surfaceHeight: drawableHeight)
        guard fit.width > 0, fit.height > 0 else { return nil }
        return fit
    }
}
