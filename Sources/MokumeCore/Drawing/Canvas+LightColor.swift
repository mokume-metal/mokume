// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 光と質感の色を素の数値で指定する口 (ADR-0033 決定 1・7)。手本が持つ形だけを
// 足すので、向きを持つ光には gray 形も alpha 形も無い。
//
// **説明文は置かない。** 正本は上の層 (ADR-0020 決定 4)。この覚え書きが宣言の
// 説明文として拾われないよう、宣言との間は必ず 1 行空ける。

extension Canvas {
    public func ambientLight(_ gray: Float) {
        ambientLight(gray, gray, gray)
    }

    public func ambientLight(_ red: Float, _ green: Float, _ blue: Float) {
        guard let color = DisplayScale.color(
            red: red, green: green, blue: blue, alpha: 255)
        else {
            return warnOnce(
                .notANumberAmbientLight, "ambientLight(): 数でない値・無限の値が渡されたので、光を置きませんでした")
        }
        ambientLight(color)
    }

    public func directionalLight(
        _ red: Float, _ green: Float, _ blue: Float, _ x: Float, _ y: Float, _ z: Float
    ) {
        guard let color = DisplayScale.color(
            red: red, green: green, blue: blue, alpha: 255)
        else {
            return warnOnce(
                .notANumberDirectionalLight, "directionalLight(): 数でない値・無限の値が渡されたので、光を置きませんでした")
        }
        directionalLight(color, x, y, z)
    }

    public func pointLight(
        _ red: Float, _ green: Float, _ blue: Float, _ x: Float, _ y: Float, _ z: Float
    ) {
        guard let color = DisplayScale.color(
            red: red, green: green, blue: blue, alpha: 255)
        else {
            return warnOnce(
                .notANumberPointLight, "pointLight(): 数でない値・無限の値が渡されたので、光を置きませんでした")
        }
        pointLight(color, x, y, z)
    }

    public func spotLight(
        _ red: Float, _ green: Float, _ blue: Float,
        _ x: Float, _ y: Float, _ z: Float,
        _ directionX: Float, _ directionY: Float, _ directionZ: Float,
        angle: Float = .pi / 6
    ) {
        guard let color = DisplayScale.color(
            red: red, green: green, blue: blue, alpha: 255)
        else {
            return warnOnce(
                .notANumberSpotLight, "spotLight(): 数でない値・無限の値が渡されたので、光を置きませんでした")
        }
        spotLight(color, x, y, z, directionX, directionY, directionZ, angle: angle)
    }

    public func ambient(_ gray: Float) {
        ambient(gray, gray, gray)
    }

    public func ambient(_ red: Float, _ green: Float, _ blue: Float) {
        guard let color = DisplayScale.color(
            red: red, green: green, blue: blue, alpha: 255)
        else {
            return warnOnce(
                .notANumberAmbient, "ambient(): 数でない値・無限の値が渡されたので、質感を変えませんでした")
        }
        ambient(color)
    }

    public func emissive(_ gray: Float) {
        emissive(gray, gray, gray)
    }

    public func emissive(_ red: Float, _ green: Float, _ blue: Float) {
        guard let color = DisplayScale.color(
            red: red, green: green, blue: blue, alpha: 255)
        else {
            return warnOnce(
                .notANumberEmissive, "emissive(): 数でない値・無限の値が渡されたので、質感を変えませんでした")
        }
        emissive(color)
    }
}
