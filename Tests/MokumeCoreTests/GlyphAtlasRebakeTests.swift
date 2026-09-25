// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import Testing

@testable import MokumeCore

/// 上限の大きさの焼き場が埋まった後の検査。GPU を要する。
///
/// ## なぜ要るか
///
/// 焼き分けの鍵には大きさが入るので、`textSize()` を連続的に変えると鍵が際限なく増える。
/// 上限 (``GlyphAtlas/maximumSize``) の面が埋まると、以前はそれ以後に初めて使う字が
/// 1 つも描かれず、回復もしなかった ([#1342])。
///
/// ## 何を物差しにするか
///
/// 埋まったかどうかを面の中から覗かない。**描いた画素**で見る — 字に墨が乗ったかと、
/// 焼き直した後の字が最初に描いた絵と 1 バイトも違わないか。
///
/// [#1342]: https://github.com/mokume-metal/mokume/issues/1342
@Suite(
    "焼き場の焼き直し",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct GlyphAtlasRebakeTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    /// 検査で使う書体。**版が変わりにくいものを選ぶ** (``TextTests`` と同じ理由)。
    private let fontName = "Helvetica"

    /// 面を埋めるのに使う字の大きさ。**循環しない** — 番号ごとに必ず別の鍵になる。
    ///
    /// 600 付近の `Float` の刻みは 0.01 よりずっと細かいので、隣の番号と同じ値には
    /// 丸まらない。大きくしてあるのは、少ない字数で上限の面を埋めるためである
    /// (「M」1 字でおよそ 415×435 画素・上限の面 1 枚に 81 字)。
    private func fillerSize(_ index: Int) -> Float { 600 + Float(index) / 100 }

    /// 面を埋める字数の上限。**ここまでに届かなければ、検査の側が前提を外している。**
    private let fillerLimit = 400

    /// 埋める字を置く位置。「M」の左の縦棒が、窓の中を上から下まで通る。
    private let fillerX: Float = 8
    private let fillerBaseline: Float = 120

    private func makeCanvas() throws -> Canvas {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 128, height: 128)
        canvas.textFont(fontName)
        return canvas
    }

    /// 1 行だけのフレームを描いて、その絵を返す。
    private func drawAlone(
        _ string: String, size: Float, on canvas: Canvas, x: Float, baseline: Float
    ) throws -> DisplayImage {
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(size)
            canvas.text(string, x, baseline)
        }
        return try canvas.target.encodeForDisplay()
    }

    /// 墨が乗っている画素が 1 つでもあるか。背景は黒、字は白で描く。
    private func isInked(_ image: DisplayImage) -> Bool {
        for y in 0..<image.height {
            for x in 0..<image.width where image[x, y].red > 8 { return true }
        }
        return false
    }

    // MARK: - フレームをまたいで埋まる

    /// 条件 1・2 と、3 の前半 ([#1342] の完了条件)。
    ///
    /// **1 フレームに 1 字ずつ**焼く。どのフレームも上限の面にはゆうに収まるので、
    /// ここで字が欠けたなら、それは埋まった面から戻れていないということである。
    ///
    /// [#1342]: https://github.com/mokume-metal/mokume/issues/1342
    @Test("上限の面が埋まった後に初めて使う字も、前に使った字も描かれる")
    func glyphsAfterTheLimitAreStillDrawn() throws {
        let canvas = try makeCanvas()
        // 上限に届く前に使う字。**頁が替わった後に、同じ大きさでもう一度頼む**
        let earlier = try drawAlone("A", size: 32, on: canvas, x: 8, baseline: 40)
        try #require(isInked(earlier), "検査の前提: 最初の「A」が描けていない")

        var index = 0
        var turnedAtLimit = false
        while !turnedAtLimit {
            guard index < fillerLimit else {
                Issue.record(
                    """
                    \(fillerLimit) 字を焼いても、上限の頁が 1 度も替わらなかった\
                    (面は \(canvas.atlas.size))。
                    """)
                return
            }
            let pageBefore = canvas.atlas.texture
            let wasAtLimit = canvas.atlas.size == GlyphAtlas.maximumSize
            let image = try drawAlone(
                "M", size: fillerSize(index), on: canvas, x: fillerX, baseline: fillerBaseline)
            // 上限の面に届いた後は、**埋まった面に当たった字も含めて**どのフレームでも描かれる
            guard !wasAtLimit || isInked(image) else {
                Issue.record(
                    """
                    上限の面に届いた後、\(index) 番目の大きさ (\(fillerSize(index))) の「M」が\
                    描かれなかった。

                    埋まった面から戻る道が無いと、それ以後に初めて使う字は 1 つも出ない。
                    `textSize()` を毎フレーム変えるだけで届く
                    ([#1342](https://github.com/mokume-metal/mokume/issues/1342))。
                    """)
                return
            }
            turnedAtLimit = wasAtLimit && canvas.atlas.texture !== pageBefore
            index += 1
        }
        #expect(canvas.atlas.size == GlyphAtlas.maximumSize, "上限の頁が、上限より小さい")

        // 替わった頁には、先に使った「A」がまだ無い。**頼めば焼き直され、最初と同じ絵になる**
        let again = try drawAlone("A", size: 32, on: canvas, x: 8, baseline: 40)
        #expect(
            again.bytes == earlier.bytes,
            "頁が替わった後に焼き直した「A」が、最初に描いた「A」と違う")

        // 上限に届いた後に初めて使う、別の字
        let fresh = try drawAlone(
            "N", size: fillerSize(index), on: canvas, x: fillerX, baseline: fillerBaseline)
        #expect(isInked(fresh), "頁が替わった後に初めて使う「N」が描かれなかった")

        // 1 フレームで要る字は上限の面に収まっていたので、知らせる場面ではない
        #expect(
            canvas.warnings.message(for: .atlasFullInOneFrame) == nil,
            "フレームをまたいで埋まっただけなのに、知らせが出た")
    }

    // MARK: - 1 フレームのうちに溢れる

    /// 1 フレームで要る字が、焼き直しても上限の面に収まらないときの文面。**実装とは別の場所に
    /// 写して突き合わせる** (``WarningLogTests`` と同じ形) — 畳んだ拍子に変わっても気付ける。
    private let fullInOneFrameNotice =
        "text(): the characters one frame needs do not fit the baking area's limit of "
        + "4096x4096, even after it is baked afresh. The characters beyond that are "
        + "not drawn in such a frame — draw fewer different characters or text sizes in "
        + "one frame, or lower textSize()"

    /// 条件 3 の後半 ([#1342] の完了条件)。
    ///
    /// 上限の面は**前のフレームまでに**用意しておく。そうすると溢れるフレームは、まず焼き
    /// 直してから、その新しい頁も使い切る — 「焼き直しても収まらない」場面そのものになる。
    ///
    /// [#1342]: https://github.com/mokume-metal/mokume/issues/1342
    @Test("1 フレームで要る字が焼き直しても上限の面に収まらないときだけ、その場面を名乗る")
    func overflowingWithinOneFrameNamesTheScene() throws {
        let canvas = try makeCanvas()
        var index = 0
        // 1 フレームに 10 字ずつ焼いて、上限の面まで広げる。どのフレームも溢れない
        while canvas.atlas.size < GlyphAtlas.maximumSize {
            guard index < fillerLimit else {
                Issue.record("\(fillerLimit) 字を焼いても、面が上限まで広がらなかった")
                return
            }
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                for _ in 0..<10 {
                    canvas.textSize(fillerSize(index))
                    canvas.text("M", fillerX, fillerBaseline)
                    index += 1
                }
            }
        }
        #expect(
            canvas.warnings.message(for: .atlasFullInOneFrame) == nil,
            "1 フレームに 10 字しか使っていないのに、知らせが出た")

        // 知らせが出るまで、1 つのフレームで字を焼き続ける
        let pageBefore = canvas.atlas.texture
        var rebaked = false
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            while !canvas.warnings.hasWarned(.atlasFullInOneFrame), index < fillerLimit {
                canvas.textSize(fillerSize(index))
                canvas.text("M", fillerX, fillerBaseline)
                index += 1
                if canvas.atlas.texture !== pageBefore { rebaked = true }
            }
        }
        #expect(rebaked, "知らせる前に、このフレームで 1 度は焼き直していなければならない")
        #expect(
            canvas.warnings.message(for: .atlasFullInOneFrame) == fullInOneFrameNotice,
            "1 フレームのうちに上限の面が溢れたのに、その場面を名乗る知らせが出ていない")

        // 溢れたのはそのフレームだけである。次のフレームでは、また焼き直して描ける
        let next = try drawAlone(
            "N", size: fillerSize(index), on: canvas, x: fillerX, baseline: fillerBaseline)
        #expect(isInked(next), "溢れたフレームの次のフレームで、初めて使う字が描かれなかった")
    }

    // MARK: - 焼き直しの道

    /// 条件 4 ([#1342] の完了条件)。**広げるときと同じ道** — 新しい頁を作るだけで、いまの面は
    /// 書き換えない。書き換えるなら、前のフレームが読み終わるのを待つことになる。
    ///
    /// [#1342]: https://github.com/mokume-metal/mokume/issues/1342
    @Test("焼き直しは GPU を待たず、いまの面を書き換えずに、同じ大きさの新しい頁へ替える")
    func rebakingStartsAFreshPageWithoutWaiting() throws {
        let canvas = try makeCanvas()
        canvas.textSize(32)
        let resolved = try #require(canvas.typeface.glyph(for: "M"))
        let key = GlyphAtlas.Key(
            fontKey: resolved.fontKey, size: 32, style: .normal, glyph: resolved.glyph)
        let atlas = canvas.atlas
        let gpu = canvas.gpu
        guard case .found = atlas.entry(for: key, font: resolved.font) else {
            Issue.record("検査の前提: 「M」を焼けなかった")
            return
        }

        let previous = atlas.texture
        let side = atlas.size
        let bakedBefore = texels(of: previous, side: side)
        try #require(bakedBefore.contains { $0.w != 0 }, "検査の前提: 焼いた画素が面に無い")
        let settles = gpu.settleCalls

        try atlas.rebake(gpu: gpu)

        #expect(gpu.settleCalls == settles, "焼き直しが、GPU の完了を待った")
        #expect(atlas.texture !== previous, "焼き直しが、いまの面を使い回した")
        #expect(atlas.size == side, "焼き直しで、面の大きさが \(side) から \(atlas.size) に変わった")
        #expect(texels(of: previous, side: side) == bakedBefore, "焼き直しが、前の面を書き換えた")

        // 焼いた字形の控えも捨てている — 同じ字を頼むと、新しい頁へもう一度焼く (焼くときだけ待つ)
        guard case .found = atlas.entry(for: key, font: resolved.font) else {
            Issue.record("焼き直した後に「M」を焼けなかった")
            return
        }
        #expect(
            gpu.settleCalls == settles + 1,
            "焼き直した後の「M」を、新しい頁へ焼いていない (前の頁の控えが残っている)")
    }

    /// 面を読み戻す。**読み戻す先を 1 で埋めてから渡す** — 0 で埋めると、読み戻しが何も
    /// 書かなくても「透明のまま」に見える (``TextTests`` の 0 埋めの検査と同じ理由)。
    private func texels(of texture: any MTLTexture, side: Int) -> [SIMD4<Float16>] {
        var pixels = [SIMD4<Float16>](repeating: SIMD4(1, 1, 1, 1), count: side * side)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!, bytesPerRow: side * GlyphAtlas.bytesPerPixel,
                from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        }
        return pixels
    }
}
