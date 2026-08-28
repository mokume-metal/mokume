// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 立体を取り巻く周囲。**上・地平・下の 3 色の帯**で表す。
///
/// ## なぜ帯なのか
///
/// 金属や艶のある面は、映り込む先が無いと絵にならない — 拡散を持たないので、
/// 周りに何も無ければただ暗いだけになる。周囲を表すのに絵 (環境マップ) を要求すると、
/// 資材を用意するまで金属が使えない。**3 色の帯なら資材が要らず**、上下の向きも
/// 持つので「空が上・地面が下」が絵に出る。
///
/// 絵から作る形はまだ置かない — この形で完了条件が満たせるうちは足さない
/// ([ADR-0008])。3 色は自分で渡せるので、作る余地は残してある。
///
/// ## 明るさの単位
///
/// **色そのものが線形の明るさの倍率である** — 光 ([`Light`](Light.swift)) と同じ規範で、
/// 強さを表す別の数を持たない。既定の周囲を弱めたいときは ``scaled(by:)`` で色を掛ける。
///
/// ## 寿命
///
/// 周囲は**シーンの記述**なのでフレームを越えない ([ADR-0021] 決定 4)。光と同じく、
/// 積んだスタイルには含めない — 「置く」ものであって「これから描くものの性質」では
/// ないためである。
///
/// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
/// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
public struct Surroundings: Equatable, Sendable {
    /// 真上の色。
    public var top: LinearRGBA
    /// 地平 (真横) の色。
    public var horizon: LinearRGBA
    /// 真下の色。
    public var bottom: LinearRGBA

    /// 3 色から作る。
    public init(top: LinearRGBA, horizon: LinearRGBA, bottom: LinearRGBA) {
        self.top = top
        self.horizon = horizon
        self.bottom = bottom
    }

    /// 晴れた空 — 上が青く、地平が明るく、下が土の色。
    public static let sky = Surroundings(
        top: .display(red: 0.42, green: 0.58, blue: 0.9),
        horizon: .display(red: 0.78, green: 0.85, blue: 0.95),
        bottom: .display(red: 0.28, green: 0.26, blue: 0.24))

    /// 撮影室 — 上から白く当たり、下は暗い。
    public static let studio = Surroundings(
        top: .display(red: 0.95, green: 0.95, blue: 0.95),
        horizon: .display(red: 0.6, green: 0.6, blue: 0.62),
        bottom: .display(red: 0.25, green: 0.25, blue: 0.27))

    /// 夕暮れ — 地平が橙で、上は暗い青。
    public static let sunset = Surroundings(
        top: .display(red: 0.25, green: 0.3, blue: 0.55),
        horizon: .display(red: 0.95, green: 0.6, blue: 0.35),
        bottom: .display(red: 0.2, green: 0.14, blue: 0.12))

    /// 明るさを倍率で変える。**色が明るさそのものなので、掛けるのが強さの指定になる。**
    public func scaled(by factor: Float) -> Surroundings {
        Surroundings(
            top: Self.scale(top, factor),
            horizon: Self.scale(horizon, factor),
            bottom: Self.scale(bottom, factor))
    }

    private static func scale(_ color: LinearRGBA, _ factor: Float) -> LinearRGBA {
        LinearRGBA(
            premultipliedRed: color.red * factor, green: color.green * factor,
            blue: color.blue * factor, alpha: color.alpha)
    }

    /// 受け取れる値か。数でない成分・負の成分を持つ周囲は置かない。
    var isUsable: Bool {
        [top, horizon, bottom].allSatisfy { color in
            [color.red, color.green, color.blue].allSatisfy { $0.isFinite && $0 >= 0 }
        }
    }

    /// シェーダへ渡す形へ詰める。
    ///
    /// - Parameter isBackdrop: この列が**周囲そのものを出す**なら真。
    func packed(isBackdrop: Bool = false) -> PackedSurroundings {
        PackedSurroundings(
            topAndPresence: SIMD4(top.red, top.green, top.blue, 1),
            horizonAndBackdrop: SIMD4(
                horizon.red, horizon.green, horizon.blue, isBackdrop ? 1 : 0),
            bottom: SIMD4(bottom.red, bottom.green, bottom.blue, 0))
    }
}

/// 周囲をシェーダへ渡す形。
///
/// 並びは `Drawing/Shaders/Common.metal` の同名の構造体と一致していなければならない
/// (``ShapeVertex`` と同じ理由で、大きさを ``expectedStride`` として持つ)。
struct PackedSurroundings {
    /// 上の色 (rgb) と、周囲が置かれているか (w)。
    var topAndPresence: SIMD4<Float>
    /// 地平の色 (rgb) と、この列が周囲そのものを出すか (w)。
    var horizonAndBackdrop: SIMD4<Float>
    /// 下の色 (rgb)。
    var bottom: SIMD4<Float>

    /// 周囲が置かれていない状態。**無いときも同じ形を渡す** — 渡し方が 2 通りに
    /// 分かれると、片方でしか成り立たない性質が生まれる。
    static let none = PackedSurroundings(
        topAndPresence: .zero, horizonAndBackdrop: .zero, bottom: .zero)

    /// シェーダ側の構造体と一致すべき大きさ (バイト)。
    static let expectedStride = 48
}
