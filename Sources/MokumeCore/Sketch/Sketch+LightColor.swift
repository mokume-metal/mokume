// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

extension Sketch {
    /// 全体を底上げする光を、素の数値で置く。**目盛りは 0–255** ([ADR-0033] 決定 1)。
    ///
    /// 0…1 で書く (1 を超える明るさも書ける) のは ``LinearRGBA`` を受ける同じ名前の口
    /// ``ambientLight(_:)-fvb5`` のほうで、ここへ `0.52` のように渡すと「255 分の 0.52」になり、
    /// ほぼ光が無くなる。
    ///
    /// ```swift
    /// ambientLight(90, 95, 110)
    /// ```
    ///
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    public func ambientLight(_ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible) {
        let (red, green, blue) = (red.asFloat, green.asFloat, blue.asFloat)
        canvas.ambientLight(red, green, blue)
    }

    /// 全体を底上げする光を、灰色の明るさで置く。**目盛りは 0–255**。
    ///
    /// 0…1 で書く (1 を超える明るさも書ける) のは ``LinearRGBA`` を受ける同じ名前の口
    /// ``ambientLight(_:)-fvb5`` のほうで、ここへ `0.52` のように渡すと「255 分の 0.52」になり、
    /// ほぼ光が無くなる。
    ///
    /// ```swift
    /// ambientLight(90)
    /// ```
    public func ambientLight(_ gray: some ScalarConvertible) {
        let gray = gray.asFloat
        canvas.ambientLight(gray)
    }

    /// 向きだけを持つ光を、素の数値で置く。**目盛りは 0–255**。
    ///
    /// 0…1 で書く (1 を超える明るさも書ける) のは ``LinearRGBA`` を受ける同じ名前の口
    /// ``directionalLight(_:_:_:_:)`` のほうで、ここへ `0.52` のように渡すと「255 分の 0.52」になり、
    /// ほぼ光が無くなる。
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
    /// - Note: **手本と同じ数を渡しても、同じ明るさは出ない。** 素の数値は表示の目盛りで
    ///   受け、**線形の値へ戻してから**面に掛け、表示の値へ戻して画面に出す
    ///   ([ADR-0011] 決定 1)。手本は表示の値のまま掛けるので、光が斜めに当たって弱まる
    ///   分も表示の値の上で効く。こちらはそれが線形の値の上で効くので、**斜めに光を受ける
    ///   面ほど手本より明るく出る**。数値形の光の口
    ///   (`ambientLight` / `directionalLight` / `pointLight` / `spotLight`) はどれもこの形で
    ///   受ける。手本に揃えないのは、手本に従うのが名前と引数の順序までだからである
    ///   ([ADR-0020] 決定 1)。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [ADR-0033]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0033-color-specification-surface.md
    public func directionalLight(
        _ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible, _ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible
    ) {
        let (red, green, blue, x, y, z) = (red.asFloat, green.asFloat, blue.asFloat, x.asFloat, y.asFloat, z.asFloat)
        canvas.directionalLight(red, green, blue, x, y, z)
    }

    /// 位置を持つ光を、素の数値で置く。**目盛りは 0–255**。
    ///
    /// 0…1 で書く (1 を超える明るさも書ける) のは ``LinearRGBA`` を受ける同じ名前の口
    /// ``pointLight(_:_:_:_:)`` のほうで、ここへ `0.52` のように渡すと「255 分の 0.52」になり、
    /// ほぼ光が無くなる。
    ///
    /// ```swift
    /// pointLight(255, 214, 170, 200, 80, 120)
    /// ```
    public func pointLight(
        _ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible, _ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible
    ) {
        let (red, green, blue, x, y, z) = (red.asFloat, green.asFloat, blue.asFloat, x.asFloat, y.asFloat, z.asFloat)
        canvas.pointLight(red, green, blue, x, y, z)
    }

    /// 位置と向きと広がりを持つ光を、素の数値で置く。**目盛りは 0–255**。
    ///
    /// 0…1 で書く (1 を超える明るさも書ける) のは ``LinearRGBA`` を受ける同じ名前の口
    /// ``spotLight(_:_:_:_:_:_:_:angle:)`` のほうで、ここへ `0.52` のように渡すと「255 分の 0.52」になり、
    /// ほぼ光が無くなる。
    ///
    /// 色の 3 つ、光源の位置、光が進む向き、の順。`angle` は円錐の半頂角 (radian)。
    ///
    /// ```swift
    /// spotLight(255, 230, 190, 200, 40, 200, 0, 1, 0, angle: 0.5)
    /// ```
    public func spotLight(
        _ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible,
        _ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible,
        _ directionX: some ScalarConvertible, _ directionY: some ScalarConvertible, _ directionZ: some ScalarConvertible,
        angle: some ScalarConvertible = Float.pi / 6
    ) {
        let (red, green, blue, x, y, z, directionX, directionY, directionZ, angle) = (red.asFloat, green.asFloat, blue.asFloat, x.asFloat, y.asFloat, z.asFloat, directionX.asFloat, directionY.asFloat, directionZ.asFloat, angle.asFloat)
        canvas.spotLight(
            red, green, blue, x, y, z, directionX, directionY, directionZ, angle: angle)
    }

    /// 面が光を受けたときに返す色を、素の数値で決める。**目盛りは 0–255**。
    ///
    /// ```swift
    /// ambient(200, 120, 90)
    /// ```
    public func ambient(_ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible) {
        let (red, green, blue) = (red.asFloat, green.asFloat, blue.asFloat)
        canvas.ambient(red, green, blue)
    }

    /// 面が光を受けたときに返す色を、灰色の明るさで決める。**目盛りは 0–255**。
    ///
    /// ```swift
    /// ambient(180)
    /// ```
    public func ambient(_ gray: some ScalarConvertible) {
        let gray = gray.asFloat
        canvas.ambient(gray)
    }

    /// 面が自分で出す光を、素の数値で決める。**目盛りは 0–255**。
    ///
    /// ```swift
    /// emissive(40, 90, 140)
    /// ```
    public func emissive(_ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible) {
        let (red, green, blue) = (red.asFloat, green.asFloat, blue.asFloat)
        canvas.emissive(red, green, blue)
    }

    /// 面が自分で出す光を、灰色の明るさで決める。**目盛りは 0–255**。
    ///
    /// ```swift
    /// emissive(60)
    /// ```
    public func emissive(_ gray: some ScalarConvertible) {
        let gray = gray.asFloat
        canvas.emissive(gray)
    }
}
