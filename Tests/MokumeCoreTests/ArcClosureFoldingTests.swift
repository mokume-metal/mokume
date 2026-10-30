// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import Testing
import simd

@testable import MokumeCore

/// 弧の閉じ方 (既定・`.chord`・`.open`) の畳み ([#3248]) の検査。GPU を要する。
///
/// `shader()` / `texture()` を効かせた間、弧の閉じ方は周を部分ごとに組んで置いていた。**輪郭を引かず貼る絵も無い塗りは、
/// 同じ形が続く間は置き場所を足すだけの 1 つの雛形に畳む。** 輪郭つき・貼る絵つきは畳まない — 畳んだ絵が畳まない絵と
/// 縁の数成分違う (置き場所の変換を GPU で掛けるぶん・#3170 の角丸の輪郭つきと同じ根) ので、絵を動かさない約束を
/// 守るため今までの道に残す。どちらも、畳まずに置く道 (閉じ方ごとの周を作って直に `draw(_:)` へ渡す) と
/// **同じ画素** (許容 0) で出ることを見る。
///
/// [#3248]: https://github.com/mokume-metal/mokume/issues/3248
@Suite(
    "弧の閉じ方の畳み",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ArcClosureFoldingTests {
    private static let size = 128
    private static let plain = "float4 paint(Fragment in, Values values) { return in.color; }"

    private static func makeCanvas(density: Float) throws -> Canvas {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: size, height: size)
        return try Canvas(output: output, gpu: gpu, pixelDensity: density, upscale: .spatial)
    }

    /// 検査の弧。`nil` は既定 (閉じ方を渡さない)。
    private static let closures: [(String, ArcMode?)] = [("既定", nil), (".chord", .chord), (".open", .open)]

    /// 弧の 4 つの数 (`ellipseMode` ごとの読み方) を、中心 `at`・半径 `radii` から組む。
    private static func arguments(
        at center: (Float, Float), radii: (Float, Float), ellipseMode: ShapeMode
    ) -> (Float, Float, Float, Float) {
        switch ellipseMode {
        case .center: (center.0, center.1, radii.0 * 2, radii.1 * 2)
        case .corner: (center.0 - radii.0, center.1 - radii.1, radii.0 * 2, radii.1 * 2)
        case .radius: (center.0, center.1, radii.0, radii.1)
        case .corners: (center.0 - radii.0, center.1 - radii.1, center.0 + radii.0, center.1 + radii.1)
        }
    }

    private static func place(
        _ canvas: Canvas, mode: ArcMode?, radii: (Float, Float), at center: (Float, Float) = (0, 0),
        ellipseMode: ShapeMode = .center, start: Float, stop: Float
    ) {
        let (a, b, c, d) = arguments(at: center, radii: radii, ellipseMode: ellipseMode)
        canvas.ellipseMode(ellipseMode)
        defer { canvas.ellipseMode(.center) }
        if let mode {
            canvas.arc(a, b, c, d, start, stop, mode)
        } else {
            canvas.arc(a, b, c, d, start, stop)
        }
    }

    // MARK: - 畳まれる

    /// 場面: 細かさ 0.5・回転だけ違う弧を 10,000 個。輪郭を引かなければ、閉じ方ごとに 1 つの雛形へ畳まれ、周は雛形の
    /// 1 回だけ組む。
    @Test("輪郭なしで回転だけ違う弧の閉じ方は、閉じ方ごとに 1 つの雛形に畳まれる")
    func rotatedArcsFoldIntoOneTemplate() throws {
        for (name, mode) in Self.closures {
            let canvas = try Self.makeCanvas(density: 0.5)
            let shader = try canvas.makeShader(Self.plain)
            let count = 10_000
            try canvas.draw {
                canvas.background(0)
                canvas.noStroke()
                canvas.fill(255)
                canvas.shader(shader)
                for index in 0..<count {
                    canvas.pushMatrix()
                    canvas.translate(64, 64)
                    canvas.rotate(Float(index) * 0.113 + 0.02)
                    Self.place(canvas, mode: mode, radii: (20, 14), start: 0.3, stop: 4.1)
                    canvas.popMatrix()
                }
                #expect(canvas.openFlat != nil, "\(name): 畳まれていない")
                #expect(canvas.flatInstances.count == count + 1, "\(name): 置き場所 \(canvas.flatInstances.count)")
                // 周を組んだのは、畳む相手を待って置いた 1 つ目と雛形だけ
                #expect(canvas.outlinesAssembledThisFrame < 10, "\(name): 周を組んだ数 \(canvas.outlinesAssembledThisFrame)")
            }
        }
    }

    /// 輪郭を引かない `.open` は `.chord` と塗りが同じなので、同じ雛形に畳む (輪郭の有無で雛形を割らない)。
    @Test("輪郭を引かない弧は、塗りが同じ閉じ方を 1 つの雛形に畳む")
    func strokelessClosuresShareTemplates() throws {
        let canvas = try Self.makeCanvas(density: 1)
        let shader = try canvas.makeShader(Self.plain)
        try canvas.draw {
            canvas.background(0)
            canvas.noStroke()
            canvas.fill(255)
            canvas.shader(shader)
            for index in 0..<40 {
                canvas.pushMatrix()
                canvas.translate(64, 64)
                canvas.rotate(Float(index) * 0.2)
                // 弦で結んだ形の塗りを `.chord` と `.open` で交互に置く
                Self.place(
                    canvas, mode: index % 2 == 0 ? .chord : .open, radii: (20, 14), start: 0.3, stop: 4.1)
                canvas.popMatrix()
            }
            #expect(canvas.openFlat != nil)
            #expect(canvas.flatInstances.count == 41, "置き場所 \(canvas.flatInstances.count)")
        }
    }

    // MARK: - 絵が動かない

    /// 畳まずに置く道 (畳む前の閉じ方ごとの周を作って直に `draw(_:)` へ渡す) と、畳んで置いた絵を比べる。
    /// **許容は 0。**
    private func expectSameAsUnfolded(
        _ name: String, density: Float = 1, texture: Bool = false, dash: Bool = false,
        stroke: (weight: Float, cap: StrokeCap, join: StrokeJoin)? = (0.7, .round, .round),
        radii: (Float, Float) = (14, 9), at center: (Float, Float) = (0, 0), ellipseMode: ShapeMode = .center,
        sweep: (Float, Float) = (0.3, 4.1), sweepOf: ((Int) -> (Float, Float))? = nil, spin: Float = 0.21,
        scale: (Int) -> (Float, Float) = { _ in (1, 1) }, fills: Bool = true, tint: Bool = false,
        blend: BlendMode = .blend, recorded: Bool = false, count: Int = 30, fillAlpha: Float = 255,
        closures: [(String, ArcMode?)] = ArcClosureFoldingTests.closures,
        folded: Bool?, expectsLit: Bool = true
    ) throws {
        for (closureName, mode) in closures {
            func picture(folding: Bool) throws -> PixelBuffer {
                let canvas = try Self.makeCanvas(density: density)
                let shader = try canvas.makeShader(Self.plain)
                var image: Image?
                if texture {
                    let made = try canvas.createImage(8, 8)
                    for y in 0..<8 {
                        for x in 0..<8 {
                            made.set(
                                x, y, .linear(red: Float(x) / 7, green: Float(y) / 7, blue: Float((x + y) % 2)))
                        }
                    }
                    image = made
                }
                try canvas.draw {
                    canvas.background(0)
                    if let stroke {
                        canvas.stroke(200)
                        canvas.strokeWeight(stroke.weight)
                        canvas.strokeCap(stroke.cap)
                        canvas.strokeJoin(stroke.join)
                        if dash { canvas.strokeDash(3, 2) }
                    } else {
                        canvas.noStroke()
                    }
                    canvas.fill(255, fillAlpha)
                    if !fills { canvas.noFill() }
                    if tint { canvas.tint(200, 120, 60) }
                    canvas.blendMode(blend)
                    if let image { canvas.texture(image) } else { canvas.shader(shader) }
                    // 保持する形 (`createShape`) に記録して置く。記録の間は畳まない
                    var retained: Shape?
                    if recorded {
                        retained = canvas.createShape {
                            for (index, spot) in [(0, (-9.0, 4.0)), (1, (11.0, -6.0)), (2, (3.0, 12.0))] {
                                let at = (Float(spot.0), Float(spot.1))
                                let swept = (sweep.0 + Float(index) * 0.2, sweep.1)
                                if folding {
                                    Self.place(
                                        canvas, mode: mode, radii: radii, at: at, ellipseMode: ellipseMode,
                                        start: swept.0, stop: swept.1)
                                } else {
                                    Self.placeUnfolded(
                                        canvas, mode: mode, radii: radii, at: at, ellipseMode: ellipseMode,
                                        sweep: swept)
                                }
                            }
                        }
                    }
                    for index in 0..<count {
                        canvas.pushMatrix()
                        // 30 個までは 6 列の格子。それ以上は、ずらしながら重ねる
                        canvas.translate(
                            20 + Float(index % 6) * 17 + Float(index / 36) * 3.7,
                            20 + Float((index / 6) % 6) * 17 + Float(index / 36) * 5.3)
                        canvas.rotate(Float(index) * spin + 0.03)
                        let (sx, sy) = scale(index)
                        canvas.scale(sx, sy)
                        let swept = sweepOf?(index) ?? sweep
                        if let retained {
                            canvas.shape(retained)
                        } else if folding {
                            Self.place(
                                canvas, mode: mode, radii: radii, at: center, ellipseMode: ellipseMode,
                                start: swept.0, stop: swept.1)
                        } else {
                            Self.placeUnfolded(
                                canvas, mode: mode, radii: radii, at: center, ellipseMode: ellipseMode,
                                sweep: swept)
                        }
                        canvas.popMatrix()
                    }
                    if folding, let folded {
                        #expect(
                            (canvas.openFlat != nil) == folded,
                            "\(name) \(closureName): 畳みの有無が想定と違う (畳まれた \(canvas.openFlat != nil))")
                    }
                }
                return try canvas.target.readPixels()
            }
            let unfolded = try picture(folding: false)
            let foldedPicture = try picture(folding: true)
            var differing = 0
            var lit = 0
            for index in unfolded.components.indices {
                if unfolded.components[index] != foldedPicture.components[index] { differing += 1 }
                // 不透明度の成分は背景でも 1 なので数えない (色の成分だけ)
                if index % 4 != 3, unfolded.components[index] > 0 { lit += 1 }
            }
            #expect((lit > 0) == expectsLit, "\(name) \(closureName): 絵が\(expectsLit ? "空" : "空でない")")
            #expect(
                differing == 0,
                "\(name) \(closureName): 畳まずに置いた絵と画素の成分が \(differing) 個違う (点いている成分 \(lit))")
        }
    }

    /// 畳まない道: **本物の ``Canvas/placeArcInParts(mode:center:radiusX:radiusY:start:sweep:)``** を、`arc` と同じ手順で
    /// 解いた中心・半径で呼ぶ (手で写した複製にしない — 本物を直しても基準が追従する)。
    private static func placeUnfolded(
        _ canvas: Canvas, mode: ArcMode?, radii: (Float, Float), at center: (Float, Float),
        ellipseMode: ShapeMode, sweep: (Float, Float)
    ) {
        let (a, b, c, d) = arguments(at: center, radii: radii, ellipseMode: ellipseMode)
        let box = Canvas.resolveBox(a, b, c, d, mode: ellipseMode)
        let radiusX = box.width / 2
        let radiusY = box.height / 2
        canvas.placeArcInParts(
            mode: mode, center: SIMD2(box.x + radiusX, box.y + radiusY), radiusX: radiusX, radiusY: radiusY,
            start: sweep.0, sweep: min(sweep.1 - sweep.0, 2 * .pi))
    }

    @Test("輪郭を引かない弧の閉じ方は、畳んでも畳まずに置いた絵と画素が同じ (許容 0)")
    func strokelessClosuresKeepTheirPixels() throws {
        try expectSameAsUnfolded("輪郭なし", stroke: nil, folded: true)
        try expectSameAsUnfolded("輪郭なしの細かさ 0.5", density: 0.5, stroke: nil, folded: true)
        try expectSameAsUnfolded("輪郭なしの鏡映", stroke: nil, scale: { _ in (-1, 1) }, folded: true)
        try expectSameAsUnfolded("輪郭なしの縦長の楕円の弧", stroke: nil, radii: (6, 15), spin: 0.3, folded: true)
        try expectSameAsUnfolded("輪郭なしの小さい弧", stroke: nil, radii: (3, 3), sweep: (0.3, 2.4), folded: true)
        try expectSameAsUnfolded("輪郭なしのほぼ一周の弧", stroke: nil, sweep: (0.1, 6.2), folded: true)
    }

    /// **置き場所が原点でない弧**。畳む道は「雛形の座標を置き場所の行列で移す」、畳まない道は「位置を足してから移す」で、
    /// 足す順が違う (#3170 が角丸の輪郭つきを畳まなかった根)。中心が原点だと足す量が 0 で、この差は出ない — 回転・拡大の
    /// ある変換の下で、非零の中心 (`rotate(θ); arc(21.3, -13.7, …)`) を `ellipseMode` ごとに置いて、許容 0 を見る。
    @Test("置き場所が非零の弧 (回転・拡大・ellipseMode) の輪郭なしの塗りも、畳んでも画素が同じ (許容 0)", arguments: [Float(1), 0.5])
    func strokelessNonZeroPlacementsKeepTheirPixels(density: Float) throws {
        for ellipseMode in [ShapeMode.center, .corner, .radius, .corners] {
            try expectSameAsUnfolded(
                "非零の中心 \(ellipseMode) 細かさ \(density)", density: density, stroke: nil, at: (21.3, -13.7),
                ellipseMode: ellipseMode, spin: 0.29, folded: true)
        }
        try expectSameAsUnfolded(
            "非零の中心・倍率なし・回転なし", density: density, stroke: nil, at: (37.3, 21.7), spin: 0, folded: true)
        // 軸ごとに違う (一様でない) 倍率。倍率が違えば刻み数も変わりうるので、畳みの有無は見ず、絵だけ見る
        try expectSameAsUnfolded(
            "非零の中心・軸ごとに違う倍率", density: density, stroke: nil, at: (-17.9, 29.1), spin: 0.37,
            scale: { (1.2 + Float($0 % 3) * 0.05, 0.8 + Float($0 % 4) * 0.03) }, folded: nil)
    }

    /// 重なりで縁の食い違いが飽和に隠れないよう、半透明を足し算で多数重ねる (400 個)。置き場所ごとの回転・非零の中心。
    @Test("非零の中心で半透明を多数重ねても、畳んだ絵は畳まない絵と画素が同じ (許容 0)")
    func manyOverlappingNonZeroPlacementsKeepTheirPixels() throws {
        try expectSameAsUnfolded(
            "400 個の重なり", stroke: nil, radii: (5, 3.5), at: (7.3, -4.1), spin: 0.917, blend: .add, count: 400,
            fillAlpha: 30, folded: true)
        try expectSameAsUnfolded(
            "細かさ 0.5 の 400 個の重なり", density: 0.5, stroke: nil, radii: (5, 3.5), at: (7.3, -4.1), ellipseMode: .corner,
            spin: 0.917, blend: .add, count: 400, fillAlpha: 30, folded: true)
    }

    /// 設定の組み合わせ。**同じ形が続けば畳み、絵は畳まない道と 1 ビットも違わない。**
    @Test("輪郭なしの塗りは、tint・blendMode・置き場所ごとに違う掃引・保持した形・塗りなしでも、畳まない絵と画素が同じ (許容 0)")
    func strokelessCombinationsKeepTheirPixels() throws {
        try expectSameAsUnfolded("tint", stroke: nil, at: (21.3, -13.7), spin: 0.29, tint: true, folded: true)
        for blend in [BlendMode.add, .screen] {
            try expectSameAsUnfolded(
                "blendMode \(blend)", stroke: nil, at: (21.3, -13.7), spin: 0.29, blend: blend, folded: true)
        }
        // 置き場所ごとに start / sweep が違う並び (形の鍵が変わるので畳まれず、絵は同じ)
        try expectSameAsUnfolded(
            "置き場所ごとに違う掃引", stroke: nil, at: (13.1, 7.3),
            sweepOf: { (0.2 + Float($0 % 5) * 0.3, 3.3 + Float($0 % 4) * 0.7) }, spin: 0.29, folded: nil)
        // 塗りも輪郭も無い弧は何も描かず、どちらの道も空 (絵が空でも畳みの有無は想定どおり)
        try expectSameAsUnfolded(
            "塗りなし・輪郭なし", stroke: nil, at: (21.3, -13.7), fills: false, folded: false, expectsLit: false)
        // 保持する形に記録して置く (記録の間は畳まない)
        try expectSameAsUnfolded(
            "保持した形", stroke: nil, radii: (6, 4), spin: 0.29, recorded: true, folded: nil)
    }

    /// **保持した形 (`createShape`) に記録した輪郭なしの弧を、拡大して置き直す。** 畳んだ道では保持した形の周が `.chord` の 1 本、
    /// 畳まない道は `.chordFill` + `.arcLine` の 2 本で、置き直しの再刻み (塗りだけ組み直す) が同じ絵になることを、拡大・縮小・
    /// 細かさを変えて許容 0 で見る (保持した形の検査は拡大なしだった)。
    @Test("保持した輪郭なしの弧を拡大して置き直しても、畳んだ絵は畳まない絵と画素が同じ (許容 0)", arguments: [Float(1), 0.5])
    func retainedStrokelessArcsRescaledKeepTheirPixels(density: Float) throws {
        let chords: [(String, ArcMode?)] = [(".chord", .chord), (".open", .open)]
        try expectSameAsUnfolded(
            "保持した形を 2.5 倍", density: density, stroke: nil, radii: (6, 4), spin: 0.29,
            scale: { _ in (2.5, 2.5) }, recorded: true, count: 12, closures: chords, folded: nil)
        try expectSameAsUnfolded(
            "保持した形を置き場所ごとに違う倍率", density: density, stroke: nil, radii: (6, 4), spin: 0.29,
            scale: { (0.6 + Float($0 % 5) * 0.7, 0.6 + Float($0 % 5) * 0.7) }, recorded: true, count: 12,
            closures: chords, folded: nil)
        try expectSameAsUnfolded(
            "保持した形を軸ごとに違う倍率", density: density, stroke: nil, radii: (6, 4), spin: 0.29,
            scale: { _ in (2.5, 1.4) }, recorded: true, count: 12, closures: chords, folded: nil)
    }

    /// **`stroke` を設定したまま `strokeWeight(0)` にした弧は輪郭を引かない** (`drawsStroke == false`) ので、輪郭なしと同じに畳み、
    /// 畳まない道と許容 0 で一致する。
    @Test("strokeWeight(0) のまま stroke を設定した .chord / .open は畳まれ、畳まない絵と画素が同じ (許容 0)")
    func zeroWeightStrokeArcsFoldAndKeepTheirPixels() throws {
        let chords: [(String, ArcMode?)] = [(".chord", .chord), (".open", .open)]
        try expectSameAsUnfolded(
            "太さ 0 の輪郭", stroke: (0, .round, .round), at: (21.3, -13.7), spin: 0.29, closures: chords, folded: true)
        try expectSameAsUnfolded(
            "太さ 0 の輪郭の細かさ 0.5", density: 0.5, stroke: (0, .round, .round), at: (21.3, -13.7), spin: 0.29,
            closures: chords, folded: true)
    }

    /// **畳んだ絵が畳まない絵と縁の数成分違う場面は、畳まない** (#3248)。輪郭つきの弧 (全部の閉じ方) と、貼る絵つきの
    /// `.chord` / `.open` は今までの道で置く — 畳まないことと、畳まない道と同じ画素 (許容 0) の両方を見る。
    @Test("輪郭つきの弧は畳まず、畳まずに置いた絵と画素が同じ (許容 0)")
    func strokedClosuresAreNotFolded() throws {
        try expectSameAsUnfolded("輪郭つき", folded: false)
        try expectSameAsUnfolded("縦長の楕円の弧", radii: (6, 15), spin: 0.3, folded: false)
        try expectSameAsUnfolded("細い輪郭", stroke: (0.3, .round, .round), spin: 0.27, folded: false)
        try expectSameAsUnfolded("太い輪郭", stroke: (3, .round, .round), folded: false)
        for cap in [StrokeCap.round, .square, .project] {
            try expectSameAsUnfolded(
                "短い弧 \(cap)", stroke: (2.5, cap, .miter), radii: (3, 3), sweep: (0.3, 0.4), folded: false)
            try expectSameAsUnfolded("ほぼ一周の弧 \(cap)", stroke: (2, cap, .round), sweep: (0.1, 6.2), folded: false)
        }
    }

    @Test("貼る絵つきの .chord / .open は畳まず、畳まずに置いた絵と画素が同じ (許容 0)")
    func texturedChordFillsAreNotFolded() throws {
        let chords: [(String, ArcMode?)] = [(".chord", .chord), (".open", .open)]
        try expectSameAsUnfolded("貼る絵だけ", texture: true, stroke: nil, closures: chords, folded: false)
        try expectSameAsUnfolded("貼る絵と輪郭", texture: true, closures: chords, folded: false)
    }

    @Test("破線の弧は畳まず、畳まずに置いた絵と画素が同じ (許容 0)")
    func dashedClosuresAreNotFolded() throws {
        try expectSameAsUnfolded("破線", dash: true, stroke: (1, .round, .round), folded: false)
    }
}
