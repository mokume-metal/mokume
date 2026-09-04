// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 光を置く。明るさの単位と寿命は ``Light`` と [ADR-0021] 決定 4 が定める。
//
// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
extension Canvas {

    // 全体を底上げする光を置く。
    public func ambientLight(_ color: LinearRGBA) {
        addLight(Light(kind: .ambient, color: color))
    }

    // 向きだけを持つ光を置く。
    public func directionalLight(_ color: LinearRGBA, _ x: Float, _ y: Float, _ z: Float) {
        addLight(
            Light(kind: .directional, color: color, direction: transformedDirection(x, y, z)))
    }

    // 位置を持つ光を置く。
    public func pointLight(_ color: LinearRGBA, _ x: Float, _ y: Float, _ z: Float) {
        addLight(Light(kind: .point, color: color, position: transform.apply(x: x, y: y, z: z)))
    }

    // 位置と向きと広がりを持つ光を置く。
    public func spotLight(
        _ color: LinearRGBA, _ x: Float, _ y: Float, _ z: Float,
        _ directionX: Float, _ directionY: Float, _ directionZ: Float,
        angle: Float = .pi / 6
    ) {
        addLight(
            Light(
                kind: .spot, color: color,
                position: transform.apply(x: x, y: y, z: z),
                direction: transformedDirection(directionX, directionY, directionZ),
                coneCosine: cos(max(0, min(angle, .pi / 2)))))
    }

    // ひととおりの光を置く (底上げ + 斜め上から差す光)。
    public func lights() {
        // 縦軸は下向きなので、上から差す光が進む向きは +y
        ambientLight(.opaque(red: 0.35, green: 0.35, blue: 0.35))
        directionalLight(.opaque(red: 0.85, green: 0.85, blue: 0.85), -0.35, 0.75, -0.55)
    }

    // 置いた光をすべて取り除く。
    public func noLights() {
        guard !activeLights.isEmpty else { return }
        closeBatch()
        activeLights.removeAll(keepingCapacity: true)
    }

    /// 光を置き場へ足す。**列をその場で閉じる**ので、既に置いた立体は置いた時点の
    /// 光で描かれる ([ADR-0021] 決定 2 の「記録した列だけで絵が決まる」)。
    ///
    /// フレームの外 (初期化のとき) に置かれた光は、どのフレームにも属さないので
    /// 警告して無視する (同 決定 4)。黙って捨てると「書いたのに効かない」だけが残る。
    private func addLight(_ light: Light) {
        guard isDrawing else { return warnLightOutsideFrame() }
        closeBatch()
        activeLights.append(light)
    }

    /// 向きを、いまの変換で世界の向きへ移す。
    ///
    /// 位置ではないので平行移動は掛からない。**面の向きと同じ規則で移す** — 軸ごとに
    /// 違う倍率を掛けたときに、光と面の向きがずれないようにするためである。
    private func transformedDirection(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
        let direction = transform.normalMatrix * SIMD3<Float>(x, y, z)
        return length_squared(direction) > 0 ? normalize(direction) : SIMD3<Float>(0, 1, 0)
    }

    /// フレームの外で光を置いたことを、初回だけ知らせる。
    private func warnLightOutsideFrame() {
        warnOnce(
            .lightOutsideFrame,
            "光はフレームごとに置き直すものなので、描くところ (draw) で呼んでください。"
                + "初期化のときに置いた光はどのフレームにも属さないため、無視しました")
    }
}
