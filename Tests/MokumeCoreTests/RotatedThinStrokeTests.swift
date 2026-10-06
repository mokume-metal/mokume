// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 細い線の補いは、**描く画素で見た太さが 1 より細い線にだけ立つ** ([#1637]・[#2039])。
/// 回すだけ・映すだけの変換は太さを変えないので、太さ 1 の線は、どの角度でも補われない。
///
/// かつては、単精度の行列の誤差で、`rotate` だけで置いた太さ 1 の線のいちばん細い太さが
/// 0.9998 ほどになり (`trace²/4 − det` の打ち消しが平方根で膨らんだ)、約 29% の角度で補いの
/// 入口が開いた。片ごとの太さも 1 ± 1e-7 に揺れ、約 4% の角度で頂点の数が変わっていた。
/// GPU は要らない。
///
/// [#1637]: https://github.com/mokume-metal/mokume/issues/1637
/// [#2039]: https://github.com/mokume-metal/mokume/issues/2039
@Suite("回すだけの変換の細い線の補い (式)")
struct RotatedThinStrokeFormulaTests {
    /// 変換の 2x2 を、描く画素 1 つが `units` の土台で描く画素へ写したもの
    /// (`Canvas.drawnLinear(_:)` と同じ割り算)。細かさ 0.5 は `units` 2。
    private func drawn(units: Float = 1, _ build: (inout Transform) -> Void) -> simd_float2x2 {
        var transform = Transform.identity
        build(&transform)
        let columns = transform.matrix.columns
        return simd_float2x2(
            SIMD2(columns.0.x / units, columns.0.y / units),
            SIMD2(columns.1.x / units, columns.1.y / units))
    }

    /// 片の向きの見本 (軸・斜め・半端な向き)。
    private static let directions: [SIMD2<Float>] = [
        SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1), SIMD2(-1, 1), SIMD2(3, -7), SIMD2(0.2, 5),
    ]

    /// 描く画素で太さちょうど 1 の線が、どの判定でも補いに入らないこと。入口 (いちばん細い太さ)・
    /// 片ごとの太さ・点の太さを見る。入口の値は 1 の上で 1e-5 を越えない (太く見積もりもしない)。
    private func unitStrokeStaysUnthinned(
        _ weight: Float, _ linear: simd_float2x2, _ label: @autoclosure () -> String,
        into broken: inout [String]
    ) {
        let thinnest = Canvas.thinnestDrawnWeight(weight, by: linear)
        if !(thinnest >= 1 && thinnest <= 1 + 1e-5) {
            broken.append("\(label()) の入口 \(thinnest)")
        }
        for direction in Self.directions {
            let along = Canvas.drawnWeight(weight, along: direction, by: linear)
            if along < 1 { broken.append("\(label()) の向き \(direction) \(along)") }
        }
        let point = Canvas.drawnPointWeight(weight, by: linear)
        if point < 1 { broken.append("\(label()) の点 \(point)") }
    }

    @Test("回すだけ・映すだけの変換は、どの角度・どの合成でも太さ 1 の線を細く見ない")
    func rotationsNeverThinAUnitStroke() {
        var broken: [String] = []
        // 1 つの角度 (0〜2π を 0.001 刻み)。平行移動は 2x2 に効かないが、置き場所と同じ形で掛ける
        for step in 0..<6284 {
            let angle = Float(step) * 0.001
            let linear = drawn {
                $0.translate(x: 80, y: 80)
                $0.rotate(by: angle)
            }
            unitStrokeStaysUnthinned(1, linear, "rotate(\(angle))", into: &broken)
        }
        // 2 つの回転の合成・平行移動と鏡映を挟んだ合成
        for first in 0..<157 {
            for second in 0..<157 {
                let a = Float(first) * 0.04
                let b = Float(second) * 0.04
                unitStrokeStaysUnthinned(
                    1, drawn { $0.rotate(by: a); $0.rotate(by: b) },
                    "rotate(\(a)); rotate(\(b))", into: &broken)
                unitStrokeStaysUnthinned(
                    1,
                    drawn {
                        $0.translate(x: 80, y: 80)
                        $0.rotate(by: a)
                        $0.translate(x: -13.7, y: 41.2)
                        $0.scale(x: -1, y: 1)
                        $0.rotate(by: b)
                    },
                    "translate; rotate(\(a)); translate; scale(-1, 1); rotate(\(b))", into: &broken)
            }
        }
        // 小さい回転を 1000 回重ねる (誤差が積もる)
        var chain = Transform.identity
        for _ in 0..<1000 { chain.rotate(by: 0.00628) }
        unitStrokeStaysUnthinned(1, drawn { $0 = chain }, "rotate(0.00628) × 1000", into: &broken)
        #expect(broken.isEmpty, "細く見た \(broken.count) 件: \(broken.prefix(3))")
    }

    /// 揺れは変換の大きさに対して相対で乗る。拡大と細かさで太さを打ち消して、描く画素でちょうど 1 に
    /// なる線も、回すだけで補いに入らない (特異値を 1 の付近で丸めるだけでは拾えない組)。
    @Test(
        "拡大や細かさで描く画素の太さがちょうど 1 になる線も、回すだけでは補わない",
        arguments: [
            (weight: Float(0.5), scale: Float(2), units: Float(1)),
            (weight: 0.25, scale: 4, units: 1),
            (weight: 2, scale: 1, units: 2),  // 細かさ 0.5 の太さ 2
            (weight: 4, scale: 1, units: 4),  // 細かさ 0.25 の太さ 4
            (weight: 3, scale: 1, units: 3),
            (weight: 1, scale: 2, units: 2),  // 細かさ 0.5 の下で 2 倍
        ])
    func scaledAndDenseUnitStrokesStayUnthinned(
        _ setting: (weight: Float, scale: Float, units: Float)
    ) {
        var broken: [String] = []
        for step in 0..<720 {
            let angle = Float(step) * (2 * .pi / 720)
            let linear = drawn(units: setting.units) {
                $0.translate(x: 80, y: 80)
                $0.rotate(by: angle)
                $0.scale(x: setting.scale, y: setting.scale)
            }
            unitStrokeStaysUnthinned(setting.weight, linear, "角度 \(angle)", into: &broken)
        }
        #expect(broken.isEmpty, "\(setting) で細く見た \(broken.count) 件: \(broken.prefix(3))")
    }

    /// 本当に細くなる変換は、従来どおり補う。幅 (1e-4) の外のわずかな縮小 (0.99・0.998・0.9995) も
    /// 補う。
    @Test(
        "縮める変換は、回しても従来どおり細く見る",
        arguments: [
            (x: Float(0.5), y: Float(0.5)), (x: 1, y: 0.5), (x: 0.25, y: 3), (x: 0.99, y: 0.99),
            (x: 0.998, y: 0.998), (x: 1, y: 0.99), (x: 0.9995, y: 0.9995), (x: 1, y: 0.9995),
        ])
    func shrinkingStillThins(_ scale: (x: Float, y: Float)) {
        let expected = min(scale.x, scale.y)
        var broken: [String] = []
        for step in 0..<720 {
            let angle = Float(step) * (2 * .pi / 720)
            let linear = drawn {
                $0.translate(x: 80, y: 80)
                $0.rotate(by: angle)
                $0.scale(x: scale.x, y: scale.y)
            }
            let thinnest = Canvas.thinnestDrawnWeight(1, by: linear)
            if !(thinnest < 1 && abs(thinnest - expected) < 1e-5) {
                broken.append("角度 \(angle) の入口 \(thinnest)")
            }
            // 形自身の座標で縮むほうの軸に沿わない片 (縮んだ軸に垂直に走る片) の太さ
            let across = Canvas.drawnWeight(
                1, along: scale.x <= scale.y ? SIMD2(0, 1) : SIMD2(1, 0), by: linear)
            if !(across < 1 && abs(across - expected) < 1e-5) {
                broken.append("角度 \(angle) の細い片 \(across)")
            }
        }
        #expect(broken.isEmpty, "scale\(scale) で補わなかった \(broken.count) 件: \(broken.prefix(3))")
    }

    /// 縦と横で倍率の違う変換で、縮まない軸に沿って測ると描く画素でちょうど 1 になる片は、
    /// 回しても補わない (入口は開くが、その片は太さ 1 のまま組む)。
    @Test("縦横で倍率の違う変換で、縮まない向きの片は回しても補わない")
    func unshrunkSidesOfAnAnisotropicScaleStayUnthinned() {
        var broken: [String] = []
        for step in 0..<720 {
            let angle = Float(step) * (2 * .pi / 720)
            let linear = drawn {
                $0.translate(x: 80, y: 80)
                $0.rotate(by: angle)
                $0.scale(x: 1, y: 0.5)
            }
            // 横に走る片は縦の 0.5 倍で細くなる。縦に走る片の太さは横の倍率 1 で決まる
            let horizontal = Canvas.drawnWeight(1, along: SIMD2(1, 0), by: linear)
            let vertical = Canvas.drawnWeight(1, along: SIMD2(0, 1), by: linear)
            if !(abs(horizontal - 0.5) < 1e-5) { broken.append("角度 \(angle) の横 \(horizontal)") }
            if vertical < 1 { broken.append("角度 \(angle) の縦 \(vertical)") }
        }
        #expect(broken.isEmpty, "\(broken.count) 件: \(broken.prefix(3))")
    }

    /// 幅は単精度の揺れ (積み重ねて 1e-5) だけを吸う。分割数の拡大率の丸め (1e-3) とは揃えない —
    /// 丸めた線は補いを外れ、AA の無い帯が画素の境目で消えうるので、本当に細い線は丸めない。
    @Test("誤差の幅の内側は 1 に丸め、幅の外の細さ (0.9995 など) は丸めずに補う")
    func roundingBandAbsorbsOnlySinglePrecisionDrift() {
        #expect(Canvas.thinStrokeTolerance == 1e-4)
        #expect(Canvas.thinStrokeTolerance < Canvas.splitScaleTolerance)
        // 幅の内側 (単精度の誤差が積もっても届く範囲) は、ちょうど 1
        #expect(Canvas.roundedDrawnWeight(0.99999994) == 1)
        #expect(Canvas.roundedDrawnWeight(0.99999) == 1)
        #expect(Canvas.roundedDrawnWeight(0.99995) == 1)
        #expect(Canvas.thinnestDrawnWeight(1, by: drawn { $0.scale(x: 0.99995, y: 0.99995) }) == 1)
        // 幅の外は丸めない (補いの経路で、描く画素 1 つの太さへ広げて濃さで出す)
        #expect(Canvas.roundedDrawnWeight(0.9995) == 0.9995)
        #expect(Canvas.roundedDrawnWeight(0.9998) == 0.9998)
        #expect(abs(Canvas.thinnestDrawnWeight(0.9995, by: drawn { _ in }) - 0.9995) < 1e-7)
        #expect(abs(Canvas.thinnestDrawnWeight(1, by: drawn { $0.scale(x: 1, y: 0.9995) }) - 0.9995) < 1e-6)
        // 1 以上と、ずっと細い値はそのまま
        #expect(Canvas.roundedDrawnWeight(0.998) == 0.998)
        #expect(Canvas.roundedDrawnWeight(0.5) == 0.5)
        #expect(Canvas.roundedDrawnWeight(0) == 0)
        #expect(Canvas.roundedDrawnWeight(1.0000001) == 1.0000001)
        #expect(Canvas.roundedDrawnWeight(.nan).isNaN)
    }

    /// 保持した形の見積もり (`Shape.thinnestRecordedWeight`) は、置くときの行列と掛け合わせた後で
    /// 1 度だけ丸める。記録の側で丸めると、記録 0.99995 × 置き場所 0.99993 = 0.99988 (幅の外で
    /// 細い) を 1 × 0.99993 → 1 と見て、組み直しを飛ばす。
    @Test("最小の特異値は丸めず、潰れた・数でない変換は従来どおり扱う")
    func smallestSingularValueIsUnrounded() {
        let slight = Canvas.smallestSingularValue(of: drawn { $0.scale(x: 0.9995, y: 0.9995) })
        #expect(abs(slight - 0.9995) < 1e-6)
        // 縦横の倍率が桁違いでも、小さいほうの桁が落ちない (単精度の `trace²/4 − det` は `trace²` の
        // 桁に呑まれ、ここで 1e-4 を大きく外していた)
        let stretched = Canvas.smallestSingularValue(of: drawn {
            $0.rotate(by: 0.3)
            $0.scale(x: 1e4, y: 1e-4)
        })
        #expect(abs(stretched / 1e-4 - 1) < 1e-5)
        // 一方の軸だけを大きく伸ばしても、伸ばさない軸の太さは動かない
        for angle in [Float(0), 0.3, 1.1, 2.5] {
            let long = drawn {
                $0.rotate(by: angle)
                $0.scale(x: 1000, y: 1)
            }
            #expect(Canvas.thinnestDrawnWeight(1, by: long) == 1, "角度 \(angle)")
            let thin = drawn {
                $0.rotate(by: angle)
                $0.scale(x: 1000, y: 0.5)
            }
            #expect(abs(Canvas.thinnestDrawnWeight(1, by: thin) - 0.5) < 1e-5, "角度 \(angle)")
        }
        // 潰れた変換は 0 (補いの入口は開き、行列式 0 の所で何も補わない — `thinOutline`)
        #expect(Canvas.smallestSingularValue(of: drawn { $0.scale(x: 0, y: 0) }) == 0)
        #expect(Canvas.thinnestDrawnWeight(1, by: drawn { $0.scale(x: 0, y: 2) }) == 0)
        // 数でない変換は、補わない側 (1 未満と比べて偽)
        #expect(!(Canvas.thinnestDrawnWeight(1, by: drawn { $0.scale(x: .nan, y: 2) }) < 1))
        #expect(!(Canvas.thinnestDrawnWeight(1, by: drawn { $0.scale(x: .infinity, y: 2) }) < 1))
    }

    /// 立体の線の太さは出す画素で書かれ、描く画素では細かさの比 (幅 / 刻む幅) で割る。比は単精度で
    /// 丸められるので、細かさ `d` の下の太さ `1 / d` (描く画素でちょうど 1) が 0.99999994 になりうる。
    /// 平面の線と同じく 1 に丸め、同じ絵の中で平面と立体の判断を食い違わせない。
    @Test("立体の線も、細かさで描く画素の太さがちょうど 1 になるなら補わない")
    func solidStrokesRoundLikePlanarOnes() {
        // 起票の再現: 細かさ 0.55・出す先 200 (刻む 110)・太さ 1 / 0.55
        let units = SIMD2(repeating: Float(200) / Float(110))
        #expect(Canvas.drawnSolidWeight(1 / 0.55, unitsPerDrawnPixel: units) >= 1)
        var broken: [String] = []
        for density in [0.1, 0.15, 0.2, 0.3, 0.35, 0.4, 0.45, 0.55, 0.6, 0.65, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95] {
            for width in stride(from: 20, through: 2000, by: 1) {
                let pixels = (Double(width) * density).rounded()
                guard pixels > 0, abs(pixels - Double(width) * density) < 1e-9 else { continue }
                let units = SIMD2(repeating: Float(width) / Float(pixels))
                let found = Canvas.drawnSolidWeight(1 / Float(density), unitsPerDrawnPixel: units)
                if found < 1 { broken.append("細かさ \(density)・幅 \(width): \(found)") }
            }
        }
        #expect(broken.isEmpty, "補いに入った \(broken.count) 件: \(broken.prefix(3))")
        // 本当に細い立体の線は、従来どおり補う
        let half = SIMD2<Float>(repeating: 2)
        #expect(Canvas.drawnSolidWeight(1, unitsPerDrawnPixel: half) == 0.5)
        #expect(Canvas.drawnSolidWeight(1.999, unitsPerDrawnPixel: half) == 0.9995)
    }
}

/// 回すだけで置いた太さ 1 の線は、どの角度でも補いの経路に入らず、頂点の数が変わらない
/// ([#2039])。本当に細くなる変換では、従来どおり補う。GPU を要する。
///
/// [#2039]: https://github.com/mokume-metal/mokume/issues/2039
@Suite(
    "回すだけの変換の細い線の補い",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct RotatedThinStrokeTests {
    /// いまの変換で `beginShape` の折れ線 (閉じる・閉じない) を引き、頂点の数と、補いの被覆を
    /// 付けたかを返す。被覆の区間は、描き終える前 (`draw` の中) で見る。
    private func stroke(
        _ canvas: Canvas, end: ShapeEnd, weight: Float, transform: (Canvas) -> Void
    ) throws -> (vertices: Int, thinned: Bool) {
        var thinned = false
        try canvas.draw {
            canvas.background(0)
            canvas.noFill()
            canvas.stroke(255)
            canvas.strokeWeight(weight)
            canvas.translate(80, 80)
            transform(canvas)
            canvas.beginShape()
            canvas.vertex(-30, -20)
            canvas.vertex(0, 25)
            canvas.vertex(30, -20)
            canvas.vertex(10, -35)
            canvas.endShape(end)
            thinned = !canvas.coverageSpans.isEmpty
        }
        return (canvas.flatVerticesInLastFrame, thinned)
    }

    /// #2039 の本文の再現。直す前は 720 角度のうち 30 角度 (約 4%) で頂点の数が変わった。
    @Test("太さ 1 の折れ線を回すだけで 720 角度描いても、頂点の数が変わらず補わない", arguments: [
        ShapeEnd.open, .close,
    ])
    func rotatedUnitStrokeKeepsItsVertices(end: ShapeEnd) throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        let unrotated = try stroke(canvas, end: end, weight: 1) { _ in }
        #expect(unrotated.vertices > 0)
        #expect(!unrotated.thinned)
        var changed: [String] = []
        for step in 0..<720 {
            let angle = Float(step) * (2 * .pi / 720)
            let found = try stroke(canvas, end: end, weight: 1) { $0.rotate(angle) }
            if found.vertices != unrotated.vertices || found.thinned {
                changed.append("角度 \(angle): 頂点 \(found.vertices)・補い \(found.thinned)")
            }
        }
        #expect(changed.isEmpty, "変わった角度 \(changed.count) 個: \(changed.prefix(3))")
    }

    /// 細かさ 0.5 の太さ 2 は、描く画素でちょうど太さ 1。これも回すだけで補わない。
    @Test("細かさ 0.5 の太さ 2 の折れ線も、回すだけでは頂点の数が変わらず補わない")
    func rotatedHalfDensityStrokeKeepsItsVertices() throws {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: 160, height: 160)
        let canvas = try Canvas(output: output, gpu: gpu, pixelDensity: 0.5, upscale: .spatial)
        let unrotated = try stroke(canvas, end: .close, weight: 2) { _ in }
        #expect(!unrotated.thinned)
        var changed: [String] = []
        for step in 0..<720 {
            let angle = Float(step) * (2 * .pi / 720)
            let found = try stroke(canvas, end: .close, weight: 2) { $0.rotate(angle) }
            if found.vertices != unrotated.vertices || found.thinned {
                changed.append("角度 \(angle): 頂点 \(found.vertices)・補い \(found.thinned)")
            }
        }
        #expect(changed.isEmpty, "変わった角度 \(changed.count) 個: \(changed.prefix(3))")
    }

    @Test(
        "縮める変換は、回しても従来どおり細い線を補う",
        arguments: [
            (x: Float(0.5), y: Float(0.5)), (x: 1, y: 0.5), (x: 0.99, y: 0.99), (x: 0.998, y: 1),
        ])
    func shrunkStrokeIsStillThinned(_ scale: (x: Float, y: Float)) throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        var missed: [Float] = []
        for step in 0..<36 {
            let angle = Float(step) * (2 * .pi / 36)
            let found = try stroke(canvas, end: .close, weight: 1) {
                $0.rotate(angle)
                $0.scale(scale.x, scale.y)
            }
            if !found.thinned { missed.append(angle) }
        }
        #expect(missed.isEmpty, "scale\(scale) で補わなかった角度 \(missed.count) 個: \(missed.prefix(3))")
    }

    /// 保持した形を回すだけで置いても、細い線の組み直し (`buildThinVertices`) が立たない。
    @Test("太さ 1 の保持した形を回すだけで置いても、細い線を組み直さない")
    func rotatedRetainedUnitStrokeIsNeverRebuilt() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 160, height: 160)
        var retained: Shape?
        try canvas.draw {
            canvas.noFill()
            canvas.stroke(255)
            canvas.strokeWeight(1)
            retained = canvas.createShape {
                canvas.beginShape()
                canvas.vertex(-30, -20)
                canvas.vertex(0, 25)
                canvas.vertex(30, -20)
                canvas.endShape(.close)
                canvas.circle(0, 0, 40)
            }
        }
        let shape = try #require(retained)
        let before = canvas.thinStrokesRebuilt
        for step in 0..<720 {
            try canvas.draw {
                canvas.background(0)
                canvas.translate(80, 80)
                canvas.rotate(Float(step) * (2 * .pi / 720))
                canvas.shape(shape)
            }
        }
        #expect(canvas.thinStrokesRebuilt == before, "組み直した回数: \(canvas.thinStrokesRebuilt - before)")
        // 縮めて置けば、従来どおり組み直す
        try canvas.draw {
            canvas.background(0)
            canvas.translate(80, 80)
            canvas.rotate(0.3)
            canvas.scale(0.5, 0.5)
            canvas.shape(shape)
        }
        #expect(canvas.thinStrokesRebuilt > before)
    }

    // MARK: - 丸めの幅の外の細い線 (反証 1)

    /// 描く画素でわずかに 1 を割る線 (0.9995) は、丸めずに補い、太さぶんの濃さ (被覆 0.9995) で
    /// 出す。丸めると補いを外れ、AA の無い太さ 0.9995 の帯をそのまま組む — 帯の縁が画素の中心の
    /// 内側に入るので、置き方によってはどの画素の中心も跨がず消えうる。手元の GPU では、ずれ
    /// (0.00025) がラスタライザの格子への寄せより小さく、帯は消えずに満濃度 1 で出た。そこで
    /// 被覆が掛かったか (満濃度 1 を下回るか) と、太さぶんから半精度の刻み 2 つ (2⁻¹⁰) の内に
    /// あるかを見る: かつての幅 1e-3 では、どの位置でも満濃度 1 が出て赤になる。補った線は手元で
    /// 0.99902 (= 1 − 2⁻¹⁰) だった。
    @Test(
        "幅の外でわずかに細い横線は、置く位置によらず太さぶんの濃さで出る",
        arguments: [
            (weight: Float(0.9995), x: Float(1), y: Float(1)),
            (weight: 1, x: 1, y: 0.9995),
            (weight: 1, x: 0.9995, y: 0.9995),
        ])
    func slightlyThinLinesNeverVanish(_ setting: (weight: Float, x: Float, y: Float)) throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 100, height: 40)
        let expected = Double(setting.weight * min(setting.x, setting.y))
        var broken: [String] = []
        for offset: Float in [10, 10.25, 10.5, 10.75, 11] {
            try canvas.draw {
                canvas.background(0)
                canvas.noFill()
                canvas.stroke(255)
                canvas.strokeWeight(setting.weight)
                canvas.scale(setting.x, setting.y)
                canvas.beginShape()
                canvas.vertex(10 / setting.x, offset / setting.y)
                canvas.vertex(90 / setting.x, offset / setting.y)
                canvas.endShape()
            }
            let pixels = try canvas.output.readPixels()
            // 端の形を避けて、x = 40…59 の列の和を平均する
            var total = 0.0
            for x in 40..<60 {
                for y in 0..<pixels.height { total += Double(pixels[x, y].red) }
            }
            let measured = total / 20
            if !(measured < 1 && measured >= expected - 1.0 / 1024) {
                broken.append("y = \(offset): \(measured) (期待 \(expected))")
            }
        }
        #expect(broken.isEmpty, "\(setting): \(broken.joined(separator: " / "))")
    }
}
