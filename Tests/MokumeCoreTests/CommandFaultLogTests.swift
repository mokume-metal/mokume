// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// GPU が打ち切った仕事の記録 ([#1065](https://github.com/mokume-metal/mokume/issues/1065))。
/// GPU は要らない — 数えるところと、拾う経路が繋がっているかだけを見る。
///
/// **打ち切りを故意に起こす検査は置かない。** 起こすには 1 本のコマンドを数百 ms 走らせる
/// ことになり、同じ GPU で並行する検査を巻き添えにしうる。しかも閾値は機械の込み具合で
/// 動くので、起こせる保証も無い (空いた機械では 1750ms の仕事も完走した)。実物で拾える
/// ことは #1065 の実装 PR に実測ログで残してある。
@Suite("GPU が打ち切った仕事の記録")
struct CommandFaultLogTests {
    /// **毎回言わない。** 打ち切りは連鎖するので、そのまま流すと読むべき 1 行が埋まる。
    @Test("言うのは始まりの 1 回だけ")
    func onlyTheFirstFaultSpeaks() {
        let log = CommandFaultLog()
        #expect(log.note("hang"))
        #expect(!log.note("hang"))
        #expect(!log.note("別の理由"))
    }

    /// **黙っていても数える。** 何回打ち切られたかは、ここにしか残らない。
    @Test("黙っている間も回数は増え、最後の理由が残る")
    func silenceStillCounts() {
        let log = CommandFaultLog()
        _ = log.note("1 回目")
        _ = log.note("2 回目")
        _ = log.note("3 回目")
        #expect(log.count == 3)
        #expect(log.last == "3 回目")
    }

    @Test("何も起きていなければ、数も理由も空")
    func aQuietDeviceHasNothingToTell() {
        let log = CommandFaultLog()
        #expect(log.count == 0)
        #expect(log.last == nil)
    }

    /// **理由は入れ子の真ん中にある。** 組み立てているのは実測した打ち切りそのままの 3 段で、
    /// 一番外は束、一番奥は番号だけを持つ。どちらを読んでも「操作を完了できませんでした」に
    /// なり、原因が 1 つも残らない。
    @Test("束の外でも一番奥でもなく、自分で名乗っている層の理由を取る")
    func reasonTakesTheStatedCause() {
        let hang = "Caused GPU Hang Error (00000003:kIOGPUCommandBufferCallbackErrorHang)"
        // 一番奥。番号しか持たない
        let ioSurface = NSError(domain: "IOGPUCommandQueueErrorDomain", code: 3)
        // 真ん中。ここだけが理由を名乗る
        let stated = NSError(
            domain: "MTL4CommandQueueErrorDomain", code: 1,
            userInfo: [NSLocalizedDescriptionKey: hang, NSUnderlyingErrorKey: ioSurface])
        // 一番外。投入は複数のコマンドをまとめて受け付けるので、外側は入れ物として作られる
        let bundle = NSError(
            domain: "MTL4CommandQueueErrorDomain", code: 1,
            userInfo: [NSUnderlyingErrorKey: stated])

        #expect(CommandFaultLog.reason(of: bundle) == hang)
        #expect(
            !bundle.localizedDescription.contains("Hang"),
            "外側が理由を持ってしまっている — この検査が何も見ていない")
        #expect(
            !ioSurface.localizedDescription.contains("Hang"),
            "一番奥が理由を持ってしまっている — この検査が何も見ていない")
    }

    @Test("誰も理由を名乗っていない失敗でも、名乗れる形で返す")
    func anErrorWithoutAnyStatedCauseStillReadsBack() {
        let bare = NSError(domain: "MTL4CommandQueueErrorDomain", code: 1)
        #expect(!CommandFaultLog.reason(of: bare).isEmpty)
    }

    // MARK: - 拾う経路が繋がっているか

    /// **数えるところが正しくても、届いていなければ 0 のままである。**
    ///
    /// 結末を受け取るには投入に `MTL4CommitOptions` を渡してハンドラを登録するしかなく、
    /// 渡し忘れた状態がまさに #1065 の姿である — 打ち切られても `commandFaultCount` は 0 で、
    /// 空の絵が「正しい絵」として読める。届いていることを外から見る手が無いので、原文で
    /// 留める (`GPUMemoryAccessGateTests` が待ちの規律を原文で裏取りしているのと同じ作法)。
    @Test("投入の経路が、実行の結末を受け取るよう頼んでいる")
    func submissionAsksForItsOutcome() throws {
        // **真偽にしてから見る。** 原文をそのまま `#expect` へ渡すと、落ちたときに
        // ファイル 1 本ぶんが失敗の記録に展開されて、何が足りないのか読めなくなる
        let source = try String(contentsOf: renderDeviceSource, encoding: .utf8)
            .filter { !$0.isWhitespace }
        let registersHandler = source.contains("addFeedbackHandler")
        let passesOptions = source.contains("queue.commit([commands],options:")

        #expect(registersHandler, "RenderDevice が実行の結末を受け取るハンドラを登録していない")
        #expect(
            passesOptions,
            """
            投入がお願い (MTL4CommitOptions) を渡していない。
            渡さなければ Metal は結末を捨てるので、打ち切られた仕事も「終わった」としか見えない
            """)
    }

    private var renderDeviceSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MokumeCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリ
            .appending(path: "Sources/MokumeCore/Rendering/RenderDevice.swift")
    }
}
