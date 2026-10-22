// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 字形を焼く口は GPU を待たず、焼いた画素は描き切りが GPU のコピーで頁へ届ける
/// ([#1792](https://github.com/mokume-metal/mokume/issues/1792)・[#749](https://github.com/mokume-metal/mokume/issues/749))。GPU を要する。
///
/// 見るのは 4 つ。**焼いても待たないこと**・**焼いたフレームで字が欠けないこと** (頁を広げる・焼き直す
/// フレームを含む)・**打ち切られた投入が運んだ区画を届け直すこと**・**控えに載せられない大きさでも
/// 字が出ること** (逃げ道)。画素そのものは変わらない — 台帳の `text`・`textFlow` と字形の検査が見る。
@Suite(
    "字形を焼く口は待たず、描き切りが届ける",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct GlyphBakeDeliveryTests {
    private let black = Color.linear(red: 0, green: 0, blue: 0)
    private let white = Color.linear(red: 1, green: 1, blue: 1)

    private func makeCanvas(width: Int = 128, height: Int = 128, gpu: RenderDevice? = nil) throws
        -> Canvas
    {
        let canvas = try CanvasFixture.make(gpu: gpu ?? RenderDevice(), width: width, height: height)
        canvas.textFont("Helvetica")
        return canvas
    }

    private func inkedPixelCount(_ image: DisplayImage) -> Int {
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width where image[x, y].red > 8 { count += 1 }
        }
        return count
    }

    /// 多くの字を 1 フレームで初めて焼く場面 (頁が何度も広がる)。
    private func manyGlyphsFrame(_ canvas: Canvas) throws -> DisplayImage {
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            for line in 0..<60 {
                canvas.textSize(24 + Float(line) * 0.37)
                canvas.text("Hamburgefonts", 4, 10 + Float(line) * 9.5)
            }
        }
        return try canvas.target.encodeForDisplay()
    }

    // MARK: - 待たない (完了条件 1)

    @Test("新しい字・新しい大きさを焼いても、焼く口は GPU の完了を待たない")
    func bakingDoesNotWait() throws {
        let canvas = try makeCanvas()
        // 1 度描いて、頁も書体も暖めておく。以後の描き切りは待たない
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(30)
            canvas.text("Ag", 8, 60)
        }
        let gpu = canvas.gpu
        let settles = gpu.settleCalls
        let bakedBefore = canvas.atlas.bakedCount
        for frame in 0..<12 {
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                // 毎フレーム大きさが違う — 毎フレーム新しい字形を焼く (#1792 の場面)
                canvas.textSize(30 + Float(frame) * 0.7)
                canvas.text("Ag", 8, 60)
            }
        }
        #expect(canvas.atlas.bakedCount > bakedBefore, "検査の前提: 新しい字形を焼いていない")
        #expect(gpu.settleCalls == settles, "焼く口か描き切りが、GPU の完了を待った")
        #expect(canvas.atlas.page.directWrites == 0, "控えに載るのに、逃げ道で直に書いた")
    }

    // MARK: - 焼いたフレームで字が出る (完了条件 2)

    /// 焼いたそのフレームで描く。**頁を広げる・焼き直すフレームの前に焼いた字も欠けない** — 前の頁を
    /// 指す列がそこを読むので、前の頁にも控えを届ける。
    @Test("頁を広げながら焼いた 1 フレームは、字が出そろった後のフレームと同じ絵になる")
    func glyphsBakedInAGrowingFrameAreNotMissing() throws {
        let canvas = try makeCanvas(width: 600, height: 600)
        func frame() throws -> DisplayImage {
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                for line in 0..<60 {
                    canvas.textSize(24 + Float(line) * 0.37)
                    canvas.text("Hamburgefonts", 4, 10 + Float(line) * 9.5)
                }
            }
            return try canvas.target.encodeForDisplay()
        }
        let cold = try frame()
        let sizeAfterCold = canvas.atlas.size
        #expect(sizeAfterCold > GlyphAtlas.initialSize, "検査の前提: 頁が広がっていない")
        _ = try frame()
        let settled = try frame()
        #expect(inkedPixelCount(cold) > 0, "検査の前提: 何も描かれていない")
        // 配列ごと表明すると、食い違ったときに全画素が出力に流れる
        let same = cold.bytes == settled.bytes
        #expect(same, "広げながら焼いたフレームの絵が、字が出そろった後と違う (字が欠けた)")
    }

    @Test("焼き直しの直前に焼いた字も、焼き直したフレームで欠けない")
    func glyphsBakedBeforeARebakeInTheSameFrameAreNotMissing() throws {
        let canvas = try makeCanvas()
        func frame(rebakeInTheMiddle: Bool) throws -> DisplayImage {
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.textSize(40)
                canvas.text("Ag", 8, 50)
                // このフレームで焼いた字を持つ頁を、同じフレームの途中で替える。前の頁を指す列は
                // まだそこを読む
                if rebakeInTheMiddle { try? canvas.atlas.rebake(gpu: canvas.gpu) }
                canvas.textSize(44)
                canvas.text("Bh", 8, 110)
            }
            return try canvas.target.encodeForDisplay()
        }
        let straight = try frame(rebakeInTheMiddle: false)
        let rebaked = try frame(rebakeInTheMiddle: true)
        let same = straight.bytes == rebaked.bytes
        #expect(inkedPixelCount(rebaked) > 0, "検査の前提: 何も描かれていない")
        #expect(same, "焼き直しの前に焼いた字が、焼き直したフレームで欠けた")
    }

    // MARK: - 控えの量の上限 (#1792 の反証)

    /// 1 回の描き切りが届ける量がそのまま Canvas の控えの置き場の要求量になり、置き場は縮まない。
    /// 上限が無ければ、最初のフレームで大量に焼いただけで、置き場が太ったまま残る。
    @Test("多くの字を初めて焼くフレームでも、控えの置き場は上限の大きさに収まる")
    func stagingStorageStaysBounded() throws {
        // 対照: 上限を外すと、1 フレームで焼いた全部がそのまま置き場の大きさになる
        let unlimited = try makeCanvas(width: 600, height: 600)
        unlimited.atlas.pendingByteLimit = .max
        unlimited.atlas.pendingRegionLimit = .max
        _ = try manyGlyphsFrame(unlimited)
        let swollen = unlimited.uploadStorage.capacity
        try #require(swollen > 1 << 20, "検査の前提: 上限が無いのに置き場が太らない (\(swollen))")

        let bounded = try makeCanvas(width: 600, height: 600)
        bounded.atlas.pendingByteLimit = 64 << 10
        _ = try manyGlyphsFrame(bounded)
        // 頁ごとに上限 (+ 越える 1 区画) までしか積まない。頁は数回しか替わらない
        let capacity = bounded.uploadStorage.capacity
        #expect(capacity < swollen / 2, "置き場が上限なしと同じほど太った (\(capacity) と \(swollen))")
        #expect(bounded.atlas.page.directWrites + bounded.atlas.bakedCount > 0)
        #expect(bounded.atlas.page.pendingUploadByteCount <= 64 << 10 + (1 << 16))
    }

    /// 字 1 つに GPU のコピーが 1 本なので、区画の数にも上限を置く。越えたら待って直接書く。
    @Test("積んだ区画の数が上限を越えたら、その場で待って直接書き、控えは上限を越えない")
    func regionCountIsBounded() throws {
        let canvas = try makeCanvas()
        canvas.atlas.pendingRegionLimit = 8
        let resolved = try #require(canvas.typeface.glyph(for: "M"))
        var maxPending = 0
        for index in 0..<40 {
            let key = GlyphAtlas.Key(
                fontKey: resolved.fontKey, size: 12 + Float(index) * 0.5, style: .normal,
                glyph: resolved.glyph)
            guard case .found = canvas.atlas.entry(for: key, font: resolved.font) else {
                Issue.record("検査の前提: 焼けなかった")
                return
            }
            maxPending = max(maxPending, canvas.atlas.page.pendingRegionCount)
        }
        #expect(maxPending <= 8, "区画が上限を越えて控えに残った (\(maxPending))")
        #expect(canvas.atlas.page.directWrites > 0, "上限を越えたのに、直接書いていない")
    }

    @Test("控えの上限を越えて直接書いた字も、描き切りで届けた字も、同じ絵になる")
    func directlyWrittenGlyphsDrawTheSame() throws {
        let straight = try makeCanvas(width: 600, height: 600)
        let reference = try manyGlyphsFrame(straight)
        let tiny = try makeCanvas(width: 600, height: 600)
        tiny.atlas.pendingRegionLimit = 4
        tiny.atlas.pendingByteLimit = 16 << 10
        let image = try manyGlyphsFrame(tiny)
        #expect(tiny.atlas.page.directWrites > 0 || tiny.atlas.size > GlyphAtlas.initialSize)
        let same = reference.bytes == image.bytes
        #expect(inkedPixelCount(image) > 0, "検査の前提: 何も描かれていない")
        #expect(same, "上限を越えて直接書いた字の絵が、描き切りで届けた絵と違う")
    }

    // MARK: - コピーの前の待ち (#341)

    /// 届け直す区画は作りたての場所ではない。コピーの前に前の仕事が読み終わるのを待たないと、前の
    /// フレームがまだ読んでいる画素を上書きしうる。画像の届け直し・書き換えも同じ口に頼る。
    @Test("控えを届けるコピーの前に、前の仕事が読み終わるのを待つ仕掛けを積む")
    func uploadsWaitForEarlierWorkBeforeCopying() throws {
        let canvas = try makeCanvas()
        let waits = canvas.uploadWaitsEncoded
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(36)
            canvas.text("Q", 8, 60)
        }
        #expect(canvas.uploadWaitsEncoded - waits == 1, "字形を届けるコピーの前に待ちを積んでいない")
        // 画像も同じ口で届ける
        let image = try canvas.createImage(4, 4)
        image.fill(white)
        let before = canvas.uploadWaitsEncoded
        try canvas.draw { canvas.image(image, 0, 0) }
        #expect(canvas.uploadWaitsEncoded - before == 1, "画像を届けるコピーの前に待ちを積んでいない")
        // 届けるものが無いフレームは積まない
        let idle = canvas.uploadWaitsEncoded
        try canvas.draw { canvas.background(black) }
        #expect(canvas.uploadWaitsEncoded == idle)
    }

    // MARK: - 打ち切りの届け直し

    @Test("字形を届けた投入が打ち切られると、結末が届いた後の描き切りが届け直す。無ければ届け直さない",
        arguments: [true, false])
    func aGlyphWhoseUploadWasDroppedIsSentAgain(dropped: Bool) throws {
        let gpu = try RenderDevice()
        let canvas = try makeCanvas(gpu: gpu)
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(36)
            canvas.text("Q", 8, 60)
            // 次の投入は、このフレームの終わりの描き切り (字形を届ける)
            if dropped { gpu.dropsNextSubmissionForTesting = DroppedWorkReadersTests.victim }
        }
        let page = canvas.atlas.page
        #expect(page.pendingRegionCount == 0, "届けた記帳が下りていない — 前提が崩れている")
        #expect(page.deliveredRegionCount > 0, "検査の前提: 区画を投入に載せていない")

        _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
        // 描き切りの頭と同じ照会。届け直す前の控えを見る
        gpu.revokeDroppedDeliveries()
        #expect((page.pendingRegionCount > 0) == dropped, "控え: \(page.pendingRegionCount)")
        #expect((page.deliveredRegionCount == 0) || !dropped, "打ち切られた投入の区画が、届けた側に残っている")

        let barriers = canvas.uploadBarriersEncoded
        try canvas.draw {}
        #expect(canvas.uploadBarriersEncoded - barriers == (dropped ? 1 : 0), "届け直した回数が違う")
        #expect(page.pendingRegionCount == 0, "届け直した後も控えが残っている")
    }

    /// 画像と数の並びは、結末を失った投入を届け直さない (正しく済んだ中身を CPU の古い値で潰しうる)。
    /// 字形の区画は CPU の画素が変わらない正本で、同じ画素を書き直すだけなので、字形の頁だけは届け直す
    /// 側に倒す。倒さないと、区画が空のまま頁が替わるまで字が欠け続ける。
    @Test("字形を届けた投入の結末を失ったときも、字形の区画は届け直す。無ければ届け直さない",
        arguments: [true, false])
    func aGlyphWhoseOutcomeWasLostIsSentAgain(lost: Bool) throws {
        let gpu = try RenderDevice()
        gpu.outcomeWaitLimit = .milliseconds(100)
        let canvas = try makeCanvas(gpu: gpu)
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.textSize(36)
            canvas.text("Q", 8, 60)
            if lost { gpu.losesNextOutcomeForTesting = true }
        }
        let page = canvas.atlas.page
        try #require(page.deliveredRegionCount > 0, "検査の前提: 区画を投入に載せていない")

        // 投げる読む口と同じ待ちで、失われた結末を打ち切りとして記させる
        _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
        gpu.revokeDroppedDeliveries()
        #expect((page.pendingRegionCount > 0) == lost, "控え: \(page.pendingRegionCount)")

        try canvas.draw {}
        #expect(page.pendingRegionCount == 0, "届け直した後も控えが残っている")
    }

    // MARK: - 控えに載せられない大きさ (逃げ道)

    @Test("控えの上限を越える頁でも、逃げ道で届いて字が出る")
    func anOversizedPageIsWrittenDirectly() throws {
        let canvas = try makeCanvas()
        canvas.uploadByteLimit = 16
        let image = try {
            try canvas.draw {
                canvas.background(black)
                canvas.fill(white)
                canvas.textSize(40)
                canvas.text("Ag", 8, 70)
            }
            return try canvas.target.encodeForDisplay()
        }()
        #expect(canvas.atlas.page.directWrites > 0, "逃げ道で書いていない")
        #expect(inkedPixelCount(image) > 0, "逃げ道で書いた字が出ていない")
        #expect(canvas.atlas.page.pendingRegionCount == 0)
    }
}
