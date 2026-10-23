// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics

extension Image {
    /// 効果の並びを掛けた、新しい絵を返す。**元の絵は変えない。**
    ///
    /// 並びは ``SketchPart/effects(_:)`` と同じ ``Effect`` の値で、`.threshold(level:)` のような組み込みも
    /// ``Effect/custom(_:)`` も掛けられる。**カメラの絵にも掛けられ**、返った絵はカメラの次の 1 枚で
    /// 書き換わらない。
    ///
    /// <!-- example: 文脈 var camera: Capture? -->
    /// ```swift
    /// func setup() { camera = try? createCapture() }
    ///
    /// func draw() {
    ///     background(0)
    ///     guard let camera else { return }
    ///     // カメラを 2 値化して影絵にする
    ///     image(camera.image.filtered([.threshold(level: 0.45)]), 0, 0, width, height)
    ///     // 効果の掛からない色の円を、その上に置く
    ///     fill(242, 115, 64)
    ///     circle(mouseX, mouseY, 80)
    /// }
    /// ```
    ///
    /// ## 画素を書き換える口との使い分け
    ///
    /// - ``set(_:_:_:)``・``fill(_:)``・``write(_:)``・``Pixels/update(_:)`` は**自分を変える**命令形
    /// - `filtered(_:)` は**新しい絵を返し**、元を変えない。手本の `PImage.filter()` は自分を変えるので、
    ///   同じ名前で新しい絵を返すと同名異義になる (そのため `filtered`)
    ///
    /// ## 費用
    ///
    /// **呼ぶたびに、GPU で別の面へ書き、読み戻して、新しい絵を作る。** 毎フレーム呼ぶと確保と読み戻しが
    /// かかる (ADR-0023 決定 5 の使い回しの外)。変わらない絵は `setup()` で 1 度掛けて持つ。
    /// 効果を通せなかったときは、効果を掛けない ``copy()`` を返し、理由を 1 度だけ警告する。
    ///
    /// - Parameter effects: 前から順に掛かる効果の並び。空なら ``copy()`` と同じ絵になる。
    /// - Returns: 大きさが同じ、新しい `Image`。
    // shot: 撮れない 例はカメラの映像を要し、掛けた後の画素は絵ではなく検査で見る
    public func filtered(_ effects: [Effect]) -> Image {
        guard !effects.isEmpty else { return copy() }
        do {
            return try applyingEffects(effects)
        } catch {
            Diagnostics.warn(
                "filtered(): could not run the effects: \(error.headline). An image without them was returned")
            return copy()
        }
    }

    /// 同じ大きさの面へ絵を置いて効果を通し、読み戻して新しい絵にする。
    ///
    /// 置くだけの面なので、フレームの終わりの `effects(_:)` と同じ検め・同じ段を通る。細かさは 1 で、
    /// 絵の画素と面の画素は 1 対 1 になる。
    private func applyingEffects(_ effects: [Effect]) throws(RenderFailure) -> Image {
        let canvas = try Canvas(
            target: RenderTarget(gpu: gpu, width: width, height: height), gpu: gpu)
        try canvas.draw {
            canvas.image(self, 0, 0)
            canvas.effects(effects)
        }
        let filtered = try canvas.target.readPixels()
        var pixels: [SIMD4<Float16>] = []
        pixels.reserveCapacity(width * height)
        for index in 0..<(width * height) {
            let base = index * 4
            pixels.append(
                SIMD4(
                    filtered.components[base], filtered.components[base + 1],
                    filtered.components[base + 2], filtered.components[base + 3]))
        }
        return try Image(width: width, height: height, pixels: pixels, gpu: gpu)
    }
}
