// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 光と質感の色を素の数値で指定する口 (ADR-0033 決定 1・7)。手本が持つ形だけを
// 足すので、向きを持つ光には gray 形も alpha 形も無い。

extension Canvas {
    public func ambientLight(_ gray: Double) {
        let gray = gray.asFloat
        ambientLight(Double(gray), Double(gray), Double(gray))
    }

    public func ambientLight(_ red: Double, _ green: Double, _ blue: Double) {
        let (red, green, blue) = (red.asFloat, green.asFloat, blue.asFloat)
        guard let color = DisplayScale.color(
            red: red, green: green, blue: blue, alpha: 255)
        else {
            return refuseLightColor(.ambientLight)
        }
        ambientLight(color)
    }

    public func directionalLight(
        _ red: Double, _ green: Double, _ blue: Double, _ x: Double, _ y: Double, _ z: Double
    ) {
        let (red, green, blue, x, y, z) = (red.asFloat, green.asFloat, blue.asFloat, x.asFloat, y.asFloat, z.asFloat)
        guard let color = DisplayScale.color(
            red: red, green: green, blue: blue, alpha: 255)
        else {
            return refuseLightColor(.directionalLight)
        }
        directionalLight(color, Double(x), Double(y), Double(z))
    }

    public func pointLight(
        _ red: Double, _ green: Double, _ blue: Double, _ x: Double, _ y: Double, _ z: Double
    ) {
        let (red, green, blue, x, y, z) = (red.asFloat, green.asFloat, blue.asFloat, x.asFloat, y.asFloat, z.asFloat)
        guard let color = DisplayScale.color(
            red: red, green: green, blue: blue, alpha: 255)
        else {
            return refuseLightColor(.pointLight)
        }
        pointLight(color, Double(x), Double(y), Double(z))
    }

    public func spotLight(
        _ red: Double, _ green: Double, _ blue: Double,
        _ x: Double, _ y: Double, _ z: Double,
        _ directionX: Double, _ directionY: Double, _ directionZ: Double,
        angle: Double = Double.pi / 6
    ) {
        let (red, green, blue, x, y, z, directionX, directionY, directionZ, angle) = (red.asFloat, green.asFloat, blue.asFloat, x.asFloat, y.asFloat, z.asFloat, directionX.asFloat, directionY.asFloat, directionZ.asFloat, angle.asFloat)
        guard let color = DisplayScale.color(
            red: red, green: green, blue: blue, alpha: 255)
        else {
            return refuseLightColor(.spotLight)
        }
        spotLight(color, Double(x), Double(y), Double(z), Double(directionX), Double(directionY), Double(directionZ), angle: Double(angle))
    }

    public func ambient(_ gray: Double) {
        let gray = gray.asFloat
        ambient(Double(gray), Double(gray), Double(gray))
    }

    public func ambient(_ red: Double, _ green: Double, _ blue: Double) {
        let (red, green, blue) = (red.asFloat, green.asFloat, blue.asFloat)
        guard let color = DisplayScale.color(
            red: red, green: green, blue: blue, alpha: 255)
        else {
            return refuseMaterialColor(.ambient)
        }
        ambient(color)
    }

    public func emissive(_ gray: Double) {
        let gray = gray.asFloat
        emissive(Double(gray), Double(gray), Double(gray))
    }

    public func emissive(_ red: Double, _ green: Double, _ blue: Double) {
        let (red, green, blue) = (red.asFloat, green.asFloat, blue.asFloat)
        guard let color = DisplayScale.color(
            red: red, green: green, blue: blue, alpha: 255)
        else {
            return refuseMaterialColor(.emissive)
        }
        emissive(color)
    }
}
