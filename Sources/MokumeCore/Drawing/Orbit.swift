// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 注視点のまわりを回る視点の操作。
///
/// 見ている先・そこからの距離・水平角・仰角を持ち、引きずった量とスクロールから
/// 進む。``SketchPart/orbitControl(_:_:_:)`` が毎フレームこれを進めて視点を当てる。
///
/// **視点そのものではない。** 視点はフレームを越えないシーンの記述だが ([ADR-0021]
/// 決定 4)、こちらは入力から積み上がる状態なのでフレームを越える — 越えなければ、
/// 引きずった角度が毎フレーム捨てられて何も動かない。
///
/// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
public struct Orbit: Equatable, Sendable {

    /// 見ている先 (世界の座標)。
    public var center: SIMD3<Float>
    /// 見ている先からの距離。
    public var distance: Float
    /// 水平角 (ラジアン)。0 で真正面から。
    public var yaw: Float
    /// 仰角 (ラジアン)。正で見下ろす。
    public var pitch: Float
    /// 離したあと、1 フレームごとに速さをどれだけ保つか。**0 で流れない (既定)。**
    public var inertia: Float
    /// 寄れる限界。
    public var minimumDistance: Float
    /// 引ける限界。
    public var maximumDistance: Float

    /// 離したあとに続く速さ。**公開しない** — 慣性の作り物であって、外から意味を持つ量ではない。
    var yawSpeed: Float = 0
    var pitchSpeed: Float = 0

    public init(
        center: SIMD3<Float>, distance: Float, yaw: Float = 0, pitch: Float = 0,
        inertia: Float = 0, minimumDistance: Float = 1, maximumDistance: Float = .infinity
    ) {
        self.center = center
        self.distance = distance
        self.yaw = yaw
        self.pitch = pitch
        self.inertia = inertia
        self.minimumDistance = minimumDistance
        self.maximumDistance = maximumDistance
    }

    // MARK: - 既定

    /// 引きずった 1 画素が回す角 (ラジアン)。
    ///
    /// 面の大きさに依らない固定の割合にする。面に対する割合にすると、窓の大きさを
    /// 変えただけで同じ手の動きが違う角を回すことになる。
    static let radiansPerPixel: Float = 0.01

    /// スクロール 1 目盛りが距離を掛ける割合 (指数)。
    ///
    /// 掛け算で寄る。足し算にすると、遠くでは寄らず近くでは行き過ぎる。
    static let zoomPerScroll: Float = 0.05

    /// 仰角の限界。**真上・真下を越えない。**
    ///
    /// 越えると上方向が視線と重なって横が決まらなくなり、絵が上下反転して操作不能に
    /// なる (``Camera/isUsable`` が弾く条件そのもの)。
    static let pitchLimit: Float = .pi / 2 - 0.01

    /// 面がちょうど収まる視点から始める操作。
    ///
    /// **既定の視点 (`Camera.fitting(width:height:)`) と同じ位置に置く。** だから
    /// `orbitControl()` を足しただけでは絵が動かない。寄り・引きの限界も既定の投影の
    /// 手前・奥の面に合わせるので、限界まで動かしても切れない。
    public static func fitting(width: some ScalarConvertible, height: some ScalarConvertible)
        -> Orbit
    {
        let (width, height) = (width.asFloat, height.asFloat)
        let distance = Camera.fittingDistance(height: height)
        return Orbit(
            center: SIMD3(width / 2, height / 2, 0), distance: distance,
            minimumDistance: distance / 10, maximumDistance: distance * 10)
    }

    // MARK: - 視点

    /// 見る位置 (世界の座標)。
    public var eye: SIMD3<Float> {
        // 縦軸は下向きなので、見下ろす (正の仰角) と見る位置は -y へ上がる
        let offset = SIMD3<Float>(
            RuntimeMath.sin(yaw) * RuntimeMath.cos(pitch), -RuntimeMath.sin(pitch), RuntimeMath.cos(yaw) * RuntimeMath.cos(pitch))
        return center + offset * distance
    }

    /// どちらを上とするか。仰角を限界で止めてあるので、視線と重ならない。
    public var up: SIMD3<Float> { SIMD3(0, 1, 0) }

    // MARK: - 進める

    /// 1 フレームぶん進める。
    ///
    /// ## 慣性を足し込みで作らない
    ///
    /// 素直に「速さに引きずった量を足し、角度に速さを足し、速さを減衰させる」と書くと、
    /// 1 px が回す総量が `1 / (1 - 減衰)` 倍になり、**慣性の強さを変えると手の効きまで
    /// 変わる**。そうならないよう、引きずっている間は**角度へ直接足し**、速さは足し込まず
    /// 上書きする (離したあとに続く速さ)。止めてから離せば速さは 0 になるので流れない。
    ///
    /// 慣性が 0 のときは速さを毎フレーム捨てる。取っておくと、**あとで慣性を上げた瞬間に、
    /// 待った時間に関わらず勝手に回り出す**。
    ///
    /// ## 状態は常に有限に保つ
    ///
    /// 角・距離・速さに数でない値・無限が入ると、``clampToLimits(fallbackCenter:)`` が角を 0、距離を
    /// 下限へ倒すしかなく、慣性があれば離したあとも毎フレーム倒し続ける ([#2643])。
    /// だから**進めた先が有限にならない軸は、その軸だけ進めない** — 感度が数でない・無限、
    /// 有限の感度と引きずった量の積が溢れる、外から届いた量が無限、のどれでも同じ扱いになる。
    /// 進めなかった軸の速さは捨てる。寄りは指数が有限なら掛けてから限界へ収める (溢れて
    /// 無限になった距離は上限へ。引いたつもりで最も寄った位置へ飛ばない)。
    ///
    /// - Returns: 進めた先が有限にならず、進めなかった軸。知らせるのは呼ぶ側
    ///   (``SketchPart/orbitControl(_:_:_:)``) で、ここは面を持たない。**軸ごとに返す** —
    ///   呼ぶ側は、感度が使えなかった軸と、有限の感度で溢れた軸を分けて知らせる。
    ///
    /// [#2643]: https://github.com/mokume-metal/mokume/issues/2643
    @discardableResult
    mutating func advance(
        dragX: Float, dragY: Float, scroll: Float, isDragging: Bool,
        sensitivity: SIMD3<Float>
    ) -> HeldAxes {
        var held = HeldAxes()
        if isDragging {
            let turn = -dragX * sensitivity.x * Self.radiansPerPixel
            let tilt = dragY * sensitivity.y * Self.radiansPerPixel
            held.turn = !Self.step(&yaw, speed: &yawSpeed, by: turn)
            held.tilt = !Self.step(&pitch, speed: &pitchSpeed, by: tilt)
        } else if inertia > 0 {
            // 速さは有限に保ってあるので、溢れるのは角が極端に大きいときだけ
            Self.step(&yaw, speed: &yawSpeed, by: yawSpeed)
            Self.step(&pitch, speed: &pitchSpeed, by: pitchSpeed)
            let keep = min(inertia, 0.99)
            yawSpeed *= keep
            pitchSpeed *= keep
        } else {
            yawSpeed = 0
            pitchSpeed = 0
        }

        // 数でない・無限のスクロールも、指数が有限にならないので下で進めない側へ入る
        if scroll != 0 {
            let exponent = -scroll * sensitivity.z * Self.zoomPerScroll
            let (lower, upper) = distanceLimits
            let next = exponent.isFinite ? distance * RuntimeMath.exp(exponent) : .nan
            // 収めた先が有限なら進める。溢れた +∞ は上限へ、0 へ潰れたら下限へ収まる
            let clamped = next.isNaN ? next : min(max(next, lower), upper)
            if clamped.isFinite { distance = clamped } else { held.zoom = true }
        }
        clampToLimits()
        return held
    }

    /// ``advance(dragX:dragY:scroll:isDragging:sensitivity:)`` が進めなかった軸。
    struct HeldAxes: Equatable {
        /// 横 (水平角)。
        var turn = false
        /// 縦 (仰角)。
        var tilt = false
        /// 寄り (距離)。
        var zoom = false
        /// どれかを進めなかったか。
        var any: Bool { turn || tilt || zoom }
    }

    /// 角を 1 段進め、続く速さをその量にする。進めた先が有限にならないなら角を動かさず、
    /// 速さを捨てて偽を返す。
    @discardableResult
    private static func step(_ angle: inout Float, speed: inout Float, by amount: Float) -> Bool {
        let next = angle + amount
        guard next.isFinite else {
            speed = 0
            return false
        }
        angle = next
        speed = amount
        return true
    }

    /// 寄れる限界と引ける限界 (逆さに書かれていても小さいほうが下)。**無限の限界も
    /// この規則で読む** — `minimumDistance = .infinity; maximumDistance = 500` は
    /// 「500 より遠く」。使えないのは数でない値だけで、それは ``clampToLimits(fallbackCenter:)``
    /// が既定へ倒す。
    private var distanceLimits: (lower: Float, upper: Float) {
        (min(minimumDistance, maximumDistance), max(minimumDistance, maximumDistance))
    }

    /// 限界へ収める。**手で書いた値にも効く** — 公開している以上、外から限界の外を
    /// 置かれうるので、進めるときにも当てるときにも同じ規則を通す。
    ///
    /// 限界の外は収める。**収めようのない値** (数でない値・無限の角・限界の無い側の無限)
    /// は既定へ倒す: 見ている先は `fallbackCenter`、角は 0、距離は下限 (下限も無限なら上限、
    /// 両方とも無限なら 1)、数でない限界は寄れる側 1・引ける側は無し (無限)、慣性は 0
    /// (``init(center:distance:yaw:pitch:inertia:minimumDistance:maximumDistance:)``
    /// の既定)。速さの数でない値・無限も捨てる — 残すと慣性のあるかぎり毎フレーム角を
    /// 倒し続ける ([#2643])。
    ///
    /// - Parameter fallbackCenter: 見ている先が数でない・無限のときに置く先。書く口は面の
    ///   中央 (``fitting(width:height:)`` の見ている先) を渡す。
    /// - Returns: 既定へ倒した値があったか。書く口 (``SketchPart/orbit``) が警告する。
    @discardableResult
    mutating func clampToLimits(fallbackCenter: SIMD3<Float> = .zero) -> Bool {
        var fellBack = false
        if !(center.x.isFinite && center.y.isFinite && center.z.isFinite) {
            center = fallbackCenter
            fellBack = true
        }
        if !pitch.isFinite {
            pitch = 0
            fellBack = true
        }
        if !yaw.isFinite {
            yaw = 0
            fellBack = true
        }
        if inertia.isNaN {
            inertia = 0
            fellBack = true
        }
        if minimumDistance.isNaN {
            minimumDistance = 1
            fellBack = true
        }
        if maximumDistance.isNaN {
            maximumDistance = .infinity
            fellBack = true
        }
        if !yawSpeed.isFinite { yawSpeed = 0 }
        if !pitchSpeed.isFinite { pitchSpeed = 0 }
        pitch = min(max(pitch, -Self.pitchLimit), Self.pitchLimit)
        let (lower, upper) = distanceLimits
        let clamped = distance.isNaN ? distance : min(max(distance, lower), upper)
        if clamped.isFinite {
            distance = clamped
        } else {
            distance = lower.isFinite ? lower : upper.isFinite ? upper : 1
            fellBack = true
        }
        return fellBack
    }
}
