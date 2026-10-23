// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing

@testable import MokumeCamera

/// 実機のカメラの層 (``CameraSource``) で、止めた後に外す前の絵が入れ物へ届かないこと (#3122)。GPU も機材も要らない。
@Suite("実機のカメラの止め方")
struct CameraSourceStopTests {
    @Test("止める手は、絵の列に積まれていた届きかけの 1 枚が済むまで戻らない")
    func stopWaitsForTheFrameInFlight() {
        let source = CameraSource(device: nil, width: 4, height: 4)
        let delivered = Mutex(false)
        // 絵の列で、変換して入れ物へ入れる最中の 1 枚の代わり
        source.frames.async {
            Thread.sleep(forTimeInterval: 0.2)
            delivered.withLock { $0 = true }
        }
        source.stop()
        #expect(delivered.withLock { $0 }, "止める手が戻った後に、絵が入れ物へ届きうる")
    }
}
