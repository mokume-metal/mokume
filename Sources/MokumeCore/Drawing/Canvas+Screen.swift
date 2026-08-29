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

    /// 点が、いまの変換でどこへ移るか (横)。
    public func screenX(_ x: Float, _ y: Float) -> Float { transform.apply(x: x, y: y).x }

    public func screenY(_ x: Float, _ y: Float) -> Float { transform.apply(x: x, y: y).y }

    // 奥行きを持つ点が、いまの変換といまの視点でどこへ移るか (横)。
    public func screenX(_ x: Float, _ y: Float, _ z: Float) -> Float {
        screenPosition(x, y, z).x
    }

    public func screenY(_ x: Float, _ y: Float, _ z: Float) -> Float {
        screenPosition(x, y, z).y
    }

    public func screenZ(_ x: Float, _ y: Float, _ z: Float) -> Float {
        screenPosition(x, y, z).z
    }

    // MARK: - 画面 → 空間

    // 面の位置が、いまの視点で空間のどこを指すか。
    public func spacePosition(screenX: Float, screenY: Float, depth: Float) -> SIMD3<Float> {
        // 潰れた変換 (どこかの軸を 0 倍したもの) には打ち消しが無い = 戻し先が決まらない
        guard let undo = transform.inverted else { return .zero }
        let inside =
            Self.makeProjection(width: width, height: height)
            * SIMD4<Float>(screenX, screenY, depth, 1)
        // **割るのは変換を戻したあと。** 変換の 4 行目は (0, 0, 0, 1) なので割る順序は
        // 結果を変えないが、先に割ると視点の逆行列だけで閉じたように読めてしまう
        let point = undo.matrix * (viewProjection.inverse * inside)
        let position = SIMD3(point.x, point.y, point.z) / point.w
        guard Camera.isDrawable(position.x, position.y, position.z) else { return .zero }
        return position
    }

    // MARK: - 中身

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
        let clip = viewProjection * transform.matrix * SIMD4<Float>(x, y, z, 1)
        let inside = SIMD4<Float>(SIMD3(clip.x, clip.y, clip.z) / clip.w, 1)
        let screen = Self.makeProjection(width: width, height: height).inverse * inside
        guard Camera.isDrawable(screen.x, screen.y, screen.z) else { return .zero }
        return SIMD3(screen.x, screen.y, screen.z)
    }
}
