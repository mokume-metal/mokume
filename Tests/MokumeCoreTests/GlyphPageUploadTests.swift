// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 頁の控え (まだ届けていない区画) を、届け終えた分だけ手放す口 (``GlyphPage/markUploaded(through:by:)``・#3255)。
/// 頁を作るので GPU の取り扱いを要するが、描かない。
@Suite(
    "頁の控えは、届けた分だけを 1 回の走査で外す",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct GlyphPageUploadTests {
    /// 区画を `count` 個積んだ頁 (世代は 1 から)。控えの上限は越えない。
    private func stagedPage(_ count: Int) throws -> GlyphPage {
        let page = try GlyphPage(side: 64, gpu: RenderDevice())
        for _ in 0..<count {
            page.stage(
                x: 0, y: 0, width: 2, height: 2,
                pixels: [SIMD4<Float16>](repeating: .zero, count: 4))
        }
        return page
    }

    @Test("途中の世代まで届けたら、それ以後の区画だけが控えに残る")
    func keepsWhatIsNewerThanTheGeneration() throws {
        let page = try stagedPage(5)
        #expect(page.markUploaded(through: 3, by: 7))
        #expect(page.pendingRegionCount == 2)
        #expect(page.pendingGenerations == [4, 5], "届けていない新しい区画が残る")
        #expect(page.deliveredRegionCount == 3)
    }

    @Test("全部届けたら控えは空になり、続けて積める")
    func emptiesWhenEverythingIsDelivered() throws {
        let page = try stagedPage(4)
        #expect(page.markUploaded(through: 4, by: 1))
        #expect(page.pendingRegionCount == 0)
        #expect(page.deliveredRegionCount == 4)
        page.stage(x: 0, y: 0, width: 2, height: 2, pixels: [SIMD4<Float16>](repeating: .zero, count: 4))
        #expect(page.pendingRegionCount == 1)
    }

    @Test("届く区画が無ければ何も動かさず false")
    func nothingToDeliver() throws {
        let page = try stagedPage(3)
        #expect(!page.markUploaded(through: 0, by: 1))
        #expect(page.pendingRegionCount == 3)
        #expect(page.deliveredRegionCount == 0)
        let empty = try stagedPage(0)
        #expect(!empty.markUploaded(through: 9, by: 1))
    }

    @Test("直接書いた分は控えから外れるが、投入に載らず、届けた側に残らない")
    func directWritesAreNotTrackedAsDelivered() throws {
        let page = try stagedPage(4)
        #expect(!page.markUploaded(through: 2, by: nil))
        #expect(page.pendingRegionCount == 2)
        #expect(page.deliveredRegionCount == 0)
    }

    @Test("打ち切られた投入の区画は、控えへ積んだ順に戻る")
    func droppedSubmissionsReturnTheirRegions() throws {
        let page = try stagedPage(5)
        #expect(page.markUploaded(through: 2, by: 7))
        #expect(page.markUploaded(through: 4, by: 8))
        #expect(page.pendingRegionCount == 1)
        page.submissionSettled(7, dropped: true)
        #expect(page.pendingRegionCount == 3)
        #expect(page.pendingGenerations == [1, 2, 5])
        #expect(page.deliveredRegionCount == 2)
        page.submissionSettled(8, dropped: false)
        #expect(page.deliveredRegionCount == 0)
        #expect(page.pendingRegionCount == 3)
        #expect(page.pendingGenerations == [1, 2, 5])
    }

    @Test("世代が混ざって積まれていても(届け直しの後)、届けた世代だけを外し、残りの順を保つ")
    func mixedGenerationsKeepTheirOrder() throws {
        let page = try stagedPage(6)
        #expect(page.markUploaded(through: 2, by: 1))
        page.submissionSettled(1, dropped: true)  // 控え: 1 2 3 4 5 6
        page.stage(x: 0, y: 0, width: 2, height: 2, pixels: [SIMD4<Float16>](repeating: .zero, count: 4))
        #expect(page.pendingGenerations == [1, 2, 3, 4, 5, 6, 7])
        #expect(page.markUploaded(through: 4, by: 2))
        #expect(page.pendingGenerations == [5, 6, 7])
    }
}
