// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import Testing

@testable import MokumeCore

/// 手放した絵や字の面が、**それを読む投入が終わるまで**常駐の集合に残ることを見る。
///
/// ## なぜ要るか
///
/// 持ち主 (``Image`` など) は死ぬときに ``RenderDevice/retire(_:)`` で面を常駐から退かせ、
/// 外す番はその時点の投入番号で決まる。溜める側 (束・保持した形) が**面だけを**抱えて
/// 持ち主を抱えないと、面を読む投入に番号が付く前に持ち主が死に、読み終わる前に面が
/// 外れる ([#1079]・[#1178])。常駐していない面を読んだ結果は未定義で、絵は多くの場合
/// 正しく出てしまうので、**集合に入っているかを直に問うしか見分ける手が無い。**
///
/// ## 窓を運に任せない
///
/// どの検査も、手放した後に ``RenderDevice/settle()`` で先行する投入を終わらせてから
/// 読む投入を出す。こうすると刈り (``RenderDevice/beginCommands()`` の手前) が手放した
/// 番を必ず過ぎているので、抱え方が壊れていれば必ず赤くなる。読む投入を出した直後は
/// 待たずに問う — 完了の知らせによる刈りは main actor を明け渡すまで着地しないので、
/// 検査が返るまで起きない。
///
/// [#1079]: https://github.com/mokume-metal/mokume/issues/1079
/// [#1178]: https://github.com/mokume-metal/mokume/issues/1178
@Suite(
    "読む投入が終わるまで常駐に残る",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ResidencyReaderTests {
    private struct Bench {
        let gpu: RenderDevice
        let canvas: Canvas

        func isResident(_ allocation: (any MTLAllocation)?) -> Bool {
            guard let allocation else { return false }
            return gpu.residencySet.containsAllocation(allocation)
        }
    }

    private func makeBench() throws -> Bench {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: 32, height: 32)
        return Bench(gpu: gpu, canvas: try Canvas(target: target, gpu: gpu))
    }

    /// 読み終えた後は外れる (#738 を開け直していない) ことも、同じ検査の末尾で見る。
    private func expectReleasedAfterSettling(
        _ bench: Bench, _ allocation: (any MTLAllocation)?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        try bench.gpu.settle()
        #expect(
            !bench.isResident(allocation),
            "読み終えた後も面が常駐に残っている (#738 の穴を開け直している)",
            sourceLocation: sourceLocation)
        #expect(bench.gpu.retiredResourceCount == 0, sourceLocation: sourceLocation)
    }

    @Test("draw の中で置いて手放した絵の面は、そのフレームの投入が終わるまで外れない")
    func pictureDroppedInsideDrawStaysUntilRead() throws {
        let bench = try makeBench()
        let canvas = bench.canvas
        var face: (any MTLTexture)?
        var failure: (any Error)?

        try canvas.draw {
            do {
                let picture = try canvas.createImage(16, 16)
                face = picture.texture
                canvas.image(picture, 0, 0)
            } catch {
                failure = error
            }
            // 手放した番を刈りが確実に過ぎるように、先行する投入を終わらせる
            try? bench.gpu.settle()
        }
        try #require(failure == nil)

        #expect(
            bench.isResident(face),
            """
            draw の中で置いて手放した絵の面が、そのフレームの投入が終わる前に常駐から外れた。
            束が面だけを抱えて持ち主 (Image) を抱えていないと、持ち主が死んだ時点の番号で
            外れる ([#1079](https://github.com/mokume-metal/mokume/issues/1079))。
            """)
        try expectReleasedAfterSettling(bench, face)
    }

    /// 描画先が死ぬと面を退かせるようになった ([#795]) ことで開きうる穴を見る。描き場所の
    /// 投入はフレームの**内側で**出るので、束が描画先を抱えていないと、親の投入に番号が
    /// 付く前に描き場所の番で外れる — 絵 (`Image`) と違い、描き場所は面を読む投入より
    /// 前に自分の投入を持つ。
    ///
    /// [#795]: https://github.com/mokume-metal/mokume/issues/795
    @Test("draw の中で描いて置いて手放した描き場所の面は、親のフレームの投入が終わるまで外れない")
    func graphicsDroppedInsideDrawStaysUntilRead() throws {
        let bench = try makeBench()
        let canvas = bench.canvas
        var face: (any MTLTexture)?
        var failure: (any Error)?

        try canvas.draw {
            do {
                let graphics = try canvas.createGraphics(16, 16)
                try graphics.draw {
                    graphics.noStroke()
                    graphics.circle(8, 8, 6)
                }
                face = graphics.output.texture
                // 描き場所自身の投入を、手放す前に終わらせる。刈りが描き場所の番を確実に
                // 過ぎるので、抱え方が壊れていれば必ず赤くなる
                try bench.gpu.settle()
                canvas.image(graphics, 0, 0)
            } catch {
                failure = error
            }
        }
        try #require(failure == nil)

        #expect(
            bench.isResident(face),
            """
            draw の中で描いて置いて手放した描き場所の面が、親のフレームの投入が終わる前に
            常駐から外れた。束が面だけを抱えて描画先 (RenderTarget) を抱えていないと、描画先が
            死んだ時点の番号で外れる
            ([#795](https://github.com/mokume-metal/mokume/issues/795) 条件 7・
            [#1079](https://github.com/mokume-metal/mokume/issues/1079))。
            """)
        try expectReleasedAfterSettling(bench, face)
    }

    @Test("1 フレームが投入を 2 つ以上出しても、置いて手放した絵の面は読み終わるまで外れない")
    func pictureSurvivesAnInterveningSubmission() throws {
        let bench = try makeBench()
        let canvas = bench.canvas
        // **置かない**描き場所。置くと、描き場所が変わる前に置いた側を描き切らせる仕掛けが
        // 親を途中で投入し、面は正当に外れてしまう
        let other = try canvas.createGraphics(8, 8)
        var face: (any MTLTexture)?
        var failure: (any Error)?

        try canvas.draw {
            do {
                let picture = try canvas.createImage(16, 16)
                face = picture.texture
                canvas.image(picture, 0, 0)
                // 番号を 1 つ進める投入を挟む。「番号 +1 まで待つ」直し方はここで破れる
                try other.draw { other.rect(0, 0, 4, 4) }
            } catch {
                failure = error
            }
            try? bench.gpu.settle()
        }
        try #require(failure == nil)

        #expect(
            bench.isResident(face),
            "間に別の投入を挟んだら、置いて手放した絵の面が読まれる前に常駐から外れた")
        try expectReleasedAfterSettling(bench, face)
    }

    @Test("フレームの途中で字形の面を広げても、前の面は同じフレームが読み終わるまで外れない")
    func previousGlyphPageSurvivesGrowthInsideDraw() throws {
        let bench = try makeBench()
        let canvas = bench.canvas
        var previous: (any MTLTexture)?
        var failure: (any Error)?

        try canvas.draw {
            canvas.text("mokume", 2, 16)
            previous = canvas.atlas.texture
            do {
                try canvas.atlas.grow(gpu: bench.gpu)
            } catch {
                failure = error
            }
            try? bench.gpu.settle()
        }
        try #require(failure == nil)
        try #require(canvas.atlas.texture !== previous)

        #expect(
            bench.isResident(previous),
            """
            フレームの途中で字形の面を広げたら、前の面が、それを指す列の投入より先に常駐から
            外れた。広げた側 (GlyphAtlas.grow) が前の面を退かせる番は、指す列が投入される
            前の番号になる ([#1079](https://github.com/mokume-metal/mokume/issues/1079))。
            """)
        try expectReleasedAfterSettling(bench, previous)
    }

    @Test("粒を置いて手放しても、読み戻しを挟んだフレームが読み終わるまで置き場所は外れない")
    func particleStorageSurvivesAReadBackInsideDraw() throws {
        let bench = try makeBench()
        let canvas = bench.canvas
        let probe = try canvas.makeNumbers(count: 1)
        var storage: (any MTLBuffer)?
        var failure: (any Error)?

        try canvas.draw {
            do {
                let dust = try canvas.makeParticles(count: 16)
                storage = dust.instances.storage
                canvas.particles(dust)
            } catch {
                failure = error
            }
            // 積んだ計算を先に流す読み戻し。計算が抱えていた粒の置き場の持ち主は、ここで
            // 降りる。列は置き場所を読むまで、まだ投入されていない
            _ = canvas.read(probe)
            try? bench.gpu.settle()
        }
        try #require(failure == nil)

        #expect(
            bench.isResident(storage),
            """
            粒を置いて手放し、同じフレームで読み戻しを挟んだら、置き場所がフレームの描き切りに
            読まれる前に常駐から外れた。列が置き場所を生で持ち、持ち主 (Numbers) を抱えて
            いない ([#1079](https://github.com/mokume-metal/mokume/issues/1079))。
            """)
        try expectReleasedAfterSettling(bench, storage)
    }

    @Test("フレームの外で置いて手放した絵の面は、それを投入するフレームが読み終わるまで外れない")
    func pictureDroppedOutsideFrameStaysUntilRead() throws {
        let bench = try makeBench()
        let canvas = bench.canvas
        var face: (any MTLTexture)?

        // `setup()` の中で置く並び。描く口はフレームの外でも溜まり、最初のフレームで投入される
        do {
            let picture = try canvas.createImage(16, 16)
            face = picture.texture
            canvas.image(picture, 0, 0)
        }
        try bench.gpu.settle()
        try canvas.draw {}

        #expect(
            bench.isResident(face),
            "フレームの外で置いて手放した絵の面が、それを投入するフレームが読む前に常駐から外れた")
        try expectReleasedAfterSettling(bench, face)
    }

    @Test("保持した形が置いた絵の面は、元の絵を手放しても形が生きている間は外れない")
    func shapeKeepsItsPictureResident() throws {
        let bench = try makeBench()
        let canvas = bench.canvas
        var face: (any MTLTexture)?
        var shape: Shape?

        do {
            let picture = try canvas.createImage(16, 16)
            face = picture.texture
            shape = canvas.createShape { canvas.image(picture, 0, 0) }
        }
        try bench.gpu.settle()
        try #require(shape != nil)
        // 形は捕まえた変数越しに読む。取り出して束縛すると、`shape = nil` の後も生き残る
        try canvas.draw { if let shape { canvas.shape(shape, 0, 0) } }

        #expect(
            bench.isResident(face),
            """
            保持した形が置いた絵を手放したら、形がまだ読むのに面が常駐から外れた。形の区間が
            面だけを抱えて持ち主を抱えていない
            ([#1178](https://github.com/mokume-metal/mokume/issues/1178))。
            """)
        // 形を手放すまでは外れない。手放したら外れる
        try bench.gpu.settle()
        #expect(bench.isResident(face), "形が生きているのに、読み終えた後で面が外れた")
        shape = nil
        try expectReleasedAfterSettling(bench, face)
    }

    @Test("保持した形が書いた字の面は、字形の面を広げた後も形が生きている間は外れない")
    func shapeKeepsItsGlyphPageResident() throws {
        let bench = try makeBench()
        let canvas = bench.canvas
        var shape: Shape? = canvas.createShape { canvas.text("mokume", 2, 16) }
        let previous = canvas.atlas.texture
        try canvas.atlas.grow(gpu: bench.gpu)
        try bench.gpu.settle()
        try #require(shape != nil)
        try canvas.draw { if let shape { canvas.shape(shape, 0, 0) } }

        #expect(
            bench.isResident(previous),
            """
            字を書いた形を持ったまま字形の面を広げたら、形がまだ読む前の面が常駐から外れた
            ([#1178](https://github.com/mokume-metal/mokume/issues/1178))。
            """)
        shape = nil
        try expectReleasedAfterSettling(bench, previous)
    }

    @Test("保持した形の塗りが読む面は、断片の面を差し替えて元の絵を手放しても外れない")
    func shapeKeepsItsShaderSurfaceResident() throws {
        let bench = try makeBench()
        let canvas = bench.canvas
        var face: (any MTLTexture)?
        var shape: Shape?
        var shader: Shader?

        do {
            let first = try canvas.createImage(4, 4)
            face = first.texture
            shader = try canvas.makeShader(
                """
                float4 paint(Fragment in, Values values, Surfaces surfaces) {
                    return mokume_sample(surfaces.tone, in.place);
                }
                """,
                surfaces: ["tone": .image(first)])
        }
        let toned = try #require(shader)
        shape = canvas.createShape {
            canvas.shader(toned)
            canvas.rect(0, 0, 16, 16)
        }
        // 断片が元の絵を手放す。形の区間は取り込んだ時点の面を読み続ける
        toned.set("tone", .image(try canvas.createImage(4, 4)))
        try bench.gpu.settle()
        try #require(shape != nil)
        try canvas.draw { if let shape { canvas.shape(shape, 0, 0) } }

        #expect(
            bench.isResident(face),
            """
            形の塗りが取り込んだ面を、断片の差し替えで元の絵ごと手放したら、形がまだ読むのに
            常駐から外れた ([#1178](https://github.com/mokume-metal/mokume/issues/1178) 条件 4)。
            """)
        shape = nil
        try expectReleasedAfterSettling(bench, face)
    }
}
