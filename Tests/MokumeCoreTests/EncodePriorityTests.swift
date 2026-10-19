// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import MokumeCore

/// 書き出しの仕事の優先度 ([#2372](https://github.com/mokume-metal/mokume/issues/2372))。
///
/// main actor は積み残しが上限に達すると semaphore で待つ (``Backpressure``)。semaphore は優先度を
/// 寄付しないので、仕事が `.utility` だと、CPU が混んだ機械で符号化だけが後回しにされ、main がその
/// 遅れを待つ。待つ側に揃えた優先度で走ることを、仕事の中から見る。
@Suite("書き出しの仕事の優先度")
struct EncodePriorityTests {
    @Test("連番の書き込みは、待つ側 (main) より低い優先度では走らない")
    func frameWritesDoNotRunBelowTheWaitingSide() {
        let lanes = WriteLanes()
        let seen = Mutex<TaskPriority?>(nil)
        let done = DispatchSemaphore(value: 0)
        lanes.enqueue(
            "priority-probe",
            drop: { done.signal() },
            {
                seen.withLock { $0 = Task.currentPriority }
                done.signal()
            })
        // **待つ側が期限を持つ** — 仕事が走らなくても検査が止まらない
        let finished = done.wait(timeout: .now() + 10) == .success
        #expect(finished)
        let priority = seen.withLock { $0 }
        #expect(priority != nil)
        if let priority {
            #expect(priority >= .userInitiated, "優先度 \(priority) で走った")
        }
    }
}
