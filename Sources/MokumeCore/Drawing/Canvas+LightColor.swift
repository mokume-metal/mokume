// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 光と質感の色を素の数値で指定する口 (ADR-0033 決定 1・7)。手本が持つ形だけを
// 足すので、向きを持つ光には gray 形も alpha 形も無い。
//
// **説明文は置かない。** 正本は上の層 (ADR-0020 決定 4)。この覚え書きが宣言の
// 説明文として拾われないよう、宣言との間は必ず 1 行空ける。

extension Canvas {
    public func ambientLight(_ gray: some ScalarConvertible) {
        let gray = gray.asFloat
        ambientLight(gray, gray, gray)
    }

    public func ambientLight(_ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible) {
        let (red, green, blue) = (red.asFloat, green.asFloat, blue.asFloat)
        guard let color = DisplayScale.color(
            red: red, green: green, blue: blue, alpha: 255)
        else {
            return warnNotANumberColor(.ambientLight)
        }
        ambientLight(color)
    }

    public func directionalLight(
        _ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible, _ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible
    ) {
        let (red, green, blue, x, y, z) = (red.asFloat, green.asFloat, blue.asFloat, x.asFloat, y.asFloat, z.asFloat)
        guard let color = DisplayScale.color(
            red: red, green: green, blue: blue, alpha: 255)
        else {
            return warnNotANumberColor(.directionalLight)
        }
        directionalLight(color, x, y, z)
    }

    public func pointLight(
        _ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible, _ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible
    ) {
        let (red, green, blue, x, y, z) = (red.asFloat, green.asFloat, blue.asFloat, x.asFloat, y.asFloat, z.asFloat)
        guard let color = DisplayScale.color(
            red: red, green: green, blue: blue, alpha: 255)
        else {
            return warnNotANumberColor(.pointLight)
        }
        pointLight(color, x, y, z)
    }

    public func spotLight(
        _ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible,
        _ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible,
        _ directionX: some ScalarConvertible, _ directionY: some ScalarConvertible, _ directionZ: some ScalarConvertible,
        angle: some ScalarConvertible = Float.pi / 6
    ) {
        let (red, green, blue, x, y, z, directionX, directionY, directionZ, angle) = (red.asFloat, green.asFloat, blue.asFloat, x.asFloat, y.asFloat, z.asFloat, directionX.asFloat, directionY.asFloat, directionZ.asFloat, angle.asFloat)
        guard let color = DisplayScale.color(
            red: red, green: green, blue: blue, alpha: 255)
        else {
            return warnNotANumberColor(.spotLight)
        }
        spotLight(color, x, y, z, directionX, directionY, directionZ, angle: angle)
    }

    public func ambient(_ gray: some ScalarConvertible) {
        let gray = gray.asFloat
        ambient(gray, gray, gray)
    }

    public func ambient(_ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible) {
        let (red, green, blue) = (red.asFloat, green.asFloat, blue.asFloat)
        guard let color = DisplayScale.color(
            red: red, green: green, blue: blue, alpha: 255)
        else {
            return warnNotANumberColor(.ambient)
        }
        ambient(color)
    }

    public func emissive(_ gray: some ScalarConvertible) {
        let gray = gray.asFloat
        emissive(gray, gray, gray)
    }

    public func emissive(_ red: some ScalarConvertible, _ green: some ScalarConvertible, _ blue: some ScalarConvertible) {
        let (red, green, blue) = (red.asFloat, green.asFloat, blue.asFloat)
        guard let color = DisplayScale.color(
            red: red, green: green, blue: blue, alpha: 255)
        else {
            return warnNotANumberColor(.emissive)
        }
        emissive(color)
    }
}
