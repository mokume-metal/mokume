// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 面の座標と空間の座標を行き来する。意味の説明は ``Sketch`` 側が正本
// ([ADR-0020] 決定 4)。
//
// **画素と切り取りの立方体の対応は 1 か所から取る** — 平面の図形が通る写像
// (``Canvas/makeProjection(width:height:)``) そのものと、その逆である。ここで別の式を
// 立てると、「奥行き 0 の面は平面の図形とぴったり重なる」([ADR-0021] 決定 1) が
// 定義の上では成り立たなくなり、破れても絵が少しずれるだけで気付けない。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
extension Canvas {

    // MARK: - 空間 → 画面

    /// 平面の点が、いまの変換といまの視点でどこへ移るか (横)。
    ///
    /// **平面の図形が描かれる位置と同じ式を通す** ([#3830])。素の場合 (既定の視点で、変換が平面を奥行き 0 の面に
    /// 保つ) は変換の x・y そのもので、いままでと 1 ビットも変わらない。視点を決めた・奥行きのある変換の下では、
    /// 奥行き 0 の点として視点を通した位置 (``screenX(_:_:_:)`` の z = 0) を返す。
    ///
    /// [#3830]: https://github.com/mokume-metal/mokume/issues/3830
    public func screenX(_ x: Double, _ y: Double) -> Double {
        let (x, y) = (x.asFloat, y.asFloat)
        return Double(flatScreenPosition(x, y).x)
    }

    public func screenY(_ x: Double, _ y: Double) -> Double {
        let (x, y) = (x.asFloat, y.asFloat)
        return Double(flatScreenPosition(x, y).y)
    }

    // 奥行きを持つ点が、いまの変換といまの視点でどこへ移るか (横)。
    public func screenX(_ x: Double, _ y: Double, _ z: Double) -> Double {
        let (x, y, z) = (x.asFloat, y.asFloat, z.asFloat)
        return Double(screenPosition(x, y, z).x)
    }

    public func screenY(_ x: Double, _ y: Double, _ z: Double) -> Double {
        let (x, y, z) = (x.asFloat, y.asFloat, z.asFloat)
        return Double(screenPosition(x, y, z).y)
    }

    public func screenZ(_ x: Double, _ y: Double, _ z: Double) -> Double {
        let (x, y, z) = (x.asFloat, y.asFloat, z.asFloat)
        return Double(screenPosition(x, y, z).z)
    }

    // MARK: - 画面 → 空間

    // 面の位置が、いまの視点で空間のどこを指すか。
    public func spacePosition(screenX: Double, screenY: Double, depth: Double) -> Vector3 {
        let (screenX, screenY, depth) = (screenX.asFloat, screenY.asFloat, depth.asFloat)
        // 潰れた変換 (どこかの軸を 0 倍したもの。判定は `Transform.isCollapsed`) には
        // 打ち消しが無い = 戻し先が決まらない。倍率が小さいだけなら打ち消しはある (#1541)
        noteTransformRead()
        guard let undo = transform.inverted else { return Vector3(0, 0, 0) }
        let inside =
            Self.makeProjection(width: Float(width), height: Float(height))
            * SIMD4<Float>(screenX, screenY, depth, 1)
        // **割るのは変換を戻したあと。** 変換の 4 行目は (0, 0, 0, 1) なので割る順序は
        // 結果を変えないが、先に割ると視点の逆行列だけで閉じたように読めてしまう
        let point = undo.matrix * (viewProjection.inverse * inside)
        let position = SIMD3(point.x, point.y, point.z) / point.w
        guard Camera.isDrawable(position.x, position.y, position.z) else { return Vector3(0, 0, 0) }
        return Vector3(position)
    }

    // MARK: - 中身

    /// 平面の点 (x, y) の画面の位置。素の場合は変換の x・y、そうでなければ奥行き 0 の点として視点を通す。
    private func flatScreenPosition(_ x: Float, _ y: Float) -> SIMD2<Float> {
        noteTransformRead()
        guard currentFlatView.clip != nil else { return transform.placed(x: x, y: y) }
        let screen = screenPosition(x, y, 0)
        return SIMD2(screen.x, screen.y)
    }

    /// いまの変換といまの視点を通した、面の上の位置 (x, y) と奥行きの面の値 (z)。
    ///
    /// **3 本の入口で 1 つの式を共有する。** 横・縦・奥行きで別々に立てると、視点の
    /// 扱いが 3 か所に散り、片方だけ直した誤りが「横は合うのに縦がずれる」形で残る。
    ///
    /// **番人は出口の 1 枚だけにする** — 読み取りは決して落ちない ([ADR-0020] 決定 5)。
    ///
    /// 数として置けない入力・割れない同次座標 (視点と同じ高さに来た点)・行列を通して
    /// 溢れた値は、**どれも結果が数でなくなる形で現れる**。入口や途中にもう 1 枚
    /// 置いても捕まる場所は増えず、消しても検査が緑のままの番人になる。
    private func screenPosition(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
        noteTransformRead()
        let clip = viewProjection * transform.matrix * SIMD4<Float>(x, y, z, 1)
        let inside = SIMD4<Float>(SIMD3(clip.x, clip.y, clip.z) / clip.w, 1)
        let screen = Self.makeProjection(width: Float(width), height: Float(height)).inverse * inside
        guard Camera.isDrawable(screen.x, screen.y, screen.z) else { return .zero }
        return SIMD3(screen.x, screen.y, screen.z)
    }
}
