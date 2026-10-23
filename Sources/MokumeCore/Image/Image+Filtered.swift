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
    /// **呼ぶたびに、GPU で効果を通し、読み戻して、新しい絵を作る。** 作業の面とその置き場は絵が 1 つ持って
    /// 使い回す (同じ絵への 2 回目からは確保しない。絵が手放されるまで、絵と同じ大きさの面が数枚残る) が、
    /// 効果を通して読み戻すのを待つ費用と、新しい絵の確保は毎回かかる。カメラの絵に毎フレーム掛ける使い方は
    /// これで成り立つが、変わらない絵は `setup()` で 1 度掛けて持つほうが安い。効果を通せなかった
    /// ときは、効果を掛けない ``copy()`` を返し、理由を 1 度だけ警告する (数でない値の効果を外したことと、
    /// 範囲の外の値を締めたことも、1 度だけ言う)。
    ///
    /// - Parameter effects: 前から順に掛かる効果の並び。空なら ``copy()`` と同じ絵になる。
    /// - Returns: 大きさが同じ、新しい `Image`。
    // shot: 撮れない 例はカメラの映像を要し、掛けた後の画素は絵ではなく検査で見る
    public func filtered(_ effects: [Effect]) -> Image {
        guard !effects.isEmpty else { return copy() }
        do {
            return try applyingEffects(effects)
        } catch {
            let message =
                "filtered(): could not run the effects: \(error.headline). An image without them was returned"
            if let filterWorkspace {
                filterWorkspace.warnOnce(.filterFailed, message)
            } else {
                Diagnostics.warn(message)
            }
            return copy()
        }
    }

    /// 同じ大きさの面へ絵を置いて効果を通し、読み戻して新しい絵にする。
    ///
    /// 作業の面は絵が持って使い回す (``filterWorkspace``)。受け口の検め (数でない値を外す・範囲を締める) と
    /// 段は ``SketchPart/filter(_:)`` と同じ 1 本 (``Canvas/acceptedEffects(_:calledBy:)``・
    /// ``Canvas/applyFilter(_:)``) を通り、**効果を通せなかったことは握りつぶさず投げる** — 掛かっていない絵を
    /// 成功の道で返さない。
    private func applyingEffects(_ effects: [Effect]) throws(RenderFailure) -> Image {
        let canvas = try workspace()
        let accepted = canvas.acceptedEffects(effects, calledBy: "filtered")
        guard !accepted.isEmpty else { return copy() }
        var failure: RenderFailure?
        try canvas.draw {
            // 使い回す面なので、前の絵を消してから置く (透明の上に置けば、置いた絵がそのまま残る)
            canvas.background(.transparent)
            canvas.image(self, 0, 0)
            do throws(RenderFailure) {
                try canvas.applyFilter(accepted)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
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

    /// 作業の面。無ければ絵と同じ大きさで作る。細かさは 1 で、絵の画素と面の画素は 1 対 1 になる。
    private func workspace() throws(RenderFailure) -> Canvas {
        if let filterWorkspace { return filterWorkspace }
        let made = try Canvas(
            target: RenderTarget(gpu: gpu, width: width, height: height), gpu: gpu)
        filterWorkspace = made
        return made
    }
}
