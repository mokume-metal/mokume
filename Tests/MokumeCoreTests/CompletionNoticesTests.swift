// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 完了の知らせを合体する器 ([#1594](https://github.com/mokume-metal/mokume/issues/1594))。
/// GPU は要らない — 届く順と走る順を手で並べて、積む数と刈る番号だけを見る。
///
/// 実物の投入で溜まらないことと、最後の投入まで刈られることは `FrameGrowthTests` と
/// `FrameSyncTests` が見る。ここは、合図が知らせより遅れる並び (実物では起こせる保証が
/// 無い) で、**控えるのが届いた最大の番号であること**を決定的に押さえる。
@Suite("完了の知らせの合体")
struct CompletionNoticesTests {
    @Test("走っていない知らせがある間は、新しく積まない")
    func onlyOneNoticeIsQueuedAtATime() {
        let notices = CompletionNotices()
        #expect(notices.arrive(1))
        #expect(!notices.arrive(2))
        #expect(!notices.arrive(3))
        #expect(notices.queued == 1)
        #expect(notices.arrived == 3)
    }

    /// 先に積んだ知らせの番号 (1) で刈ると、合図が遅れたときに 2・3 の投入を刈り残す。
    @Test("積んだ知らせは、走る時点で届いている最大の番号を読む")
    func theQueuedNoticeReadsTheNewestSubmission() {
        let notices = CompletionNotices()
        _ = notices.arrive(1)
        _ = notices.arrive(3)
        _ = notices.arrive(2)
        #expect(notices.take() == 3)
        #expect(notices.queued == 0)
    }

    @Test("走った後に届いた知らせは、改めて 1 本積む")
    func aNoticeAfterTheRunQueuesAgain() {
        let notices = CompletionNotices()
        _ = notices.arrive(1)
        _ = notices.take()
        #expect(notices.arrive(2))
        #expect(notices.take() == 2)
    }
}
