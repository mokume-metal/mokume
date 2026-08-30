// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 走っている速さの名乗り (#510)。GPU は要らない — 行を組むところは純関数にしてある。
@Suite("速さの名乗り")
struct FrameRateNoticeTests {
    /// **与えられなければ何も出さない。** 窓口から立てたスケッチの出力が 1 バイトも
    /// 変わらないことは、この既定で保たれる。
    @Test("名乗りが与えられなければ、名乗らない")
    func nothingIsSaidWithoutTheKey() {
        #expect(FrameRateNotice.configuration(environment: [:]) == nil)
        #expect(
            FrameRateNotice.configuration(
                environment: [StartupReads.frameRateNotice.key: "   "]) == nil)
        #expect(
            FrameRateNotice.configuration(
                environment: [StartupReads.frameRateNotice.key: " release "]) == "release")
    }

    /// **数字だけを見せない。** 速さは構成で数倍変わるので、同じ行に無いと重い / 軽いの
    /// 判断が構成の違いに引きずられる。
    @Test("速さの行には、構成が必ず入る")
    func theLineAlwaysCarriesTheConfiguration() {
        let line = FrameRateNotice.line(rate: 58.74, configuration: "debug")
        #expect(line.contains("58.7"))
        #expect(line.contains("debug"))
    }

    /// **欠測を 0 と書かない。** 0 は「測ったら 0 だった」と読めるが、実際は測れていない。
    @Test("進んでいないときは、0 と書かない")
    func aStoppedSketchIsNotWrittenAsZero() {
        let line = FrameRateNotice.line(rate: nil, configuration: "debug")
        #expect(!line.contains("0"))
        #expect(line.contains("測れない"))
        #expect(line.contains("debug"), "欠測でも構成は要る — 何の土俵の話かは変わらない")
    }
}
