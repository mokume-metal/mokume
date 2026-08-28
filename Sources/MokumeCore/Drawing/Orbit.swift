// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 注視点のまわりを回る視点の操作。
///
/// 見ている先・そこからの距離・水平角・仰角を持ち、引きずった量とスクロールから
/// 進む。``Sketch/orbitControl(_:_:_:)`` が毎フレームこれを進めて視点を当てる。
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
    /// **既定の視点 (``Camera/fitting(width:height:)``) と同じ位置に置く。** だから
    /// `orbitControl()` を足しただけでは絵が動かない。寄り・引きの限界も既定の投影の
    /// 手前・奥の面に合わせるので、限界まで動かしても切れない。
    public static func fitting(width: Float, height: Float) -> Orbit {
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
            sin(yaw) * cos(pitch), -sin(pitch), cos(yaw) * cos(pitch))
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
    mutating func advance(
        dragX: Float, dragY: Float, scroll: Float, isDragging: Bool,
        sensitivity: SIMD3<Float>
    ) {
        if isDragging {
            let turn = -dragX * sensitivity.x * Self.radiansPerPixel
            let tilt = dragY * sensitivity.y * Self.radiansPerPixel
            yaw += turn
            pitch += tilt
            yawSpeed = turn
            pitchSpeed = tilt
        } else if inertia > 0 {
            yaw += yawSpeed
            pitch += pitchSpeed
            let keep = min(inertia, 0.99)
            yawSpeed *= keep
            pitchSpeed *= keep
        } else {
            yawSpeed = 0
            pitchSpeed = 0
        }

        if scroll != 0, scroll.isFinite {
            distance *= exp(-scroll * sensitivity.z * Self.zoomPerScroll)
        }
        clampToLimits()
    }

    /// 限界へ収める。**手で書いた値にも効く** — 公開している以上、外から限界の外を
    /// 置かれうるので、進めるときにも当てるときにも同じ規則を通す。
    mutating func clampToLimits() {
        if !pitch.isFinite { pitch = 0 }
        if !yaw.isFinite { yaw = 0 }
        pitch = min(max(pitch, -Self.pitchLimit), Self.pitchLimit)
        let lower = min(minimumDistance, maximumDistance)
        let upper = max(minimumDistance, maximumDistance)
        distance = distance.isFinite ? min(max(distance, lower), upper) : lower
    }
}
