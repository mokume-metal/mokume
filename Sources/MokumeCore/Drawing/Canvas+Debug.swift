// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 立体の空間の向きを読むための目印 (床の格子と 3 本の軸)。意味の説明は利用者が最初に触る層
// (`SketchPart.debugMode()`) が正本 ([ADR-0020] 決定 4)。**`Canvas` の公開面には置かない** —
// 完了条件にあるのはスケッチの口だけである ([#2462])。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [#2462]: https://github.com/mokume-metal/mokume/issues/2462
extension Canvas {

    /// このフレームの終わりに格子と軸を描く。シーンの記述なので、フレームの外と形の組み立ての
    /// 中では断る (``admits(_:)``)。
    func debugMode() {
        guard admits(.debug) else { return }
        drawsDebugGuides = true
    }

    /// このフレームでは格子と軸を描かない。後に書いたほうが勝つ。
    func noDebugMode() {
        guard admits(.debug) else { return }
        drawsDebugGuides = false
    }

    /// 目印の寸法と色。説明 (`SketchPart.debugMode()`) が名乗る値と同じものを、検査もここから読む。
    enum DebugGuides {
        /// 格子の 1 辺を、面の短いほうの辺の何倍にするか。
        static let gridSpan: Float = 1
        /// 格子の 1 辺を割る数。
        static let gridDivisions = 10
        /// 軸の長さを、面の短いほうの辺の何倍にするか。**格子の線の間に先が来る長さにする** —
        /// 先が格子の線と重なると、先の色が格子の灰と混ざる。
        static let axisLength: Float = 0.25
        static let gridWeight: Float = 1
        static let axisWeight: Float = 2
        static let gridColor = Color.display(red: 0.5, green: 0.5, blue: 0.5)
        static let xColor = Color.display(red: 1, green: 0, blue: 0)
        static let yColor = Color.display(red: 0, green: 1, blue: 0)
        static let zColor = Color.display(red: 0, green: 0, blue: 1)
    }

    /// 目印の中心 (面の中心・奥行き 0)。既定の視点と ``Orbit`` の見ている先と同じ所。
    var debugGuideCenter: SIMD3<Float> { SIMD3(width / 2, height / 2, 0) }

    /// 軸の長さ (世界の座標)。
    var debugAxisLength: Float { min(width, height) * DebugGuides.axisLength }

    /// 印が立っていれば、格子と軸を描く。フレームの終わり (``endFrame()``) が、描き切る前に呼ぶ。
    ///
    /// **描くのはその時点の視点からで、変換・スタイル・断片は使わない。** 変換は恒等、スタイルは
    /// 既定 (塗らない・影を落とさない・受けない)、断片は組み込みにして描き、終わったら戻す。
    /// 利用者が最後に書いた `translate()` や `stroke()` が目印へ漏れると、目印の位置と色が
    /// 読めなくなる。組み立て中の形は ``placeSolidVertices(_:_:)`` が退かせて戻す。
    ///
    /// 格子の中心線のうち軸と重なる区間 (中心から +x・+z へ軸の長さまで) は引かない。同じ線を
    /// 2 度引くと、奥行きの比べ方 (`lessEqual`) と丸めの揺れで、どちらの色が出るかが画素ごとに揺れる。
    func drawDebugGuides() {
        guard drawsDebugGuides, isDrawing, !recordingShape else { return }
        let savedTransform = transform
        let savedStyle = currentStyle
        let savedShader = currentShader
        defer {
            currentStyle = savedStyle
            transform = savedTransform
            if savedShader !== currentShader {
                closeBatch()
                currentShader = savedShader
            }
        }
        transform = .identity
        var guides = Style()
        guides.hasFill = false
        guides.castsShadow = false
        guides.receivesShadow = false
        currentStyle = guides
        if currentShader != nil {
            closeBatch()
            currentShader = nil
        }

        let center = debugGuideCenter
        let short = min(width, height)
        let half = short * DebugGuides.gridSpan / 2
        let axis = debugAxisLength
        let divisions = DebugGuides.gridDivisions

        // 格子は 1 つの形にまとめて置く (`beginShape(.lines)` に 2 点ずつ)
        var grid: [SIMD3<Float>] = []
        for index in 0...divisions {
            let offset = -half + 2 * half * Float(index) / Float(divisions)
            if index * 2 == divisions {
                // 中心線。+側の軸の区間を除いて引く
                for (from, to) in [(-half, Float(0)), (axis, half)] {
                    grid += [center + SIMD3(from, 0, 0), center + SIMD3(to, 0, 0)]
                    grid += [center + SIMD3(0, 0, from), center + SIMD3(0, 0, to)]
                }
                continue
            }
            // x に沿う線 (奥行きが offset) と、奥行きに沿う線 (横が offset)
            grid += [center + SIMD3(-half, 0, offset), center + SIMD3(half, 0, offset)]
            grid += [center + SIMD3(offset, 0, -half), center + SIMD3(offset, 0, half)]
        }
        style.stroke = DebugGuides.gridColor
        style.strokeWeight = DebugGuides.gridWeight
        placeSolidVertices(.lines, grid)

        style.strokeWeight = DebugGuides.axisWeight
        for (direction, color) in [
            (SIMD3<Float>(1, 0, 0), DebugGuides.xColor),
            (SIMD3<Float>(0, 1, 0), DebugGuides.yColor),
            (SIMD3<Float>(0, 0, 1), DebugGuides.zColor),
        ] {
            style.stroke = color
            placeSolidVertices(.lines, [center, center + direction * axis])
        }
    }
}
