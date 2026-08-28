// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// どこから、どう見るか。**視点 (どこから・どこを見て・どちらが上か) と投影の組**。
///
/// 値なので、作って持ち回して、あとから当て直せる。視点はシーンの記述なので
/// フレームを越えない ([ADR-0021] 決定 4) — つまり**状態としてしか持てないと、
/// 複数の視点を切り替える書き方ができない**。値で持てる形にしてあるのはそのためで、
/// 初期化のときに作っておいて毎フレーム当てる、という書き方が成り立つ。
///
/// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
public struct Camera: Equatable, Sendable {

    /// どう写すか。
    public enum Projection: Equatable, Sendable {
        /// 遠くのものほど小さく写す。
        ///
        /// - Parameters:
        ///   - fieldOfView: 縦方向の画角 (ラジアン)。
        ///   - aspect: 横 ÷ 縦の比。
        ///   - near: 手前の面までの距離。これより手前は写らない。
        ///   - far: 奥の面までの距離。これより奥は写らない。
        case perspective(fieldOfView: Float, aspect: Float, near: Float, far: Float)

        /// 距離によらず同じ大きさで写す。
        ///
        /// 範囲は**視点から見た座標**で与える。`top` と `bottom` は画面の上端・下端を
        /// 指す — 縦軸が下向きなので `top` のほうが数として小さくなる
        /// ([ADR-0021] 決定 1 の「画面の側を正とする」)。
        case orthographic(
            left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float)
    }

    /// 見る位置 (世界の座標)。
    public var eye: SIMD3<Float>
    /// 見ている先 (世界の座標)。
    public var center: SIMD3<Float>
    /// どちらを上とするか。
    public var up: SIMD3<Float>
    /// どう写すか。
    public var projection: Projection

    public init(
        eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>, projection: Projection
    ) {
        self.eye = eye
        self.center = center
        self.up = up
        self.projection = projection
    }

    // MARK: - 既定

    /// 既定の画角 (縦方向・ラジアン)。
    static let defaultFieldOfView: Float = .pi / 3

    /// 面がちょうど収まる距離。
    ///
    /// 既定の視点はここに置く。だから何も指定せずに置いた立体は**画素の大きさで
    /// 見える** — `box(120)` は 120 画素の箱として出る ([ADR-0021] 決定 1)。
    static func fittingDistance(height: Float) -> Float {
        (height / 2) / tan(defaultFieldOfView / 2)
    }

    /// 面がちょうど収まる位置から、面の正面を見る視点。
    ///
    /// **投影の既定値もここから導く。** 「よくある固定値」で決めると既定の視点と
    /// 噛み合わず、何も指定せずに置いた被写体が隅へ寄る・奥が切れる。
    static func fitting(width: Float, height: Float) -> Camera {
        let distance = fittingDistance(height: height)
        return Camera(
            eye: SIMD3(width / 2, height / 2, distance),
            center: SIMD3(width / 2, height / 2, 0),
            up: SIMD3(0, 1, 0),
            projection: defaultPerspective(width: width, height: height))
    }

    /// 既定の透視投影。手前と奥の面は、面がちょうど収まる距離から導く。
    static func defaultPerspective(width: Float, height: Float) -> Projection {
        let distance = fittingDistance(height: height)
        return .perspective(
            fieldOfView: defaultFieldOfView, aspect: width / height,
            near: distance / 10, far: distance * 10)
    }

    /// 既定の平行投影。範囲は視点を中心に面 1 枚ぶん。
    ///
    /// この選び方だと、**奥行き 0 に置いたものが平面の図形とぴったり重なる** —
    /// 透視投影の既定と同じ性質で、既定どうしが噛み合っていることの現れである。
    static func defaultOrthographic(width: Float, height: Float) -> Projection {
        let distance = fittingDistance(height: height)
        // 縦軸は下向きなので、画面の上端が -height/2、下端が +height/2 になる
        return .orthographic(
            left: -width / 2, right: width / 2,
            bottom: height / 2, top: -height / 2,
            near: distance / 10, far: distance * 10)
    }

    // MARK: - 視点の枠

    /// 視線が進む向き。**奥行きの正の側が手前** ([ADR-0021] 決定 1)。
    var forward: SIMD3<Float> {
        let toward = center - eye
        return length_squared(toward) > 0 ? normalize(toward) : SIMD3(0, 0, -1)
    }

    /// 画面の横方向 (世界の向き)。
    var right: SIMD3<Float> {
        let back = -forward
        let side = cross(up, back)
        if length_squared(side) > 0 { return normalize(side) }
        // 上方向と視線が重なっていると横が決まらない。視線と重ならない軸へ倒す
        let axis: SIMD3<Float> = abs(back.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        return normalize(cross(axis, back))
    }

    /// 画面の縦方向 (世界の向き)。**画面の下へ向かう** — 縦軸が下向きだから。
    var down: SIMD3<Float> { cross(-forward, right) }

    /// 見ている場所を、断片が使える形で表したもの。
    ///
    /// 透視は**視点の位置** (`w` = 1)、平行は**見ている側へ向かう一定の向き**
    /// (`w` = 0)。平行では面から目までの向きが場所によらないので、位置を渡すと
    /// 艶だけが透視のように歪む。
    var viewer: SIMD4<Float> {
        switch projection {
        case .perspective: SIMD4(eye, 1)
        case .orthographic: SIMD4(-forward, 0)
        }
    }

    /// その位置での、画面 1 画素ぶんの世界での長さ。
    ///
    /// 線の太さは画面の画素で測る約束なので、遠いものほど世界では広く作る。
    /// **視点の情報はここ 1 箇所から取る** — 視点が変わっても式が散らばらない。
    func worldPerPixel(at position: SIMD3<Float>, height: Float) -> Float {
        switch projection {
        case let .perspective(fieldOfView, _, near, _):
            let depth = max(dot(position - eye, forward), near)
            return 2 * tan(fieldOfView / 2) * depth / height
        case let .orthographic(_, _, bottom, top, _, _):
            // 距離によらず同じ大きさで写るので、奥行きを見ない
            return abs(bottom - top) / height
        }
    }

    // MARK: - 行列

    /// 立体を落とす行列。
    ///
    /// **奥行き 0 の面は、平面の図形とぴったり重なる。** 既定の距離をそう選び、
    /// 平面と同じ半画素のずらしを掛けているためで、そのことは検査で固定してある。
    func viewProjection(width: Float, height: Float) -> simd_float4x4 {
        Self.clipAdjustment(width: width, height: height) * projectionMatrix * viewMatrix
    }

    /// 世界をカメラの側へ移す行列。
    var viewMatrix: simd_float4x4 {
        let back = -forward
        let side = right
        let above = cross(back, side)
        return simd_float4x4(
            SIMD4(side.x, above.x, back.x, 0),
            SIMD4(side.y, above.y, back.y, 0),
            SIMD4(side.z, above.z, back.z, 0),
            SIMD4(-dot(side, eye), -dot(above, eye), -dot(back, eye), 1))
    }

    /// 見えている範囲を、切り取りの立方体へ落とす行列。
    var projectionMatrix: simd_float4x4 {
        switch projection {
        case let .perspective(fieldOfView, aspect, near, far):
            let y = 1 / tan(fieldOfView / 2)
            let x = y / aspect
            let z = far / (near - far)
            return simd_float4x4(
                SIMD4(x, 0, 0, 0),
                SIMD4(0, y, 0, 0),
                SIMD4(0, 0, z, -1),
                SIMD4(0, 0, z * near, 0))
        case let .orthographic(left, right, bottom, top, near, far):
            // 縦は ``clipAdjustment`` が反転させるので、**画面の下端**を正の側に入れる。
            // ここを行列の慣行 (上端が正) のまま書くと、絵が黙って上下逆になる
            return simd_float4x4(
                SIMD4(2 / (right - left), 0, 0, 0),
                SIMD4(0, 2 / (bottom - top), 0, 0),
                SIMD4(0, 0, 1 / (near - far), 0),
                SIMD4(
                    -(right + left) / (right - left), -(bottom + top) / (bottom - top),
                    near / (near - far), 1))
        }
    }

    /// 縦軸を下向きに保ち、平面と同じ半画素のずらしを掛ける。
    ///
    /// 縦軸は 2 度反転する — 投影が持つ「上が +y」と、この行列の反転で、世界の +y が
    /// 画面の下になる。平面の約束をそのまま延長するための補正である ([ADR-0021] 決定 1)。
    static func clipAdjustment(width: Float, height: Float) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, -1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(1 / width, -1 / height, 0, 1))
    }

    // MARK: - 置けるか

    /// 数として置けるか。**数でない値・無限は絵を丸ごと消す**ので、受け口で弾く。
    static func isDrawable(_ values: Float...) -> Bool {
        values.allSatisfy { $0.isFinite }
    }

    /// 視点として成り立つか。
    ///
    /// 見る位置と見ている先が同じだと視線の向きが決まらず、上方向が視線と重なると
    /// 横が決まらない。どちらも行列が壊れて絵が丸ごと消えるので、当てる前に見る。
    var isUsable: Bool {
        guard Self.isDrawable(eye.x, eye.y, eye.z, center.x, center.y, center.z),
            Self.isDrawable(up.x, up.y, up.z)
        else { return false }
        guard length_squared(center - eye) > 0, length_squared(up) > 0 else { return false }
        return length_squared(cross(up, eye - center)) > 0
    }
}
