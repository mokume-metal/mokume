// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 画素の読み書きの検査。GPU を要する。
@Suite(
    "画素",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct PixelsTests {
    private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    // MARK: - 往復

    /// 完了条件「読んだ値をそのまま書き戻すと絵が変わらない」。
    ///
    /// **半透明を含む絵で確かめる。** 公開する値と内部の表現の変換が非対称でも、
    /// 不透明な画素では割り戻しの掛け戻しが恒等になってしまい、破れが出ない。
    @Test("読んだ値をそのまま書き戻しても、半透明を含む絵が変わらない")
    func readingAndWritingBackLeavesTranslucentArtworkUnchanged() throws {
        let canvas = try makeCanvas(width: 32, height: 32)
        // **下地まで透ける絵にする。** 不透明な下地を敷くと、重ねた半透明が合成の
        // 時点で不透明に潰れ、面の上に残る画素が 1 つも半透明にならない。そうなると
        // この検査は不透明な絵しか見ておらず、非対称を通してしまう
        try canvas.draw {
            canvas.background(.display(red: 0, green: 0, blue: 0, alpha: 0))
            canvas.noStroke()
            canvas.fill(LinearRGBA(straightRed: 1, green: 0.3, blue: 0.1, alpha: 0.35))
            canvas.circle(16, 16, 24)
            canvas.fill(LinearRGBA(straightRed: 0.2, green: 0.9, blue: 1, alpha: 0.5))
            canvas.rect(4, 4, 16, 16)
        }

        let before = try canvas.target.readPixels()
        // 半透明の画素が実際に面へ残っていることを先に確かめる。全部不透明なら
        // この検査は何も見ていない
        let alpha = before[16, 16].alpha
        #expect(alpha > 0 && alpha < 1, "面に半透明の画素が残っていない (α=\(alpha))")

        try canvas.draw {
            for y in 0..<32 {
                for x in 0..<32 { canvas.set(x, y, canvas.get(x, y)) }
            }
        }

        #expect(try canvas.target.readPixels() == before)
    }

    /// 完了条件「描いた図形の中心の画素が、指定した色を量子化した値と一致する」。
    @Test("描いた図形の中心の画素が、指定した色を量子化した値と一致する")
    func centreOfAShapeCarriesTheColourItWasGiven() throws {
        let canvas = try makeCanvas(width: 32, height: 32)
        let color = LinearRGBA.display(red: 0.25, green: 0.5, blue: 0.75)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.fill(color)
            canvas.rect(8, 8, 16, 16)
        }

        // 半精度浮動小数へ量子化した値と比べる。指定した Float とそのまま比べると、
        // 検査が「量子化したか」ではなく「精度が落ちたか」を見てしまう。
        //
        // **挟む 2 つの半精度のどちらかと一致すればよい。** GPU が描き場所へ書くときの丸めは
        // 最寄りとは限らず、半精度の目盛りの途中にある値は下の目盛りへ落ちることがある
        // (原色を移した後の青 0.49213 は、最寄りの 0.49219 ではなく 0.49194 として書かれた — #911)
        func isQuantized(_ drawn: Float, _ given: Float) -> Bool {
            let below = Float(Float16(given).nextDown)
            let above = Float(Float16(given).nextUp)
            let nearest = Float(Float16(given))
            return drawn == nearest || drawn == below || drawn == above
        }
        let drawn = canvas.get(16, 16)
        #expect(isQuantized(drawn.red, color.red))
        #expect(isQuantized(drawn.green, color.green))
        #expect(isQuantized(drawn.blue, color.blue))
        #expect(drawn.alpha == Float(Float16(color.alpha)))
    }

    // MARK: - 整列

    /// 完了条件「面の幅が整列の要求を満たさないときも正しく読める」。
    ///
    /// 幅 × 1 画素のバイト数が整列の単位の倍数にならない幅を選ぶ。行の間隔を広げずに
    /// 素直に並べると、2 行目以降が丸ごとずれる。
    @Test(
        "整列の要求を満たさない幅でも、置いた画素が置いた場所から読める",
        arguments: [1, 3, 7, 13, 63, 129, 963])
    func readsCorrectlyAtWidthsThatDoNotMeetTheAlignment(width: Int) throws {
        let canvas = try makeCanvas(width: width, height: 5)
        try canvas.draw { canvas.background(.linear(red: 0, green: 0, blue: 0)) }

        // 行ごとに違う色を置き、行が混ざっていないことを見る
        try canvas.draw {
            for y in 0..<5 {
                for x in 0..<width {
                    canvas.set(
                        x, y,
                        .linear(red: Float(y) / 4, green: Float(x % 8) / 8, blue: 0.5))
                }
            }
        }

        for y in 0..<5 {
            for x in 0..<width {
                #expect(
                    canvas.get(x, y)
                        == .linear(red: Float(y) / 4, green: Float(x % 8) / 8, blue: 0.5),
                    "(\(x), \(y)) / 幅 \(width)")
            }
        }
    }

    @Test("整列の要求を満たさない幅でも、書き出した絵が読んだ画素と一致する", arguments: [3, 13, 63])
    func writtenImageAgreesWithThePixelsAtUnalignedWidths(width: Int) throws {
        let canvas = try makeCanvas(width: width, height: 3)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            // 作業空間の原色で塗る。純色のまま 255 / 0 に出るので、行ごとに完全一致で読める
            canvas.fill(.linear(red: 1, green: 0, blue: 0))
            canvas.rect(0, 1, Float(width), 1)
        }

        let image = try canvas.target.encodeForDisplay()
        for x in 0..<width {
            #expect(image[x, 0] == (0, 0, 0, 255))
            #expect(image[x, 1] == (255, 0, 0, 255))
        }
    }

    // MARK: - 待つ場所

    @Test("そのフレームでそこまでに描いたものが読める")
    func readsWhatWasDrawnEarlierInTheSameFrame() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        var sampled = LinearRGBA.transparent
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.fill(.linear(red: 1, green: 0, blue: 0))
            canvas.rect(0, 0, 16, 16)
            sampled = canvas.get(8, 8)
        }
        #expect(sampled == .linear(red: 1, green: 0, blue: 0))
    }

    @Test("画素を読んだあとに描いた図形も、同じフレームの絵に残る")
    func shapesDrawnAfterReadingStillLandInTheFrame() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            _ = canvas.get(0, 0)
            canvas.noStroke()
            canvas.fill(.linear(red: 0, green: 1, blue: 0))
            canvas.rect(0, 0, 16, 16)
        }
        #expect(try canvas.target.readPixels()[8, 8] == .linear(red: 0, green: 1, blue: 0))
    }

    /// **描き切りをフレームの途中で挟んでも、図形が 2 度描かれない。**
    ///
    /// 溜めたものの片付けを描き切りの側に持たせていないと、途中で描き切ったときに
    /// 頂点が残り、フレームの終わりにもう一度描かれる。半透明ならそこだけ濃くなる。
    @Test("途中で画素を読んでも、図形が 2 度描かれない")
    func readingMidFrameDoesNotDrawShapesTwice() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        let translucent = LinearRGBA(straightRed: 1, green: 1, blue: 1, alpha: 0.5)

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.fill(translucent)
            canvas.rect(0, 0, 16, 16)
        }
        let once = try canvas.target.readPixels()[8, 8]

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.fill(translucent)
            canvas.rect(0, 0, 16, 16)
            _ = canvas.get(0, 0)
        }
        #expect(try canvas.target.readPixels()[8, 8] == once)
    }

    /// **背景は 1 フレームに 1 度しか効かない。**
    ///
    /// 描き切りが背景の指定を消さないと、フレームの途中で読んだあとの描き切りが
    /// もう一度塗り直し、読む前に描いた図形が消える。
    @Test("画素を読んだあとの描き切りが、背景をもう一度塗らない")
    func readingMidFrameDoesNotRepaintTheBackground() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.fill(.linear(red: 1, green: 0, blue: 0))
            canvas.rect(0, 0, 16, 16)
            _ = canvas.get(0, 0)
        }
        #expect(try canvas.target.readPixels()[8, 8] == .linear(red: 1, green: 0, blue: 0))
    }

    /// **待つ印はフレームごとに戻る。** 戻らないと、2 フレーム目以降の読み取りが
    /// 描き切りを通らず、1 フレーム目の絵を読んでしまう。
    @Test("フレームが変わると、そのフレームの絵が読める")
    func eachFrameReadsItsOwnDrawing() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        var sampled: [LinearRGBA] = []
        for green in [Float(0.25), 0.5, 0.75] {
            try canvas.draw {
                canvas.background(.linear(red: 0, green: green, blue: 0))
                sampled.append(canvas.get(8, 8))
            }
        }
        #expect(
            sampled == [
                .linear(red: 0, green: 0.25, blue: 0),
                .linear(red: 0, green: 0.5, blue: 0),
                .linear(red: 0, green: 0.75, blue: 0),
            ])
    }

    @Test("画素を触らないフレームでは、読める状態にする印が戻る")
    func theLoadedFlagResetsEachFrame() throws {
        let canvas = try makeCanvas(width: 8, height: 8)
        try canvas.draw { _ = canvas.get(0, 0) }
        #expect(canvas.hasLoadedPixels)
        try canvas.draw {}
        #expect(!canvas.hasLoadedPixels)
    }

    // MARK: - 写し (#753)

    /// 完了条件「読まないスケッチは 1 バイトも払わない」。描画先は GPU 専用の面で、
    /// 画素の窓はその写しである。写しは画素を頼まれたときにだけ作られる。
    @Test("画素を触らない面は、何フレーム描いても写しを持たない")
    func aCanvasThatNeverReadsPixelsHasNoMirror() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        for _ in 0..<3 {
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.rect(2, 2, 8, 8)
            }
        }
        #expect(canvas.target.pixelMirror == nil)
        #expect(canvas.target.pixelReadbacksEncoded == 0)
        #expect(canvas.target.pixelWriteBacksEncoded == 0)
    }

    /// 読む前の描き切りが読み戻しを同じコマンドに積むので、続けて何画素読んでも blit は増えない。
    @Test("画素を読むフレームは、読み戻しを 1 本だけ積む")
    func aFrameThatReadsPixelsEncodesOneReadback() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            for y in 0..<16 {
                for x in 0..<16 { _ = canvas.get(x, y) }
            }
            _ = canvas.pixels
        }
        #expect(canvas.target.pixelReadbacksEncoded == 1)
        #expect(canvas.target.pixelWriteBacksEncoded == 0, "読むだけなのに書き戻している")
    }

    /// 書き戻しは `set` を使ったフレームだけが払う。
    @Test("書き戻しは、画素へ書いたフレームだけが積む")
    func onlyFramesThatWritePixelsEncodeAWriteBack() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            _ = canvas.get(0, 0)
        }
        #expect(canvas.target.pixelWriteBacksEncoded == 0)

        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.set(3, 3, .linear(red: 1, green: 0, blue: 0))
        }
        #expect(canvas.target.pixelWriteBacksEncoded == 1)
        // 書いた画素は、次に読むときに描画先から戻ってくる (写しをそのまま返したのではない)
        try canvas.draw { _ = canvas.get(0, 0) }
        #expect(canvas.target.pixelWriteBacksEncoded == 1, "書いていないフレームが書き戻している")
        #expect(canvas.get(3, 3) == .linear(red: 1, green: 0, blue: 0))
    }

    /// 書いた画素の上に、そのフレームの続きの図形が載る (書き戻しが描画より先に積まれる)。
    @Test("画素へ書いたあとに描いた図形が、書いた画素の上に載る")
    func shapesDrawnAfterWritingLandOnTopOfTheWrittenPixels() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.pixels.fill(.linear(red: 1, green: 0, blue: 0))
            canvas.noStroke()
            canvas.fill(.linear(red: 0, green: 1, blue: 0))
            canvas.rect(0, 0, 8, 16)
        }
        let pixels = try canvas.target.readPixels()
        #expect(pixels[4, 8] == .linear(red: 0, green: 1, blue: 0), "図形が書いた画素の下に隠れた")
        #expect(pixels[12, 8] == .linear(red: 1, green: 0, blue: 0), "書いた画素が戻っていない")
    }

    // MARK: - 面としての振る舞い

    @Test("範囲の外を読むと透明が返り、範囲の外へ書いても何も起きない")
    func outOfRangeAccessIsHarmless() throws {
        let canvas = try makeCanvas(width: 4, height: 4)
        try canvas.draw { canvas.background(.linear(red: 1, green: 1, blue: 1)) }

        #expect(canvas.get(-1, 0) == .transparent)
        #expect(canvas.get(4, 0) == .transparent)
        #expect(canvas.get(0, -1) == .transparent)
        #expect(canvas.get(0, 4) == .transparent)

        canvas.set(-1, 0, .linear(red: 0, green: 0, blue: 0))
        canvas.set(4, 4, .linear(red: 0, green: 0, blue: 0))
        #expect(canvas.get(0, 0) == .linear(red: 1, green: 1, blue: 1))
    }

    /// 完了条件「画素の面・読み出した画素・絵の 3 つが、範囲の外で同じ値を返す」(#1436)。
    /// 表示できる形にした絵 (``DisplayImage``) も、同じ位置で透明 (0, 0, 0, 0) を返す (#1590)。
    ///
    /// 読み取りは決して落ちない (ADR-0020 決定 5) のだから、画素を読む口のどれを
    /// 選んでも範囲の外の答えは変わらない。**内側は白で埋める** — 透明のままだと、
    /// 範囲の外で内側の値を返す口があっても一致してしまう。
    @Test("範囲の外では、画素の面・読み出した画素・絵・表示できる形の絵が同じ透明を返す")
    func everyPixelReaderAgreesOutside() throws {
        let canvas = try makeCanvas(width: 4, height: 4)
        let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)
        try canvas.draw { canvas.background(white) }
        let image = try canvas.createImage(4, 4)
        for y in 0..<4 {
            for x in 0..<4 { image.set(x, y, white) }
        }
        let buffer = try canvas.target.readPixels()
        let shown = try canvas.target.encodeForDisplay()

        for (x, y) in [(-1, 0), (4, 0), (0, -1), (0, 4)] {
            let surface = canvas.pixels[x, y]
            #expect(surface == .transparent, "画素の面 (\(x), \(y))")
            #expect(buffer[x, y] == surface, "読み出した画素 (\(x), \(y))")
            #expect(image.get(x, y) == surface, "絵 (\(x), \(y))")
            // バイトで持つので LinearRGBA とは比べられない。透明は 4 成分とも 0
            #expect(shown[x, y] == (0, 0, 0, 0), "表示できる形の絵 (\(x), \(y))")
        }
    }

    @Test("画素の面は描画先そのもので、写しではない")
    func thePixelSurfaceIsTheTargetItself() throws {
        let canvas = try makeCanvas(width: 8, height: 8)
        try canvas.draw { canvas.background(.linear(red: 0, green: 0, blue: 0)) }

        canvas.pixels[2, 3] = .linear(red: 1, green: 0, blue: 0)
        // 送り直しの手順を挟まずに、書き出した絵へ届く
        #expect(try canvas.target.encodeForDisplay()[2, 3] == (255, 0, 0, 255))
    }

    @Test("面全体を 1 色で埋められる")
    func fillsTheWholeSurface() throws {
        let canvas = try makeCanvas(width: 13, height: 3)
        try canvas.draw { canvas.background(.linear(red: 0, green: 0, blue: 0)) }

        canvas.pixels.fill(.linear(red: 0, green: 0.5, blue: 1))
        for y in 0..<3 {
            for x in 0..<13 {
                #expect(canvas.pixels[x, y] == .linear(red: 0, green: 0.5, blue: 1))
            }
        }
    }

    @Test("画素の数は面の広さと一致する")
    func countMatchesTheSurfaceArea() throws {
        let canvas = try makeCanvas(width: 13, height: 3)
        #expect(canvas.pixels.count == 39)
    }

    // MARK: - 投入されなかった書き戻し (#1183)

    /// **書き戻しを積んだ後で描き切りが投げても、CPU の書き込みを「戻した」ことにしない。**
    /// 戻したことにすると、次の描き切りは書き戻しを積まず、読み出しは描画先から写し直すので、
    /// `set` した画素が黙って消える ([#1183])。
    ///
    /// 投げさせるのは書き戻しより後 — 形の置き場を伸ばし、その取り直しの待ちで投げる。
    ///
    /// [#1183]: https://github.com/mokume-metal/mokume/issues/1183
    @Test("書き戻しを積んだ後で描き切りが投げても、書いた画素は次のフレームで戻る")
    func writesSurviveAFlushThatThrowsAfterEncodingTheWriteBack() throws {
        let canvas = try makeCanvas(width: 16, height: 16)
        let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            // 形の置き場を 1 度取らせる。面の外に置くので絵には出ない
            canvas.rect(100, 100, 1, 1)
        }

        let encoded = canvas.target.pixelWriteBacksEncoded
        #expect(throws: RenderFailure.self) {
            try canvas.draw {
                canvas.set(3, 3, red)
                canvas.gpu.failSettleForTesting = .timedOut(seconds: RenderDevice.waitLimitSeconds)
                for index in 0..<5000 { canvas.rect(100 + index % 16, 100, 1, 1) }
            }
        }
        canvas.gpu.failSettleForTesting = nil
        #expect(
            canvas.target.pixelWriteBacksEncoded == encoded + 1,
            "書き戻しを積む前に投げている — この検査は書き戻しの後で投げる経路を見ていない")

        try canvas.draw {}
        #expect(
            try canvas.target.readPixels()[3, 3] == red,
            "投入されなかった書き戻しを「戻した」ことにして、書いた画素を失っている")
    }
}
