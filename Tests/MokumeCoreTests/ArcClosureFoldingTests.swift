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

    private static func place(
        _ canvas: Canvas, mode: ArcMode?, radii: (Float, Float), start: Float, stop: Float
    ) {
        if let mode {
            canvas.arc(0, 0, radii.0 * 2, radii.1 * 2, start, stop, mode)
        } else {
            canvas.arc(0, 0, radii.0 * 2, radii.1 * 2, start, stop)
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
        radii: (Float, Float) = (14, 9), sweep: (Float, Float) = (0.3, 4.1), spin: Float = 0.21,
        scale: (Int) -> (Float, Float) = { _ in (1, 1) },
        closures: [(String, ArcMode?)] = ArcClosureFoldingTests.closures,
        folded: Bool
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
                    canvas.fill(255)
                    if let image { canvas.texture(image) } else { canvas.shader(shader) }
                    for index in 0..<30 {
                        canvas.pushMatrix()
                        canvas.translate(20 + Float(index % 6) * 17, 20 + Float(index / 6) * 17)
                        canvas.rotate(Float(index) * spin + 0.03)
                        let (sx, sy) = scale(index)
                        canvas.scale(sx, sy)
                        if folding {
                            Self.place(canvas, mode: mode, radii: radii, start: sweep.0, stop: sweep.1)
                        } else {
                            Self.placeUnfolded(canvas, mode: mode, radii: radii, sweep: sweep)
                        }
                        canvas.popMatrix()
                    }
                    if folding {
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
                if unfolded.components[index] > 0 { lit += 1 }
            }
            #expect(lit > 0, "\(name) \(closureName): 絵が空")
            #expect(
                differing == 0,
                "\(name) \(closureName): 畳まずに置いた絵と画素の成分が \(differing) 個違う (点いている成分 \(lit))")
        }
    }

    /// 畳む前の道: 閉じ方ごとの周を、置き場所の中心 (原点) まで動かして直に描く。
    private static func placeUnfolded(
        _ canvas: Canvas, mode: ArcMode?, radii: (Float, Float), sweep: (Float, Float)
    ) {
        let segments = Canvas.segmentCount(
            forRadius: max(radii.0, radii.1), scale: Canvas.splitScale(of: canvas.transform.matrix))
        func outline(_ piece: Canvas.Outline.Ring.Piece) -> Canvas.Outline {
            Canvas.ringOutline(
                Canvas.Outline.Ring(
                    radiusX: radii.0, radiusY: radii.1, start: sweep.0, sweep: sweep.1 - sweep.0,
                    segments: segments, piece: piece)
            ).moved(by: .zero)
        }
        switch mode {
        case nil:
            canvas.draw(outline(.sectorFill))
            canvas.draw(outline(.arcLine))
        case .chord:
            canvas.draw(outline(.chord))
        case .open:
            canvas.draw(outline(.chordFill))
            canvas.draw(outline(.arcLine))
        case .pie:
            canvas.draw(outline(.sector))
        }
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
