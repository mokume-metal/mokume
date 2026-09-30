// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 光を置く。明るさの単位と寿命は ``Light`` と [ADR-0021] 決定 4 が定める。
//
// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
extension Canvas {

    // 全体を底上げする光を置く。
    public func ambientLight(_ color: LinearRGBA) {
        addLight(Light(kind: .ambient, color: color), color: color, entry: .ambientLight)
    }

    // 向きだけを持つ光を置く。
    public func directionalLight(_ color: LinearRGBA, _ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible) {
        let (x, y, z) = (x.asFloat, y.asFloat, z.asFloat)
        addLight(
            Light(kind: .directional, color: color, direction: transformedDirection(x, y, z)),
            color: color, entry: .directionalLight)
    }

    // 位置を持つ光を置く。
    public func pointLight(_ color: LinearRGBA, _ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible) {
        let (x, y, z) = (x.asFloat, y.asFloat, z.asFloat)
        addLight(
            Light(kind: .point, color: color, position: transform.apply(x: x, y: y, z: z)),
            color: color, entry: .pointLight)
    }

    // 位置と向きと広がりを持つ光を置く。
    public func spotLight(
        _ color: LinearRGBA, _ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible,
        _ directionX: some ScalarConvertible, _ directionY: some ScalarConvertible, _ directionZ: some ScalarConvertible,
        angle: some ScalarConvertible = Float.pi / 6
    ) {
        // フレームの外では光を置かないので、丸めの注意より先に断る (#1698 の反証 10)。
        // 丸めの注意を先に言うと、置かない光のために 1 度きりの鍵を使い切る
        guard isDrawing else { return warnOutsideFrame(.light) }
        // 色が受け取れないなら置かないので、丸めの注意より先に断る (同じ理由・#1706)
        guard color.isFinite else { return warnNotANumberColor(.spotLight) }
        let (x, y, z, directionX, directionY, directionZ, angle) = (x.asFloat, y.asFloat, z.asFloat, directionX.asFloat, directionY.asFloat, directionZ.asFloat, angle.asFloat)
        // 半頂角は 0…π/2 へ丸め、丸めたら 1 度知らせる (#1698)。書き順は `max(0, min(…))` に
        // 保つ — Swift の `min` / `max` は第 1 引数の NaN を返すので、この順なら NaN は 0 になる
        let used = max(0, min(angle, Float.pi / 2))
        if !Self.spotLightAngles.contains(angle) {
            warnRounded(
                .badSpotLightAngle, "spotLight", "angle", takes: "0 to pi / 2 (\(Float.pi / 2))",
                passed: angle, used: used)
        }
        addLight(
            Light(
                kind: .spot, color: color,
                position: transform.apply(x: x, y: y, z: z),
                direction: transformedDirection(directionX, directionY, directionZ),
                coneCosine: cos(used)),
            color: color, entry: .spotLight)
    }

    /// 知らせずに受け取る半頂角。**上の端は `Float.pi / 2` より 1 ulp 大きい所まで**
    /// ([#1698] の反証 8)。`Float.pi` は 0 の側へ丸めてあるので、`Double.pi / 2` を `Float` へ
    /// 移した値 (`asFloat`) は `Float.pi / 2` より 1 ulp 大きい。書いた人にとってはどちらも π/2
    /// である。丸め先はどちらも `Float.pi / 2` で変わらない。
    ///
    /// [#1698]: https://github.com/mokume-metal/mokume/issues/1698
    static let spotLightAngles: ClosedRange<Float> = 0...(Float.pi / 2).nextUp

    // ひととおりの光を置く (底上げ + 斜め上から差す光)。
    public func lights() {
        // 縦軸は下向きなので、上から差す光が進む向きは +y
        ambientLight(.linear(red: 0.35, green: 0.35, blue: 0.35))
        directionalLight(.linear(red: 0.85, green: 0.85, blue: 0.85), -0.35, 0.75, -0.55)
    }

    // 置いた光をすべて取り除く。
    public func noLights() {
        // 光の無いフレームの外でも言う (#1670)。そこには取り除く光が無い (頭と終わりで
        // 空に戻る) ので何も変わらないが、書いたことは知らせる — 切り抜きの `noClip()` と
        // 同じ扱い (#970)。鍵は光を置く口と共有する。直す先 (`draw()` から呼ぶ) は置く口と
        // 外す口で同じなので、分けても言うことが増えない (`resetMatrix()` が変換の鍵を
        // 共有するのと同じ)
        guard isDrawing else { return warnOutsideFrame(.light) }
        guard !activeLights.isEmpty else { return }
        closeBatch()
        activeLights.removeAll(keepingCapacity: true)
    }

    /// 光を置き場へ足す。**列をその場で閉じる**ので、既に置いた立体は置いた時点の
    /// 光で描かれる ([ADR-0021] 決定 2 の「記録した列だけで絵が決まる」)。
    ///
    /// フレームの外 (初期化のとき) に置かれた光は、どのフレームにも属さないので
    /// 警告して無視する (同 決定 4)。黙って捨てると「書いたのに効かない」だけが残る。
    ///
    /// **光の色 (`color`) が数でない成分・無限の成分を持つなら置かない** ([#1706])。フレームの
    /// 外の断りを先に言う — 置かない光のために、色の鍵を使い切らない。
    ///
    /// [#1706]: https://github.com/mokume-metal/mokume/issues/1706
    private func addLight(_ light: Light, color: LinearRGBA, entry: ColorEntry) {
        guard isDrawing else { return warnOutsideFrame(.light) }
        guard color.isFinite else { return warnNotANumberColor(entry) }
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

}
