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
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

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
