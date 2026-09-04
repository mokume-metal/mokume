// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

extension Sketch {
    /// 全体を底上げする光を、素の数値で置く。**目盛りは 0–255** ([ADR-0033] 決定 1)。
    ///
    /// ```swift
    /// ambientLight(90, 95, 110)
    /// ```
    ///
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    public func ambientLight(_ red: Float, _ green: Float, _ blue: Float) {
        canvas.ambientLight(red, green, blue)
    }

    /// 全体を底上げする光を、灰色の明るさで置く。**目盛りは 0–255**。
    ///
    /// ```swift
    /// ambientLight(90)
    /// ```
    public func ambientLight(_ gray: Float) {
        canvas.ambientLight(gray)
    }

    /// 向きだけを持つ光を、素の数値で置く。**目盛りは 0–255**。
    ///
    /// 色の 3 つに続けて、光が**進む向き**を渡す。
    ///
    /// ```swift
    /// directionalLight(255, 244, 214, -0.5, 1, -0.3)
    /// ```
    ///
    /// - Note: 光には不透明度も灰色 1 つの形も無い — 手本が持たないためで、
    ///   「光の不透明度」が何を指すのかを説明できない ([ADR-0033] 決定 7)。
    ///
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    public func directionalLight(
        _ red: Float, _ green: Float, _ blue: Float, _ x: Float, _ y: Float, _ z: Float
    ) {
        canvas.directionalLight(red, green, blue, x, y, z)
    }

    /// 位置を持つ光を、素の数値で置く。**目盛りは 0–255**。
    ///
    /// ```swift
    /// pointLight(255, 214, 170, 200, 80, 120)
    /// ```
    public func pointLight(
        _ red: Float, _ green: Float, _ blue: Float, _ x: Float, _ y: Float, _ z: Float
    ) {
        canvas.pointLight(red, green, blue, x, y, z)
    }

    /// 位置と向きと広がりを持つ光を、素の数値で置く。**目盛りは 0–255**。
    ///
    /// 色の 3 つ、光源の位置、光が進む向き、の順。`angle` は円錐の半頂角 (radian)。
    ///
    /// ```swift
    /// spotLight(255, 230, 190, 200, 40, 200, 0, 1, 0, angle: 0.5)
    /// ```
    public func spotLight(
        _ red: Float, _ green: Float, _ blue: Float,
        _ x: Float, _ y: Float, _ z: Float,
        _ directionX: Float, _ directionY: Float, _ directionZ: Float,
        angle: Float = .pi / 6
    ) {
        canvas.spotLight(
            red, green, blue, x, y, z, directionX, directionY, directionZ, angle: angle)
    }

    /// 面が光を受けたときに返す色を、素の数値で決める。**目盛りは 0–255**。
    ///
    /// ```swift
    /// ambient(200, 120, 90)
    /// ```
    public func ambient(_ red: Float, _ green: Float, _ blue: Float) {
        canvas.ambient(red, green, blue)
    }

    /// 面が光を受けたときに返す色を、灰色の明るさで決める。**目盛りは 0–255**。
    ///
    /// ```swift
    /// ambient(180)
    /// ```
    public func ambient(_ gray: Float) {
        canvas.ambient(gray)
    }

    /// 面が自分で出す光を、素の数値で決める。**目盛りは 0–255**。
    ///
    /// ```swift
    /// emissive(40, 90, 140)
    /// ```
    public func emissive(_ red: Float, _ green: Float, _ blue: Float) {
        canvas.emissive(red, green, blue)
    }

    /// 面が自分で出す光を、灰色の明るさで決める。**目盛りは 0–255**。
    ///
    /// ```swift
    /// emissive(60)
    /// ```
    public func emissive(_ gray: Float) {
        canvas.emissive(gray)
    }
}
