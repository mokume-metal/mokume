// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// `filter(_:)` は呼んだ時点の絵に効果をその場で掛け、`Image.filtered(_:)` は同じ並びを掛けた新しい絵を返す
/// ([#2455])。`.threshold(level:)` は明るさ (`brightness(_:)` と同じ物差し) で 2 値にする。
///
/// 期待は絵ぜんぶへ掛ける `effects(_:)` の絵と、手で数えた画素から作り、検査の対象と同じ口から作らない。
///
/// [#2455]: https://github.com/mokume-metal/mokume/issues/2455
@Suite(
    "filter()・Image.filtered()・threshold",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FilterImmediateTests {
    private func makeCanvas(width: Int = 100, height: Int = 100) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    private func read(_ canvas: Canvas) throws -> DisplayImage {
        try canvas.target.encodeForDisplay()
    }

    // MARK: - 呼んだ時点で掛かる (完了条件 1)

    /// 左に白い矩形、右に赤い矩形。間で `apply` を呼ぶ。
    private func scene(on canvas: Canvas, between apply: () -> Void) {
        canvas.background(0)
        canvas.noStroke()
        canvas.fill(255)
        canvas.rect(0, 0, 50, 100)
        apply()
        canvas.fill(255, 0, 0)
        canvas.rect(60, 0, 40, 100)
    }

    @Test("filter() の後に描いたものには掛からず、前に描いたものには掛かる。effects() は後のものにも掛かる")
    func laterDrawingIsLeftAlone() throws {
        let blur = [Effect.blur(radius: 8)]
        let immediate = try makeCanvas()
        try immediate.draw { scene(on: immediate) { immediate.filter(blur) } }
        let deferred = try makeCanvas()
        try deferred.draw { scene(on: deferred) { deferred.effects(blur) } }
        let plain = try makeCanvas()
        try plain.draw { scene(on: plain) {} }
        let after = try read(immediate)
        let all = try read(deferred)
        let untouched = try read(plain)

        // 白い矩形の縁 (x = 50 付近) は、どちらもぼける
        #expect(after[49, 50].red < 255 && after[49, 50].red > 0, "filter の前に描いた縁がぼけていない")
        // 赤い矩形の内側は、filter の後に描いたので、ぼけない
        #expect(after[61, 50] == untouched[61, 50], "filter の後に描いた赤が、ぼけた")
        #expect(after[80, 50] == untouched[80, 50])
        // effects() で書くと、同じ赤の縁 (x = 61) もぼける — 比べる相手が「何もしない口」でない
        #expect(all[61, 50] != untouched[61, 50], "effects() が後に描いたものにも掛かるはずが、掛かっていない")
    }

    // MARK: - 持ち越す (完了条件 2)

    /// 1 枚目だけ背景を塗り、中央に点を置く。以後は毎フレーム `apply` だけを呼ぶ。広がった画素の数を返す。
    private func spread(over frames: Int, _ apply: (Canvas) -> Void) throws -> [Int] {
        let canvas = try makeCanvas(width: 64, height: 64)
        var counts: [Int] = []
        for frame in 0..<frames {
            try canvas.draw {
                if frame == 0 {
                    canvas.background(0)
                    canvas.noStroke()
                    canvas.fill(255)
                    canvas.rect(31, 31, 2, 2)
                }
                apply(canvas)
            }
            let image = try read(canvas)
            var lit = 0
            for y in 0..<64 {
                for x in 0..<64 where image[x, y].red > 0 { lit += 1 }
            }
            counts.append(lit)
        }
        return counts
    }

    @Test("filter() で掛けた絵は次のフレームへ持ち越し、広がりが回ごとに増える。effects() は増えない")
    func filteredPictureCarriesOver() throws {
        let filtered = try spread(over: 3) { $0.filter([.blur(radius: 2)]) }
        #expect(filtered[1] > filtered[0] && filtered[2] > filtered[1], "広がりが増えない: \(filtered)")
        let deferred = try spread(over: 3) { $0.effects([.blur(radius: 2)]) }
        #expect(deferred[1] == deferred[0] && deferred[2] == deferred[0], "effects() の広がりが回ごとに増えた: \(deferred)")
    }

    // MARK: - Image.filtered (完了条件 3)

    @Test("filtered() は掛けた新しい絵を返し、元の絵を変えない。返った絵は元が書き換わっても動かない")
    func filteredReturnsANewPicture() throws {
        let canvas = try makeCanvas(width: 4, height: 4)
        let source = try canvas.createImage(2, 1)
        let dark = LinearRGBA.display(red: 0.4, green: 0.4, blue: 0.4)
        let light = LinearRGBA.display(red: 0.6, green: 0.6, blue: 0.6)
        source.set(0, 0, dark)
        source.set(1, 0, light)
        // 面は半精度で持つので、置いた色を読み直した値を「元の絵」とする
        let (darkBefore, lightBefore) = (source.get(0, 0), source.get(1, 0))

        let result = source.filtered([.threshold(level: 0.5)])
        #expect(result !== source)
        #expect((result.width, result.height) == (2, 1))
        #expect(result.get(0, 0) == LinearRGBA.linear(red: 0, green: 0, blue: 0), "暗い側が黒でない")
        #expect(result.get(1, 0) == LinearRGBA.linear(red: 1, green: 1, blue: 1), "明るい側が白でない")
        #expect(source.get(0, 0) == darkBefore && source.get(1, 0) == lightBefore, "元の絵が変わった")

        // 元が書き換わっても (カメラの次の 1 枚のように)、返った絵は動かない
        source.set(0, 0, LinearRGBA.display(red: 1, green: 0, blue: 0))
        #expect(result.get(0, 0) == LinearRGBA.linear(red: 0, green: 0, blue: 0))
    }

    @Test("filtered([]) は掛けずに写しを返す")
    func emptyListIsACopy() throws {
        let canvas = try makeCanvas(width: 4, height: 4)
        let source = try canvas.createImage(2, 1)
        source.set(0, 0, LinearRGBA.display(red: 0.2, green: 0.5, blue: 0.9))
        let result = source.filtered([])
        #expect(result !== source)
        #expect(result.get(0, 0) == source.get(0, 0))
    }

    // MARK: - threshold の物差し (完了条件 4)

    /// 1 画素ずつ別の色を置いて 2 値化し、画素を読む。
    private func thresholded(
        _ colors: [LinearRGBA], level: Float, background: Bool = false
    ) throws -> DisplayImage {
        let canvas = try makeCanvas(width: colors.count, height: 1)
        try canvas.draw {
            if background { canvas.background(0) }
            canvas.noStroke()
            for (index, color) in colors.enumerated() {
                canvas.fill(color)
                canvas.rect(Float(index), 0, 1, 1)
            }
            canvas.filter([.threshold(level: level)])
        }
        return try read(canvas)
    }

    @Test("明るさが level 以上の画素は白、未満は黒。物差しは brightness() と同じで、境目は 127 と 128")
    func thresholdFollowsTheBrightnessRuler() throws {
        let gray = { (value: Float) in LinearRGBA.display(red: value / 255, green: value / 255, blue: value / 255) }
        let image = try thresholded([gray(127), gray(128), gray(0), gray(255)], level: 0.5, background: true)
        #expect(image[0, 0] == (0, 0, 0, 255), "127/255 は 0.5 に届かない")
        #expect(image[1, 0] == (255, 255, 255, 255), "128/255 は 0.5 を越える")
        #expect(image[2, 0] == (0, 0, 0, 255))
        #expect(image[3, 0] == (255, 255, 255, 255))
    }

    @Test("明るさは R・G・B の最大で比べる。青だけの暗い色も、成分が level に届けば白")
    func thresholdUsesTheBrightestChannel() throws {
        let blueOnly = LinearRGBA.display(red: 0, green: 0, blue: 200 / 255)
        let dimBlue = LinearRGBA.display(red: 0, green: 0, blue: 100 / 255)
        let image = try thresholded([blueOnly, dimBlue], level: 0.5, background: true)
        #expect(image[0, 0] == (255, 255, 255, 255), "最大の成分が 0.78 なので白")
        #expect(image[1, 0] == (0, 0, 0, 255), "最大の成分が 0.39 なので黒")
    }

    @Test("アルファは動かさない。透明は透明のまま、半透明は半透明の白になる")
    func thresholdKeepsTheAlpha() throws {
        let half = LinearRGBA.display(red: 0.9, green: 0.9, blue: 0.9, alpha: 0.5)
        let image = try thresholded([half], level: 0.5)
        let kept = try #require(image[0, 0].alpha as UInt8?)
        #expect(abs(Int(kept) - 128) <= 1, "半透明のアルファが動いた: \(kept)")
        #expect(image[0, 0].red == 255 && image[0, 0].green == 255 && image[0, 0].blue == 255, "半透明の明るい画素が白でない")
        // 何も描かなかった所 (透明) はそのまま
        let canvas = try makeCanvas(width: 2, height: 1)
        try canvas.draw { canvas.filter([.threshold(level: 0)]) }
        #expect(try read(canvas)[0, 0] == (0, 0, 0, 0), "透明が塗られた")
    }

    @Test("level は 0…1 に締まり、数でない値は並びから外す")
    func thresholdClampsTheLevel() throws {
        let gray = { (value: Float) in LinearRGBA.display(red: value / 255, green: value / 255, blue: value / 255) }
        // 2 は 1 に締まる: 254/255 は届かず、255 だけが白
        let over = try thresholded([gray(254), gray(255)], level: 2, background: true)
        #expect(over[0, 0] == (0, 0, 0, 255) && over[1, 0] == (255, 255, 255, 255))
        // -1 は 0 に締まる: 黒い画素も 0 以上なので白
        let under = try thresholded([gray(0)], level: -1, background: true)
        #expect(under[0, 0] == (255, 255, 255, 255))
        // 数でない値は外す: 絵は変わらない
        let dropped = try thresholded([gray(100)], level: .nan, background: true)
        #expect(dropped[0, 0].red == 100 || abs(Int(dropped[0, 0].red) - 100) <= 1, "数でない level の効果が掛かった")
    }
}
