// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import Testing

@testable import MokumeCore

/// 道具が出す 2 種類の窓。
///
/// **作品の窓に道具の都合が出ないことを、構造で見る。** 「載せないように気をつける」では
/// 検められないので、載せる場所そのものが無いことを見る
/// ([ADR-0032](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md) 決定 1)。
@Suite(
    "道具が出す窓",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct SharedFrameStageTests {
    /// 区画を 1 つ作って渡す。後片付けまで面倒を見る。
    private func withFacet<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-viewport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    private func look(_ name: String) -> SharedFrameStage.Look {
        SharedFrameStage.Look(
            title: name, autosaveName: "mokume.test.\(name)",
            defaultSize: NSSize(width: 320, height: 180))
    }

    @Test("重ねる面を渡さなければ、絵の面には何も足されない")
    func artworkWindowCarriesNothing() throws {
        try withFacet { facet in
            let stage = try SharedFrameStage(gpu: RenderDevice(), facet: facet, look: look("bare"))
            stage.open()
            defer { stage.close() }
            let content = try #require(stage.window?.contentView)
            #expect(content.subviews.isEmpty)
        }
    }

    @Test("重ねる面を渡すと、絵の面の上に足される")
    func previewCarriesTheNotice() throws {
        try withFacet { facet in
            let stage = try SharedFrameStage(
                gpu: RenderDevice(), facet: facet, look: look("notice"))
            let notice = NoticeOverlay()
            stage.open(overlay: notice)
            defer { stage.close() }
            let content = try #require(stage.window?.contentView)
            #expect(content.subviews.contains { $0 === notice })
        }
    }

    /// **プレビューは作品の窓の子ではない。** 作品が窓を持たない日 (外へ流すだけの作品) に
    /// プレビューだけを出せる形かどうかは、片方だけを開いて確かめられる。
    @Test("プレビューは、作品の窓を作らなくても開いて畳める")
    func previewStandsAlone() throws {
        try withFacet { facet in
            let preview = try SharedFramePreview(
                gpu: RenderDevice(), facet: facet, title: "単体")
            preview.open()
            preview.report("作っている…", spinning: true)
            preview.close()
        }
    }

    /// **覚えている枠が無いときに、寸分違わず重ならない。**
    ///
    /// どちらも同じ大きさで中央へ出るので、ずらさないと 2 枚が完全に重なり、窓が 1 つしか
    /// 無いように見える (実測)。**その場限りの覚え名で開く** — 覚えた枠が残っている機械では
    /// 中央へ出ないので、それでは初めての 1 回を見たことにならない。
    @Test("初めて開くとき、2 枚は重ならない")
    func freshWindowsDoNotOverlap() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let artwork = try SharedFrameStage(gpu: gpu, facet: facet, look: look(fresh()))
            var previewLook = look(fresh())
            previewLook.nudge = SharedFramePreview.nudge
            let preview = try SharedFrameStage(gpu: gpu, facet: facet, look: previewLook)
            artwork.open()
            preview.open()
            defer {
                artwork.close()
                preview.close()
            }
            #expect(try #require(artwork.window?.frame) != #require(preview.window?.frame))
        }
    }

    /// 覚えた枠を引き継がないための、その場限りの名前。
    private func fresh() -> String { "fresh-\(UUID().uuidString)" }

    /// **拾った 1 件は、合流点と運び先の両方へ行く。**
    ///
    /// 道具の窓では絵を描いているのが別のプロセスなので、運ばないと何も起きない
    /// ([ADR-0032] 決定 4)。運ぶだけにすると、こんどは窓の側の合流点が空になる。
    @Test("窓が拾った出来事は、合流点へも運び先へも行く")
    func deliveredEventsGoBothWays() throws {
        let gpu = try RenderDevice()
        let state = InputState()
        let surface = SketchSurface(
            frame: NSRect(x: 0, y: 0, width: 10, height: 10), device: gpu.device, input: state,
            canvasSize: (10, 10))
        var lines: [String] = []
        surface.relay = { lines.append($0) }
        surface.deliver(.mouseMoved(x: 3, y: 4))
        state.beginFrame()
        #expect(state.x == 3)
        #expect(lines == [InputEvent.mouseMoved(x: 3, y: 4).wireLine])
    }

    /// **つまみはプレビューにだけ出る** ([ADR-0032] 決定 5)。見張りから本番を回している
    /// 間、つまみが本番の画面に出てはならない。
    @Test("宣言があればプレビューにつまみが出て、作品の窓には出ない")
    func knobsGoToThePreviewOnly() throws {
        try withFacet { facet in
            let params = facet.appendingPathComponent("params", isDirectory: true)
            try FileManager.default.createDirectory(at: params, withIntermediateDirectories: true)
            let report = ParamReport(
                revision: 1, id: nil,
                params: [ParamDeclaration(name: "size", value: .float(12))],
                rejected: [], clamped: [], discarded: [])
            try AtomicFile.write(
                try JSONEncoder().encode(report),
                to: params.appendingPathComponent(ParamSurface.reportFileName))

            let gpu = try RenderDevice()
            let preview = try SharedFramePreview(
                gpu: gpu, facet: facet, params: params, title: "つまみ")
            let artwork = try SharedFrameStage(gpu: gpu, facet: facet, look: look("bare-knobs"))
            preview.open()
            artwork.open()
            defer {
                preview.close()
                artwork.close()
            }
            #expect(preview.knobCount == 1)
            #expect(try #require(artwork.window?.contentView).subviews.isEmpty)
        }
    }

    /// つまみが宣言から出るのは変わらない (ADR-0030 決定 8)。**速さは宣言ではない**ので、
    /// 宣言が 1 つも無くても読み出しの面は出る — ここは道具の窓である (ADR-0032 決定 1)。
    @Test("宣言が 1 つも無ければ、つまみは足さない (速さの面は出る)")
    func addsNoKnobsWithoutDeclarations() throws {
        try withFacet { facet in
            let params = facet.appendingPathComponent("params", isDirectory: true)
            try FileManager.default.createDirectory(at: params, withIntermediateDirectories: true)
            let preview = try SharedFramePreview(
                gpu: try RenderDevice(), facet: facet, params: params, title: "空")
            preview.open()
            defer { preview.close() }
            #expect(preview.knobCount == 0)
            #expect(preview.hasPanel)
        }
    }

    /// **絵が 1 枚も来ていないうちは、速さを名乗らない** (#718)。0 を出すと「とても重い」と
    /// 誤読され、前の子の数字を出すと死んだ相手を名乗り続ける。
    @Test("絵が来ていないうちは、速さを名乗らない")
    func noNumbersBeforeAnyFrame() throws {
        try withFacet { facet in
            let stage = try SharedFrameStage(
                gpu: try RenderDevice(), facet: facet, look: look("no-numbers"))
            stage.open(overlay: nil)
            defer { stage.close() }
            #expect(stage.numbers == nil)
        }
    }

    /// 2 枚が同じ名前で位置を覚えると、互いを上書きして重なって開く。
    @Test("作品の窓とプレビューは、別の名前で位置を覚える")
    func placementNamesDiffer() {
        #expect(WindowPlacement.autosaveName != WindowPlacement.previewAutosaveName)
    }

    /// **畳み忘れが、黙って残り続ける形にしない** (#738)。
    ///
    /// 表示のリフレッシュに紐づけた仕掛けは相手を強く持つので、台が自分でそれを持つと
    /// 環になる。環になっている間、台は手放しても解放されず、しかもリフレッシュのたびに
    /// 区画を読み直し続ける — 症状は「メモリが減らない」だけで、原因からは遠い。
    @Test("close() を呼ばずに手放しても、台は解放される")
    func droppingTheStageReleasesIt() throws {
        weak var dropped: SharedFrameStage?
        try withFacet { facet in
            let stage = try SharedFrameStage(
                gpu: RenderDevice(), facet: facet, look: look("dropped"))
            stage.open()
            stage.window?.orderOut(nil)
            dropped = stage
        }
        #expect(
            dropped == nil,
            """
            close() を呼ばずに手放した台が、まだ生きている。

            表示のリフレッシュの仕掛けが台を強く持っていると、手放しても解放されず、
            リフレッシュのたびに走り続ける ([#738](https://github.com/mokume-metal/mokume/issues/738))。
            """)
    }

    // MARK: - 閉じようとしたとき

    /// 窓に据えられた受け口へ、「閉じてよいか」を訊く。
    ///
    /// **台を直に呼ばない。** 窓が持っているのは中継なので (#738 と同じ形)、そこまで
    /// 含めて訊かないと配線が外れたことに気付けない。
    private func asksToClose(_ stage: SharedFrameStage) throws -> Bool {
        let window = try #require(stage.window)
        let delegate = try #require(window.delegate)
        return try #require(delegate.windowShouldClose?(window))
    }

    /// 検査で使う問い。**中身は問わない** — ここで見ているのは言葉ではなく経路である。
    private var question: SharedFrameStage.CloseQuestion {
        .init(message: "終えますか？", detail: "止まります。", confirm: "終える", cancel: "続ける")
    }

    /// **問いを持たない窓の × は、いままでどおり通る。** 窓を持つ側が終わり方を決めて
    /// いないのに、閉じられない窓を作る理由が無い。
    @Test("問いを繋がなければ、× はそのまま閉じる")
    func closesWithoutAQuestion() throws {
        try withFacet { facet in
            let stage = try SharedFrameStage(
                gpu: RenderDevice(), facet: facet, look: look("plain-close"))
            stage.open()
            defer { stage.close() }
            #expect(!stage.asksBeforeClosing)
            #expect(try asksToClose(stage), "問いを持たない窓が閉じられない")
        }
    }

    /// **× を押した瞬間には閉じない** ([#826](https://github.com/mokume-metal/mokume/issues/826))。
    ///
    /// 閉じてしまうと絵の出口が消え、開き直す経路が無い — 見張りは子を止め、区画を
    /// 片付けてから畳む必要がある。
    @Test("問いを繋ぐと、× ではまだ閉じず、問いが出る")
    func asksInsteadOfClosing() throws {
        try withFacet { facet in
            let stage = try SharedFrameStage(
                gpu: RenderDevice(), facet: facet, look: look("asking"))
            var asked: SharedFrameStage.CloseQuestion?
            stage.presentQuestion = { question, _, _ in asked = question }
            stage.askBeforeClosing(question) {}
            stage.open()
            defer { stage.close() }
            #expect(try !asksToClose(stage), "問いを出す前に閉じている")
            #expect(asked?.confirm == question.confirm)
        }
    }

    /// **確定するまで、誰にも知らせない。** 取り消したのに知らせると、続けるつもりで
    /// 押した人の作品が止まる。
    @Test("閉じてよいと確定したときだけ、知らせる")
    func tellsOnlyWhenConfirmed() throws {
        for confirmed in [true, false] {
            try withFacet { facet in
                let stage = try SharedFrameStage(
                    gpu: RenderDevice(), facet: facet, look: look("answer-\(confirmed)"))
                var told = 0
                stage.presentQuestion = { _, _, answer in answer(confirmed) }
                stage.askBeforeClosing(question) { told += 1 }
                stage.open()
                defer { stage.close() }
                #expect(try !asksToClose(stage))
                #expect(told == (confirmed ? 1 : 0))
            }
        }
    }

    /// **後始末は問いを通らない。** 通ると、終わろうとしている最中にもう一度
    /// 「終えますか？」と訊くことになる。
    @Test("畳むときは、問いが出ない")
    func closingDoesNotAsk() throws {
        try withFacet { facet in
            let stage = try SharedFrameStage(
                gpu: RenderDevice(), facet: facet, look: look("teardown"))
            var asked = 0
            stage.presentQuestion = { _, _, _ in asked += 1 }
            stage.askBeforeClosing(question) {}
            stage.open()
            stage.close()
            #expect(asked == 0)
        }
    }

    /// **プレビューも同じ経路を通る** (ADR-0032 決定 7)。プレビューだけが消える形は、
    /// 決定 7 が作らないと決めた「既定を外す口」そのものである。
    @Test("プレビューにも、閉じる前の問いが繋がる")
    func previewAsksBeforeClosingToo() throws {
        try withFacet { facet in
            let preview = try SharedFramePreview(gpu: RenderDevice(), facet: facet, title: "問い")
            #expect(!preview.asksBeforeClosing)
            preview.askBeforeClosing(
                message: question.message, detail: question.detail, confirm: question.confirm,
                cancel: question.cancel
            ) {}
            #expect(preview.asksBeforeClosing)
        }
    }
}
