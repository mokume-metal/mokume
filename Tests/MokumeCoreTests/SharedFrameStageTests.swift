// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import MokumeTestSupport
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
        let directory = try TestScratch.directory("mokume-viewport")
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    /// 台へ渡す見た目。
    ///
    /// **大きさは本番の定数から取る。** 検査が自前の数字を持つと、本番の 2 つの既定が
    /// 割れても緑のままになる — それが [#964] の状態だった (両方に 320x180 を渡していた)。
    ///
    /// [#964]: https://github.com/mokume-metal/mokume/issues/964
    private func look(
        _ name: String, size: NSSize = SharedFrameWindow.defaultSize, selects: Bool = false
    ) -> SharedFrameStage.Look {
        SharedFrameStage.Look(
            title: name, autosaveName: "mokume.test.\(name)", defaultSize: size,
            showsSelectionDialogs: selects)
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
            let title = "単体-\(UUID().uuidString)"
            func previewWindow() -> NSWindow? { NSApplication.shared.windows.first { $0.title == title } }
            #expect(previewWindow() == nil, "開く前に窓がある")

            let preview = try SharedFramePreview(gpu: RenderDevice(), facet: facet, title: title)
            preview.open()
            // 作品の窓 (`SharedFrameStage`) を作っていないのに、プレビューの窓だけが出ている
            let window = try #require(previewWindow(), "開いたのに窓が出ていない")
            #expect(window.isVisible)

            // 重ねる 1 行は、その窓の上に出る
            preview.report("作っている…", spinning: true)
            let notice = try #require(
                window.contentView?.subviews.compactMap { $0 as? NoticeOverlay }.first,
                "重ねる面が窓の上に無い")
            #expect(notice.line == "作っている…")
            #expect(notice.isSpinning)

            preview.close()
            #expect(!window.isVisible, "畳んだのに窓が残っている")
        }
    }

    /// **覚えている枠が無いときに、プレビューは作品の窓の真下に並ぶ。**
    ///
    /// どちらも同じ大きさで中央へ出るので、ずらさないと 2 枚が完全に重なり、窓が 1 つしか
    /// 無いように見える (実測)。**その場限りの覚え名で開く** — 覚えた枠が残っている機械では
    /// 中央へ出ないので、それでは初めての 1 回を見たことにならない。
    ///
    /// **見るのは「枠が違う」ではなく「真下に並ぶ」である** ([#964])。`nudge` は
    /// `SharedFramePreview.defaultSize` の丈から出る前計算なので、作品の窓の既定だけが
    /// 大きくなると足りなくなり、2 枚は重なる — そのとき枠は違うので、`!=` では通って
    /// しまう。**大きさは本番の定数から取る** (`look()` の doc)。
    ///
    /// [#964]: https://github.com/mokume-metal/mokume/issues/964
    @Test("初めて開くとき、プレビューは作品の窓の真下に並ぶ")
    func freshWindowsDoNotOverlap() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let artwork = try SharedFrameStage(gpu: gpu, facet: facet, look: look(fresh()))
            var previewLook = look(fresh(), size: SharedFramePreview.defaultSize)
            previewLook.nudge = SharedFramePreview.nudge
            let preview = try SharedFrameStage(gpu: gpu, facet: facet, look: previewLook)
            artwork.open()
            preview.open()
            defer {
                artwork.close()
                preview.close()
            }
            let above = try #require(artwork.window?.frame)
            let below = try #require(preview.window?.frame)
            #expect(
                below.maxY <= above.minY,
                """
                プレビューが作品の窓の真下に並んでいない (\(below.maxY - above.minY)pt 重なっている)。

                作品の窓 \(above) / プレビュー \(below)

                SharedFrameWindow.defaultSize \(SharedFrameWindow.defaultSize) と
                SharedFramePreview.defaultSize \(SharedFramePreview.defaultSize) が
                揃っていることが、ずらし量 \(SharedFramePreview.nudge) の前提である
                ([#964](https://github.com/mokume-metal/mokume/issues/964))。
                """)
        }
    }

    /// **2 つの既定が揃っていることを直に見る** ([#964])。
    ///
    /// 上の「真下に並ぶ」だけでは片方向しか捕まらない — プレビュー側を大きくすると
    /// `nudge` も一緒に伸びるので、重ならない関係は保たれてしまう。だが `defaultSize` の
    /// doc が名乗っている契約は「作品の窓と揃える」であって「重ならない」ではない。
    ///
    /// **既定値は `setFrameUsingName` が false のときだけ効く**ので、覚えた枠を持つ機械
    /// では割れても一度も現れない。目に見える症状があっても、気付く経路が無い
    /// ([ADR-0008](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md)
    /// 決定 6 — 写しのままにして、割れても直せる形を置く)。
    ///
    /// [#964]: https://github.com/mokume-metal/mokume/issues/964
    @Test("作品の窓とプレビューは、同じ既定の大きさで開く")
    func defaultSizesAgree() {
        #expect(
            SharedFrameWindow.defaultSize == SharedFramePreview.defaultSize,
            """
            作品の窓 \(SharedFrameWindow.defaultSize) とプレビュー \
            \(SharedFramePreview.defaultSize) の既定が割れている。

            既定のスケッチ (960x540・windowScale 0.5) の窓は 480x270 で開くので、作品の窓の
            既定はそれと、プレビューの既定はそれと揃えてある。同じ 480x270 は 3 つ目があり
            (SketchApplication の 描く大きさ × windowScale)、
            寄せる先が無いので写しのまま残している — 詳しくは SharedFrameWindow.defaultSize の
            doc と [#964](https://github.com/mokume-metal/mokume/issues/964)。
            """)
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

    /// **キーは、窓へ送っても運び先まで行く。**
    ///
    /// 上の検査は面を直に組んで `deliver` を叩くので、**窓 → 第一応答者 → 面**という区間を
    /// 1 度も通らない。そこはキーだけが無音で落ちるところで、実際 [#963] は「道具が出す窓
    /// では届いていないのではないか」を疑った (実測では届いていた — 落ちていないことを
    /// 覆うものが無かった)。
    ///
    /// だから**台に窓を出させ、本物の `NSEvent` をその窓へ送る**。面が第一応答者に据わって
    /// いなければ `keyDown` は 1 度も呼ばれず、運び先は空のままになる。
    ///
    /// [#963]: https://github.com/mokume-metal/mokume/issues/963
    @Test("道具の窓へ送ったキーは、運び先へ行く")
    func keysReachTheRelayThroughTheWindow() throws {
        try withFacet { facet in
            let stage = try SharedFrameStage(gpu: RenderDevice(), facet: facet, look: look("keys"))
            var lines: [String] = []
            stage.onInput = { lines.append($0) }
            stage.open()
            defer { stage.close() }
            let window = try #require(stage.window)
            #expect(window.firstResponder === window.contentView)
            let event = try #require(
                KeyEventFixture.keyDown(in: window, characters: "a", keyCode: 0))
            window.sendEvent(event)
            #expect(
                lines == [
                    InputEvent.keyDown(code: Key(rawValue: 0), characters: "a", isRepeat: false)
                        .wireLine
                ])
        }
    }

    /// **道具の窓へ落としたファイルは、運び先 (子の標準入力へ書く 1 行) へ行く。**
    ///
    /// 窓は `SketchSurface` で、落としの受けはそこに 1 か所だけある。道具の窓の面が別の型になれば、
    /// 受けが片方だけ抜けるので、窓から取り出した面に直に落としを渡して運び先まで見る
    /// ([#3061](https://github.com/mokume-metal/mokume/issues/3061))。本物のドラッグの身振りは人の手。
    @Test("道具の窓へ落としたファイルは、運び先へ行く")
    func droppedFilesReachTheRelayThroughTheWindow() throws {
        try withFacet { facet in
            let stage = try SharedFrameStage(gpu: RenderDevice(), facet: facet, look: look("drop"))
            var lines: [String] = []
            stage.onInput = { lines.append($0) }
            stage.open()
            defer { stage.close() }
            let window = try #require(stage.window)
            let surface = try #require(window.contentView as? SketchSurface)
            #expect(surface.registeredDraggedTypes.contains(.fileURL), "ファイルを受けるよう登録されていない")
            let center = NSPoint(
                x: surface.bounds.midX, y: surface.bounds.midY)
            let dragging = FakeDraggingInfo.files(["/tmp/a.png"], at: surface.convert(center, to: nil))
            #expect(surface.draggingEntered(dragging) == .copy)
            #expect(surface.performDragOperation(dragging))
            #expect(lines.count == 1, "\(lines)")
            let raw = try JSONDecoder().decode(
                RawInputEvent.self, from: Data(try #require(lines.first).utf8))
            guard case .fileDropped(let paths, let x, let y)? = raw.event else {
                Issue.record("落としではない: \(lines)")
                return
            }
            #expect(paths == ["/tmp/a.png"])
            // 面の真ん中を落とした。描く大きさ (最初の絵が来るまでの仮の 1x1) の真ん中に写る
            #expect(abs(x - 0.5) < 0.01 && abs(y - 0.5) < 0.01, "(\(x), \(y))")
        }
    }

    /// **ファイルを選ばせる頼みは、作品の窓が 1 度だけ出し、結果は子への 1 行になる** ([#3062])。
    /// 頼みは子が絵と一緒に面の属性へ載せる。同じ頼み (子の番号と通し番号) の次の枚では出し直さず、
    /// 別の頼みに変わったら前のダイアログは結果ごと捨てて閉じる。プレビューは出さない (パネルが 2 枚出る)。
    ///
    /// [#3062]: https://github.com/mokume-metal/mokume/issues/3062
    @Test("作品の窓は面に載った選ばせる頼みを 1 度だけ出し、結果を子への 1 行にする。別の頼みで前のを閉じる")
    func theArtworkWindowShowsASelectionOnce() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let child = try publish(in: facet, gpu: gpu, pid: 100, frames: 1, pointerLock: false)
            let stage = try SharedFrameStage(
                gpu: gpu, facet: facet, look: look("selects", selects: true))
            defer { stage.close() }
            let picker = FakeFilePicker()
            stage.filePicker = picker
            var lines: [String] = []
            stage.onInput = { lines.append($0) }
            stage.open()
            stage.displayLinkFired()
            #expect(picker.shown.isEmpty, "頼みが無いのに出した")

            let first = SelectionBroker.Request(serial: 1, prompt: "pick")
            try draw(child, frame: 2, gpu: gpu, selection: first)
            stage.displayLinkFired()
            #expect(picker.shown.map(\.prompt) == ["pick"])

            // 同じ頼みが次の枚にも載っていても、出し直さない
            try draw(child, frame: 3, gpu: gpu, selection: first)
            stage.displayLinkFired()
            stage.displayLinkFired()
            #expect(picker.shown.count == 1, "同じ頼みを出し直した")

            picker.answer(0, "/tmp/a.csv")
            #expect(
                lines == [InputEvent.fileSelected(path: "/tmp/a.csv", serial: 1).wireLine], "\(lines)")

            // 結果が届いて頼みが消え、次の頼み (2) が来る
            try draw(child, frame: 4, gpu: gpu)
            stage.displayLinkFired()
            try draw(child, frame: 5, gpu: gpu, selection: SelectionBroker.Request(serial: 2, prompt: "again"))
            stage.displayLinkFired()
            #expect(picker.shown.map(\.prompt) == ["pick", "again"])

            // 開いている間に別の頼み (3) に変わったら、前のダイアログは結果ごと捨てて閉じる
            try draw(child, frame: 6, gpu: gpu, selection: SelectionBroker.Request(serial: 3, prompt: "third"))
            stage.displayLinkFired()
            // 閉じるように言われたのは、答え済みの 1 枚目 (頼みが消えたとき・害は無い) と、開いていた 2 枚目
            #expect(picker.dismissals == 2 && picker.shown.count == 3)
            lines.removeAll()
            picker.answer(1, "/tmp/stale.csv")
            #expect(lines.isEmpty, "閉じたダイアログの結果が子へ渡った")
            picker.answer(2, nil)
            #expect(
                lines == [InputEvent.fileSelected(path: nil, serial: 3).wireLine],
                "取り消しは空の配列の 1 行で、頼みの番号を載せる")
        }
    }

    /// **結果の 1 行は落ちうる** ([#3062]): 管が一杯・書き残しの間・子の溢れ。頼みが面に残っている間は、間合いを置いて
    /// 送り直す。頼みが消えたら止める。
    ///
    /// [#3062]: https://github.com/mokume-metal/mokume/issues/3062
    @Test("答えた結果は、頼みが面に残る間だけ間合いを置いて送り直す。頼みが消えたら止める")
    func theAnswerIsResentWhileTheRequestStaysPosted() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let child = try publish(in: facet, gpu: gpu, pid: 100, frames: 1, pointerLock: false)
            let stage = try SharedFrameStage(
                gpu: gpu, facet: facet, look: look("resend", selects: true))
            defer { stage.close() }
            let picker = FakeFilePicker()
            stage.filePicker = picker
            var clock = 100.0
            stage.now = { clock }
            var lines: [String] = []
            stage.onInput = { lines.append($0) }
            stage.open()
            stage.displayLinkFired()
            let request = SelectionBroker.Request(serial: 1, prompt: "pick")
            try draw(child, frame: 2, gpu: gpu, selection: request)
            stage.displayLinkFired()
            picker.answer(0, "/tmp/a.csv")
            let line = InputEvent.fileSelected(path: "/tmp/a.csv", serial: 1).wireLine
            #expect(lines == [line])

            // 間合いの前は送り直さない。頼みが残っていても毎フレームは送らない
            try draw(child, frame: 3, gpu: gpu, selection: request)
            clock += SharedFrameStage.selectionResendInterval / 2
            for _ in 0..<3 { stage.displayLinkFired() }
            #expect(lines == [line], "間合いの前に送り直した: \(lines.count) 行")

            // 間合いが過ぎたら、頼みが残っているので送り直す (落ちた 1 行の代わり)
            clock += SharedFrameStage.selectionResendInterval
            stage.displayLinkFired()
            #expect(lines == [line, line], "落ちた結果を送り直さない")
            stage.displayLinkFired()
            #expect(lines.count == 2, "同じ間合いの中でもう 1 度送った")
            #expect(picker.shown.count == 1, "答えた頼みを出し直した")

            // 子が結果を受けて頼みを消したら、もう送らない
            try draw(child, frame: 4, gpu: gpu)
            clock += SharedFrameStage.selectionResendInterval * 4
            for _ in 0..<3 { stage.displayLinkFired() }
            #expect(lines.count == 2, "頼みが消えた後も送り直した")
        }
    }

    @Test("答える前は送り直さない。頼んだ世代が入れ替わったら、送り直さない")
    func nothingIsResentBeforeAnswerOrAfterTheGenerationChanged() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let child = try publish(in: facet, gpu: gpu, pid: 100, frames: 1, pointerLock: false)
            let stage = try SharedFrameStage(
                gpu: gpu, facet: facet, look: look("resend-none", selects: true))
            defer { stage.close() }
            let picker = FakeFilePicker()
            stage.filePicker = picker
            var clock = 0.0
            stage.now = { clock }
            var lines: [String] = []
            stage.onInput = { lines.append($0) }
            stage.open()
            stage.displayLinkFired()
            try draw(
                child, frame: 2, gpu: gpu, selection: SelectionBroker.Request(serial: 1, prompt: "pick"))
            stage.displayLinkFired()
            clock += SharedFrameStage.selectionResendInterval * 10
            stage.displayLinkFired()
            #expect(lines.isEmpty, "答えていないのに送った")

            picker.answer(0, nil)
            #expect(lines.count == 1)
            stage.relinquishSource(pids: [100])
            clock += SharedFrameStage.selectionResendInterval * 10
            for _ in 0..<3 { stage.displayLinkFired() }
            #expect(lines.count == 1, "手放した世代へ送り直した")
        }
    }

    /// **ファイルのシートが付いている間も、× は閉じる問いへ進む** ([#3062])。付いたシートがあると
    /// `windowShouldClose` は黙って false を返し、× が効かない窓になっていた。
    ///
    /// [#3062]: https://github.com/mokume-metal/mokume/issues/3062
    @Test("ファイルを選ぶシートが付いていても、× は問いへ進み、ダイアログは取り消しとして子へ渡る")
    func closingWithTheFileSheetUpAsksTheQuestion() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let child = try publish(in: facet, gpu: gpu, pid: 100, frames: 1, pointerLock: false)
            let stage = try SharedFrameStage(
                gpu: gpu, facet: facet, look: look("close-sheet", selects: true))
            defer { stage.close() }
            let picker = FakeFilePicker()
            stage.filePicker = picker
            var asked = 0
            stage.presentQuestion = { _, _, _ in asked += 1 }
            stage.askBeforeClosing(question) {}
            var lines: [String] = []
            stage.onInput = { lines.append($0) }
            stage.open()
            stage.displayLinkFired()
            try draw(
                child, frame: 2, gpu: gpu, selection: SelectionBroker.Request(serial: 4, prompt: "pick"))
            stage.displayLinkFired()
            try #require(picker.shown.count == 1)
            // 本物のシートが窓に付いた状態にする (ファイルのシートの代わり)
            let window = try #require(stage.window)
            let sheet = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 80, height: 40), styleMask: [.titled],
                backing: .buffered, defer: true)
            window.beginSheet(sheet, completionHandler: nil)
            defer { if let attached = window.attachedSheet { window.endSheet(attached) } }
            try #require(window.attachedSheet != nil)

            #expect(try !asksToClose(stage))
            #expect(asked == 1, "ファイルのシートが付いていると × が効かない")
            #expect(picker.dismissals == 1, "ファイルのダイアログを取り消していない")
            #expect(
                lines == [InputEvent.fileSelected(path: nil, serial: 4).wireLine],
                "取り消しとして子へ渡らない: \(lines)")

            // 問いのシートが出ている間の 2 度目の × は、問いを重ねない
            #expect(try !asksToClose(stage))
            #expect(asked == 1, "問いを二重に出した")
            #expect(lines.count == 1)
        }
    }

    @Test("プレビューは、選ばせる頼みが面に載っていても出さない")
    func thePreviewDoesNotShowASelection() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let child = try publish(in: facet, gpu: gpu, pid: 100, frames: 1, pointerLock: false)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("no-selects"))
            defer { stage.close() }
            let picker = FakeFilePicker()
            stage.filePicker = picker
            stage.open()
            stage.displayLinkFired()
            try draw(child, frame: 2, gpu: gpu, selection: SelectionBroker.Request(serial: 1, prompt: "pick"))
            for _ in 0..<3 { stage.displayLinkFired() }
            #expect(stage.selectionRequested != nil, "検査の前提: 頼みは読めている")
            #expect(picker.shown.isEmpty, "プレビューがダイアログを出した")
        }
    }

    /// **頼んだ世代の子が入れ替わった後に届いた結果は、子へ渡さない。** 新しい子は待っていない。
    @Test("頼んだ世代が入れ替わった後に答えても、結果は子へ渡さない")
    func anAnswerAfterTheGenerationChangedIsNotSent() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let old = try publish(in: facet, gpu: gpu, pid: 100, frames: 1, pointerLock: false)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("gen", selects: true))
            defer { stage.close() }
            let picker = FakeFilePicker()
            stage.filePicker = picker
            var lines: [String] = []
            stage.onInput = { lines.append($0) }
            stage.open()
            stage.displayLinkFired()
            try draw(old, frame: 2, gpu: gpu, selection: SelectionBroker.Request(serial: 1, prompt: "pick"))
            stage.displayLinkFired()
            try #require(picker.shown.count == 1)

            // 見張りが世代を手放す (畳まれた世代の頼みは下ろす)
            stage.relinquishSource(pids: [100])
            stage.displayLinkFired()
            #expect(picker.dismissals == 1, "手放した世代の頼みのダイアログが残っている")
            picker.answer(0, "/tmp/a.csv")
            #expect(lines.isEmpty)
        }
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
                to: params.appendingPathComponent("report.json"))

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

    /// **読む前に「読んだ」と記録しない。** `surface.json` を書くのは走り出しの 1 回だけ
    /// なので、書きかけを掴み損ねると**直る契機が来ない** — 症状は「プレビューが真っ白の
    /// まま何も出ない」だけで、起こし直すまで直らない
    /// ([#1048](https://github.com/mokume-metal/mokume/issues/1048))。
    ///
    /// **mokume の書き手 (`AtomicFile`) は原子的に置くので、書きかけは実際には見えない。** ここは、原子的に
    /// 置かない書き手に備えた性質を、書きかけを作って固定している (``WatchedFile`` の説明)。
    @Test("書きかけの目録を掴んでも、その改訂を読み飛ばさない")
    func rereadsAManifestItCouldNotDecode() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let surface = try SharedFrameSurface(gpu: gpu, width: 32, height: 32, at: facet)
            let url = facet.appendingPathComponent(SharedFrameSurface.manifestName)
            let moment = Date(timeIntervalSince1970: 1_000_000)
            // 置いている途中を掴んだ = 解けない
            try Data(#"{"width":32,"ids":[1"#.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: moment], ofItemAtPath: url.path)

            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("manifest"))
            defer { stage.close() }
            stage.displayLinkFired()
            #expect(!stage.hasSource)

            // 書き手が置き終わった。**更新時刻は動かさない** — 同じ改訂を掴み直せるかを見る
            try surface.publishManifest()
            try FileManager.default.setAttributes(
                [.modificationDate: moment], ofItemAtPath: url.path)
            stage.displayLinkFired()
            #expect(stage.hasSource)
        }
    }

    /// **読めない目録は、黙って捨てず、改訂ごとに台ごと 1 度名乗る** ([#2889])。版が違えば読まない
    /// 目録 (`schemaVersion` が違う) を置かれると、台は古い絵のまま理由を言わずに続いていた。
    /// 差し出し元は変えず、直前の絵を出したまま (ADR-0032 決定 6)。
    ///
    /// [#2889]: https://github.com/mokume-metal/mokume/issues/2889
    @Test("読めない目録は、読み直しても 1 度だけ名乗り、差し出し元は変えない")
    func anUnreadableManifestIsSaidOnce() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let surface = try makeSurface(in: facet, gpu: gpu, drawing: 1)
            let url = facet.appendingPathComponent(SharedFrameSurface.manifestName)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("unreadable"))
            defer { stage.close() }
            var said: [String] = []
            stage.warn = { said.append($0) }
            stage.displayLinkFired()
            #expect(stage.hasSource)
            #expect(said.isEmpty, "読めた目録で名乗っている: \(said)")

            // 版の違う目録に置き換わった (更新時刻は動く)
            try Data(#"{"schemaVersion":99,"ids":[1],"width":10,"height":10}"#.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
            for _ in 0..<3 { stage.displayLinkFired() }
            #expect(stage.hasSource, "差し出し元は変わらず、直前の絵を出したまま")
            let message = try #require(said.first)
            #expect(said.count == 1, "読み直すたびに繰り返している: \(said)")
            #expect(message.contains(url.path), "どのファイルか: \(message)")
            #expect(message.contains("99"), "読めなかった理由: \(message)")
            #expect(message.contains("mokume doctor"), "候補: \(message)")
            #expect(message.contains("by each window"), "台ごとに名乗ることを偽らない: \(message)")
            _ = surface
        }
    }

    /// **乗り換えの合図が来ない 2 つの形は、道具の窓だけが知る** ([#2928])。目録が読めない・目録は読めたが
    /// 番号の面を引けない — どちらも子は知らないので、台が知らせないと前の世代が残る。
    /// 読み直しても繰り返さず、差し出し元は変えない (直前の絵を出したまま)。
    ///
    /// [#2928]: https://github.com/mokume-metal/mokume/issues/2928
    @Test(
        "受け取れない目録・引けない面は、台が 1 度だけ知らせ、差し出し元は変えない",
        arguments: [
            (#"{"schemaVersion":99,"ids":[1],"width":10,"height":10}"#, UndeliverableGeneration.unreadableManifest),
            (#"{"schemaVersion":1,"ids":[4000000000],"width":10,"height":10}"#, UndeliverableGeneration.noSurface),
        ])
    func anUndeliverableGenerationIsAnnouncedOnce(manifest: String, cause: UndeliverableGeneration) throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let surface = try makeSurface(in: facet, gpu: gpu, drawing: 1)
            let url = facet.appendingPathComponent(SharedFrameSurface.manifestName)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("undeliverable"))
            defer { stage.close() }
            stage.warn = { _ in }
            var told: [UndeliverableGeneration] = []
            stage.onGenerationUndeliverable = { cause, _ in told.append(cause) }
            stage.displayLinkFired()
            #expect(stage.hasSource)
            #expect(told.isEmpty, "読めた目録で知らせている: \(told)")

            try Data(manifest.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
            for _ in 0..<3 { stage.displayLinkFired() }
            #expect(told == [cause], "\(told)")
            #expect(stage.hasSource, "差し出し元は変わらず、直前の絵を出したまま")
            _ = surface
        }
    }

    /// 目録がファイルとして読めない (置き場がディレクトリ) 形も、道具の窓だけが知る。版の形とは関係が無いので、
    /// 受け取る側が版の案内を付けないよう、別の種類で知らせる ([#2928])。
    ///
    /// [#2928]: https://github.com/mokume-metal/mokume/issues/2928
    @Test("ファイルとして読めない目録は、版の形と別の種類で知らせる")
    func anUnreadableManifestFileIsAnnouncedApart() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let surface = try makeSurface(in: facet, gpu: gpu, drawing: 1)
            let url = facet.appendingPathComponent(SharedFrameSurface.manifestName)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("unreadable-file"))
            defer { stage.close() }
            var said: [String] = []
            stage.warn = { said.append($0) }
            var told: [UndeliverableGeneration] = []
            stage.onGenerationUndeliverable = { cause, _ in told.append(cause) }
            stage.displayLinkFired()

            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for _ in 0..<3 { stage.displayLinkFired() }
            #expect(told == [.unreadableFile], "\(told)")
            #expect(said.count == 1 && !(said.first ?? "").contains("mokume doctor"), "\(said)")
            _ = surface
        }
    }

    /// **前の世代を畳んでも、台は前の世代の頼みと寸法を持ち続けない** ([#2928])。見張りが新しい世代へ乗り
    /// 換えたとみなして前の世代を畳むと、前の世代はもう絵を書かないので、カーソルの頼みを読み直す契機が
    /// 来ず、窓は捕まえたまま・隠したままになる。入力を受けるのは新しい子なので、読めた目録の寸法へ
    /// 入力の写しを追随させる。
    ///
    /// [#2928]: https://github.com/mokume-metal/mokume/issues/2928
    @Test("受け取れない世代を知らせるとき、前の世代のカーソルの頼みを下ろし、読めた目録の寸法へ入力の写しを追随させる")
    func undeliverableReleasesTheOldRequestsAndFollowsTheSize() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let requesting = try makeSurface(in: facet, gpu: gpu, drawing: 0)
            try draw(requesting, frame: 1, gpu: gpu, pointerLock: true, cursorHidden: true)
            let url = facet.appendingPathComponent(SharedFrameSurface.manifestName)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("release"))
            defer { stage.close() }
            stage.open()
            stage.warn = { _ in }
            var told: [UndeliverableGeneration] = []
            stage.onGenerationUndeliverable = { cause, _ in told.append(cause) }
            stage.displayLinkFired()
            #expect(stage.pointerLockRequested && stage.cursorHiddenRequested, "検査の前提: 前の世代が頼んでいる")
            let surface = try #require(stage.host as? SketchSurface)
            #expect(surface.canvasWidth == 32)

            // 面を引けない目録 (読める。寸法は 64x48)
            try Data(#"{"schemaVersion":1,"ids":[4000000000],"width":64,"height":48}"#.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
            stage.displayLinkFired()
            #expect(told == [.noSurface])
            #expect(!stage.pointerLockRequested && !stage.cursorHiddenRequested, "前の世代の頼みが残っている")
            #expect(surface.canvasWidth == 64, "入力の写しが前の世代の寸法のまま")
        }
    }

    /// **見張りが映している世代を手放したら、台はその世代の頼みを下ろす** ([#2983])。倒れた子・子の離脱・
    /// 合図の来ないまま次の保存が来た回は台の知らせを通らず、畳まれた世代は絵を書かないので、読み直す
    /// 契機が来ない。最後の絵と入力の写しの寸法は残す。生きて書き続ける世代の頼みは、次の枚数で戻る。
    ///
    /// [#2983]: https://github.com/mokume-metal/mokume/issues/2983
    @Test("映している世代を手放したと伝えられたら、カーソルの頼みを下ろし、絵と入力の写しの寸法は残す")
    func relinquishingTheSourceReleasesTheRequestsAndKeepsThePictureAndSize() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let requesting = try makeSurface(in: facet, gpu: gpu, drawing: 0)
            try draw(requesting, frame: 1, gpu: gpu, pointerLock: true, cursorHidden: true)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("relinquish"))
            defer { stage.close() }
            stage.open()
            stage.displayLinkFired()
            #expect(stage.pointerLockRequested && stage.cursorHiddenRequested, "検査の前提: 世代が頼んでいる")
            let surface = try #require(stage.host as? SketchSurface)
            #expect(surface.canvasWidth == 32)

            stage.relinquishSource(pids: [ProcessInfo.processInfo.processIdentifier])
            #expect(!stage.pointerLockRequested && !stage.cursorHiddenRequested, "手放した世代の頼みが残っている")
            #expect(stage.hasSource, "最後の絵を消した")
            #expect(surface.canvasWidth == 32, "入力の写しの寸法を変えた")

            // **手放した世代は、同じ面の次の枚数でも頼みを戻さない** (止めるまでに書いた 1 枚・止まらない子が
            // 書き続ける枚)。頼みの写しを空にするだけでは、次の 1 枚で戻る
            for frame in 2...4 {
                try draw(requesting, frame: frame, gpu: gpu, pointerLock: true, cursorHidden: true)
                stage.displayLinkFired()
                #expect(
                    !stage.pointerLockRequested && !stage.cursorHiddenRequested,
                    "手放した世代の \(frame) 枚目で頼みが戻った")
            }
            #expect(stage.hasSource, "最後の絵を消した")

            // 新しい世代へ乗り換えれば、その世代の頼みには従う (手放したのは前の世代だけ)
            // (別の子の番号で。同じ番号の目録は、手放した世代のものとして扱われる)
            let next = try publish(in: facet, gpu: gpu, pid: 300, frames: 0, pointerLock: false)
            try draw(next, frame: 1, gpu: gpu, pointerLock: true, cursorHidden: true)
            stage.displayLinkFired()
            #expect(
                stage.pointerLockRequested && stage.cursorHiddenRequested,
                "乗り換えた新しい世代の頼みに従わない")
        }
    }

    /// **子が言った警告は、道具の窓が控えて出す** ([#3087](https://github.com/mokume-metal/mokume/issues/3087))。
    /// 速さと違い古くならない (``RemoteTempo`` の鮮度の外) ので、次の世代の絵が来るまで残り、
    /// 新しい世代が何も言っていなければ消える。
    @Test("子が言った警告は台が控え、新しい世代の絵が来て何も言っていなければ消える")
    func theStageKeepsTheWarningsUntilTheNextGenerationDraws() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let first = try makeSurface(in: facet, gpu: gpu, drawing: 0)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("warnings"))
            defer { stage.close() }
            stage.open()
            #expect(stage.warnings == nil, "絵が来る前から警告を名乗った")

            var spoken = SharedFrameSurfaceTests.numbers(frame: 1)
            spoken.warningCount = 2
            spoken.lastWarning = "Transforms are written again every frame"
            try draw(first, frame: 1, gpu: gpu, numbers: spoken)
            stage.displayLinkFired()
            #expect(
                stage.warnings
                    == WarningSummary(count: 2, last: "Transforms are written again every frame"))

            // 同じ世代の次の枚数 (何も言い足さない) でも残る
            var again = SharedFrameSurfaceTests.numbers(frame: 2)
            again.warningCount = spoken.warningCount
            again.lastWarning = spoken.lastWarning
            try draw(first, frame: 2, gpu: gpu, numbers: again)
            stage.displayLinkFired()
            #expect(stage.warnings?.count == 2)

            // 何も言っていない新しい世代の絵が来れば、前の世代の警告は消える
            let next = try publish(in: facet, gpu: gpu, pid: 300, frames: 0, pointerLock: false)
            try draw(next, frame: 1, gpu: gpu)
            stage.displayLinkFired()
            #expect(stage.warnings == nil, "新しい世代が何も言っていないのに、前の世代の警告が残っている")
        }
    }

    /// **警告の控えは、面の値と一緒に動く。** 数字を載せない面 (速さを載せない古いライブラリの子) は数字の読みで
    /// 先に抜けるので、そこで抜けると前の値が残る ([#3087](https://github.com/mokume-metal/mokume/issues/3087) の反証)。
    @Test("数字の載らない面の絵が来たら、前の警告は残らない")
    func aSurfaceWithoutNumbersCarriesNoWarnings() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let shared = try makeSurface(in: facet, gpu: gpu, drawing: 0)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("no-numbers"))
            defer { stage.close() }
            stage.open()
            var spoken = SharedFrameSurfaceTests.numbers(frame: 1)
            spoken.warningCount = 2
            spoken.lastWarning = "spoken once"
            try draw(shared, frame: 1, gpu: gpu, numbers: spoken)
            stage.displayLinkFired()
            #expect(stage.warnings?.count == 2, "検査の前提: 警告を名乗っている")

            // 次の絵は、数字を載せない子の絵 (数字の鍵が無い)
            try draw(shared, frame: 2, gpu: gpu)
            stripNumbers(from: shared)
            stage.displayLinkFired()
            #expect(stage.warnings == nil, "数字の載らない面なのに、前の警告が残っている")
        }
    }

    /// **乗り換えでは前の世代の警告を捨て、前の版へ戻すときは死んだ世代の警告を捨てる** ([#3087])。戻した前の版の
    /// 値は、次のリフレッシュがその面から読み直す。
    @Test("乗り換えた瞬間に前の世代の警告は消え、乗り換えないと伝えれば死んだ世代の警告も消えて前の版の値に戻る")
    func promotionAndAbandonmentDropTheOldWarnings() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            // 窓を開かない台: 乗り換えても 1 枚目の合図は鳴らず、直前の世代を持ち続ける
            let previous = try publish(in: facet, gpu: gpu, pid: 100, frames: 0, pointerLock: false)
            var spoken = SharedFrameSurfaceTests.numbers(frame: 1)
            spoken.warningCount = 3
            spoken.lastWarning = "from the previous version"
            try draw(previous, frame: 1, gpu: gpu, numbers: spoken)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("warnings-handover"))
            defer { stage.close() }
            var seenAtPromotion: [WarningSummary?] = []
            stage.onGenerationPromoted = { [unowned stage] _ in seenAtPromotion.append(stage.warnings) }
            stage.displayLinkFired()
            #expect(stage.displayedPID == 100 && stage.warnings?.count == 3, "検査の前提")
            seenAtPromotion.removeAll()

            // 死ぬ子 (200) は別の警告を言って 1 枚書き、乗り換えられる
            let dead = try publish(in: facet, gpu: gpu, pid: 200, frames: 0, pointerLock: false)
            var deadSpoken = SharedFrameSurfaceTests.numbers(frame: 1)
            deadSpoken.warningCount = 7
            deadSpoken.lastWarning = "from the dying child"
            try draw(dead, frame: 1, gpu: gpu, numbers: deadSpoken)
            stage.displayLinkFired()
            #expect(stage.displayedPID == 200)
            #expect(seenAtPromotion.count == 1 && seenAtPromotion[0] == nil, "乗り換えた時点で前の世代の警告が残っている")
            #expect(stage.warnings?.count == 7, "乗り換えた世代の警告を読んでいない")

            // 見張りが乗り換えないと決める: 死んだ子の警告は消え、次のリフレッシュで前の版の値に戻る
            stage.abandonIncoming(pids: [200])
            #expect(stage.displayedPID == 100)
            #expect(stage.warnings == nil, "死んだ世代の警告が残っている: \(String(describing: stage.warnings))")
            stage.displayLinkFired()
            #expect(stage.warnings?.count == 3 && stage.warnings?.last == "from the previous version")
        }
    }

    /// **プレビューは、後から来た警告で面の枠を伸ばす** ([#3087](https://github.com/mokume-metal/mokume/issues/3087))。
    /// つまみの顔ぶれが変わらなければ面は作り直さないので、拍ごとに警告を押し込んで枠を置き直す。
    @Test("プレビューの枠は、警告が後から来ると伸び、新しい世代が何も言わなければ縮む")
    func thePreviewPanelGrowsWhenAWarningArrivesLater() throws {
        try withFacet { facet in
            let params = facet.appendingPathComponent("params", isDirectory: true)
            try FileManager.default.createDirectory(at: params, withIntermediateDirectories: true)
            let gpu = try RenderDevice()
            let first = try publish(in: facet, gpu: gpu, pid: 100, frames: 1, pointerLock: false)
            let preview = try SharedFramePreview(
                gpu: gpu, facet: facet, params: params, title: "警告で伸びる-\(UUID().uuidString)")
            preview.open()
            defer { preview.close() }
            preview.stage.displayLinkFired()
            let bare = try #require(preview.panelHeight)

            var spoken = SharedFrameSurfaceTests.numbers(frame: 2)
            spoken.warningCount = 1
            spoken.lastWarning = "Transforms are written again every frame, so call this from draw()."
            try draw(first, frame: 2, gpu: gpu, numbers: spoken)
            preview.stage.displayLinkFired()
            #expect(preview.stage.warnings?.count == 1, "検査の前提: 台が警告を控えた")
            // 拍の頭で面へ押し込み、その後で読むので、面に載るのは次の拍
            preview.stage.displayLinkFired()
            let grown = try #require(preview.panelHeight)
            #expect(grown > bare, "警告が来たのに枠が伸びていない: \(bare) → \(grown)")

            // 何も言っていない新しい世代へ乗り換えれば、欄は消えて枠は元の丈に戻る
            let next = try publish(in: facet, gpu: gpu, pid: 200, frames: 0, pointerLock: false)
            try draw(next, frame: 1, gpu: gpu)
            preview.stage.displayLinkFired()
            preview.stage.displayLinkFired()
            preview.stage.displayLinkFired()
            #expect(preview.stage.warnings == nil)
            #expect(preview.panelHeight == bare, "欄が消えたのに枠が縮んでいない")
        }
    }

    /// 面から数字の鍵 (進めた枚数と時刻) を外す。数字を載せない子の面を作る。
    private func stripNumbers(from shared: SharedFrameSurface) {
        for id in shared.ids {
            guard let surface = IOSurfaceLookup(id) else { continue }
            IOSurfaceRemoveValue(surface, SharedFrameSurface.TempoAttribute.frameCount as CFString)
            IOSurfaceRemoveValue(surface, SharedFrameSurface.TempoAttribute.time as CFString)
        }
    }

    /// **受け取れない知らせの経路も同じ形** ([#2928] の経路・[#2983])。生きた前の世代の次の 1 枚で頼みが
    /// 戻らない。
    ///
    /// [#2928]: https://github.com/mokume-metal/mokume/issues/2928
    /// [#2983]: https://github.com/mokume-metal/mokume/issues/2983
    @Test("受け取れない世代を知らせた後も、前の世代の次の枚数で頼みは戻らない")
    func undeliverableKeepsTheOldRequestsReleasedAcrossItsNextFrames() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let requesting = try makeSurface(in: facet, gpu: gpu, drawing: 0)
            try draw(requesting, frame: 1, gpu: gpu, pointerLock: true, cursorHidden: true)
            let url = facet.appendingPathComponent(SharedFrameSurface.manifestName)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("release-twice"))
            defer { stage.close() }
            stage.open()
            stage.warn = { _ in }
            stage.displayLinkFired()
            #expect(stage.pointerLockRequested, "検査の前提: 前の世代が頼んでいる")

            try Data(#"{"schemaVersion":1,"ids":[4000000000],"width":64,"height":48}"#.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
            stage.displayLinkFired()
            #expect(!stage.pointerLockRequested && !stage.cursorHiddenRequested)

            try draw(requesting, frame: 2, gpu: gpu, pointerLock: true, cursorHidden: true)
            stage.displayLinkFired()
            #expect(
                !stage.pointerLockRequested && !stage.cursorHiddenRequested,
                "生きた前の世代の次の 1 枚で頼みが戻った")
        }
    }

    // MARK: - 合図が名乗る子の番号 (#2982)

    /// 目録を置き直す (書き手の番号を選ぶ)。`ids` は実在の面のもの。
    private func place(manifest json: String, in facet: URL) throws {
        let url = facet.appendingPathComponent(SharedFrameSurface.manifestName)
        try Data(json.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
    }

    /// **乗り換えの合図は、乗り換えた世代の目録が名乗った子の番号を添える** ([#2982](https://github.com/mokume-metal/mokume/issues/2982))。
    /// 番号を名乗らない子 (古いライブラリ) は `nil`。
    @Test("乗り換えの合図に、目録が名乗った子の番号が添う。名乗らない目録は nil")
    func promotionCarriesTheWriterPid() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let first = try makeSurface(in: facet, gpu: gpu, drawing: 1)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("pid-promoted"))
            defer { stage.close() }
            var told: [Int32?] = []
            stage.onGenerationPromoted = { told.append($0) }
            stage.displayLinkFired()
            // 子が自分の番号を目録へ置く (`publishManifest()`)
            #expect(told == [ProcessInfo.processInfo.processIdentifier], "\(told)")

            // 番号を書かない子へ入れ替わる
            let silent = try SharedFrameSurface(gpu: gpu, width: 32, height: 32, at: facet)
            try place(
                manifest: #"{"schemaVersion":1,"ids":\#(silent.ids),"width":32,"height":32}"#, in: facet)
            try draw(silent, frame: 1, gpu: gpu)
            stage.displayLinkFired()
            #expect(told.count == 2 && told[1] == nil, "\(told)")
            _ = first
        }
    }

    /// **1 枚目を出した知らせは、その世代の目録が名乗った子の番号を添え、世代ごとに 1 度だけ出る**
    /// ([#3172](https://github.com/mokume-metal/mokume/issues/3172))。乗り換えの合図は、出している世代が無いと絵を
    /// 待たずに出るので、見張りが「絵を出す前に終わった子」を読む根拠はこちらである。
    @Test("1 枚目を出した知らせに、目録が名乗った子の番号が添う。世代ごとに 1 度で、名乗らない目録は nil")
    func shownCarriesTheWriterPid() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            // 目録だけで、まだ 1 枚も書いていない世代
            let first = try makeSurface(in: facet, gpu: gpu, drawing: 0)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("pid-shown"))
            defer { stage.close() }
            stage.open()
            var told: [Int32?] = []
            stage.onGenerationShown = { told.append($0) }
            stage.displayLinkFired()
            #expect(stage.hasSource)
            #expect(told.isEmpty, "絵を出す前に、1 枚目を出したと知らせた: \(told)")

            try draw(first, frame: 1, gpu: gpu)
            stage.displayLinkFired()
            #expect(told == [ProcessInfo.processInfo.processIdentifier], "\(told)")
            try draw(first, frame: 2, gpu: gpu)
            stage.displayLinkFired()
            #expect(told.count == 1, "同じ世代で 2 度知らせた: \(told)")

            // 番号を書かない子へ入れ替わる
            let silent = try SharedFrameSurface(gpu: gpu, width: 32, height: 32, at: facet)
            try place(
                manifest: #"{"schemaVersion":1,"ids":\#(silent.ids),"width":32,"height":32}"#, in: facet)
            try draw(silent, frame: 1, gpu: gpu)
            stage.displayLinkFired()
            #expect(told.count == 2 && told[1] == nil, "\(told)")
        }
    }

    /// **乗り換えないと決めた世代は、控えを捨て、後から来ても採らない** ([#3172](https://github.com/mokume-metal/mokume/issues/3172) の反証)。
    /// 起動に失敗した新しい版を捨てて前の版を戻したのに、台が 1 枚書いて死んだ子の絵へ乗り換えると、動いている前の版の
    /// 代わりに死んだ子の絵を映す。
    @Test("乗り換えないと伝えた世代は、控えていれば捨て、まだ採っていなければ採らず、映している世代には触らない")
    func anAbandonedGenerationIsNeverPromoted() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let shown = try makeSurface(in: facet, gpu: gpu, drawing: 1)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("abandon"))
            defer { stage.close() }
            var promotions = 0
            stage.onGenerationPromoted = { _ in promotions += 1 }
            stage.displayLinkFired()
            #expect(promotions == 1)

            // すでに控えている世代 (まだ 1 枚も書いていない)
            let dying = try publish(in: facet, gpu: gpu, pid: 4242, frames: 0, pointerLock: false)
            stage.displayLinkFired()
            #expect(stage.hasIncoming)
            stage.abandonIncoming(pids: [4242])
            #expect(!stage.hasIncoming, "控えを捨てていない")
            _ = dying
            // 1 枚書いて死んでも、乗り換えない
            try draw(dying, frame: 1, gpu: gpu)
            stage.displayLinkFired()
            #expect(promotions == 1, "捨てた世代へ乗り換えた")

            // まだ採っていない目録も、採らない
            let late = try publish(in: facet, gpu: gpu, pid: 4243, frames: 1, pointerLock: false)
            stage.abandonIncoming(pids: [4243])
            stage.displayLinkFired()
            #expect(!stage.hasIncoming && promotions == 1, "後から来た目録を採った")
            _ = late

            // 別の番号の世代へは、これまでどおり乗り換える。映していた世代には触っていない
            _ = try publish(in: facet, gpu: gpu, pid: 4244, frames: 1, pointerLock: false)
            stage.displayLinkFired()
            #expect(promotions == 2, "別の世代へ乗り換えられなくなった")
            _ = shown
        }
    }

    /// **乗り換え済みで描画が見送られた子が死んでも、前の版へ映し直す** ([#3172](https://github.com/mokume-metal/mokume/issues/3172) の反証 2 回目)。
    /// 台は乗り換えた拍に描画を試し、面が取れなければ 1 枚目の合図は鳴らない。見張りはその子を「絵を出す前に
    /// 終わった」と読んで前の版を戻すので、台も死んだ子の目録を映したままではいけない。
    @Test("乗り換え済みで描画が見送られた子を乗り換えないと伝えると、前の版へ映し直し、前の版の頼みが効く")
    func anAbandonedPromotedGenerationReturnsToThePreviousOne() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            // 窓を開かない台: 乗り換えても描画は見送られ、1 枚目の合図は鳴らない
            let previous = try publish(in: facet, gpu: gpu, pid: 100, frames: 1, pointerLock: true)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("abandon-promoted"))
            defer { stage.close() }
            var shown = 0
            stage.onGenerationShown = { _ in shown += 1 }
            stage.displayLinkFired()
            #expect(stage.displayedPID == 100 && stage.pointerLockRequested, "検査の前提: 前の版が頼んでいる")

            // 死んだ子が 1 枚書いて乗り換えられ、見張りの伝える順 (手放す → 乗り換えない)
            _ = try publish(in: facet, gpu: gpu, pid: 200, frames: 1, pointerLock: false)
            stage.displayLinkFired()
            #expect(stage.displayedPID == 200 && shown == 0, "検査の前提: 乗り換え済みで合図は鳴っていない")
            stage.relinquishSource(pids: [200])
            stage.abandonIncoming(pids: [200])
            #expect(stage.displayedPID == 100, "死んだ子の目録を映したまま: \(String(describing: stage.displayedPID))")
            #expect(!stage.holdsSupersededSource)

            // 前の版が生きて書き続ける: 頼みが戻り、死んだ子の目録は採り直さない
            try draw(previous, frame: 2, gpu: gpu, pointerLock: true)
            stage.displayLinkFired()
            #expect(stage.pointerLockRequested, "前の版の頼みが効かない")
            #expect(stage.displayedPID == 100 && !stage.hasIncoming)

            // 別の番号の世代へは、これまでどおり乗り換える
            _ = try publish(in: facet, gpu: gpu, pid: 300, frames: 1, pointerLock: false)
            stage.displayLinkFired()
            #expect(stage.displayedPID == 300)
        }
    }

    /// **直前の世代を持つのは、乗り換えた世代が 1 枚目を出すまで** ([#3172](https://github.com/mokume-metal/mokume/issues/3172))。
    /// 出した後に終わった子は「自分で消えた」と読まれ、見張りは前の版を戻さない — 持ち続けると、常駐が積み上がる。
    @Test("乗り換えた世代が 1 枚目を出したら、直前の世代の常駐を外す。出した世代は乗り換えないと伝えても戻さない")
    func theSupersededGenerationIsReleasedOnceTheNewOneHasShown() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let first = try publish(in: facet, gpu: gpu, pid: 100, frames: 1, pointerLock: false)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("superseded-released"))
            defer { stage.close() }
            stage.open()
            stage.displayLinkFired()
            #expect(!stage.holdsSupersededSource, "最初の世代に直前は無い")

            // 控えは 1 枚も書いていない: 乗り換えない
            let next = try publish(in: facet, gpu: gpu, pid: 200, frames: 0, pointerLock: false)
            stage.displayLinkFired()
            #expect(stage.displayedPID == 100 && stage.hasIncoming)
            try draw(next, frame: 1, gpu: gpu)
            stage.displayLinkFired()
            #expect(stage.displayedPID == 200)
            #expect(!stage.holdsSupersededSource, "1 枚目を出したのに直前の世代を持っている")

            stage.abandonIncoming(pids: [200])
            #expect(stage.displayedPID == 200, "1 枚目を出した世代を、前の版へ戻した")
            _ = first
        }
    }

    /// **乗り換えないと決めた番号は、新しい子を起こしたら外す** ([#3172](https://github.com/mokume-metal/mokume/issues/3172) の反証 2 回目)。
    /// 番号は使い回される。起動の失敗が乗り換えの無いまま重なっても、同じ番号を得た新しい子の目録を黙って捨てない。
    @Test("新しい子を起こしたと伝えた番号は、乗り換えないと決めた世代から外れ、その目録を採る")
    func aRecycledPidIsNotAbandonedForever() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            _ = try publish(in: facet, gpu: gpu, pid: 100, frames: 1, pointerLock: false)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("pid-recycled"))
            defer { stage.close() }
            stage.displayLinkFired()

            // 起動に失敗した子 (200) を乗り換えない。乗り換えの無いまま、番号が一周して新しい子が 200 を得る
            stage.abandonIncoming(pids: [200])
            stage.expectGeneration(pids: [200])
            _ = try publish(in: facet, gpu: gpu, pid: 200, frames: 1, pointerLock: false)
            stage.displayLinkFired()
            #expect(stage.displayedPID == 200, "新しい子の目録を捨てた")

            // 伝えなければ、従来どおり採らない
            stage.abandonIncoming(pids: [300])
            _ = try publish(in: facet, gpu: gpu, pid: 300, frames: 1, pointerLock: false)
            stage.displayLinkFired()
            #expect(stage.displayedPID == 200 && !stage.hasIncoming)
        }
    }

    /// **手放した番号の覚えも、新しい子を起こしたら外す** ([#3172](https://github.com/mokume-metal/mokume/issues/3172))。
    /// 番号が一周して同じ番号を得た新しい子を、生まれたときから手放した扱いにして頼みを読まないままにしない。
    @Test("新しい子を起こしたと伝えた番号は、手放した世代の覚えからも外れ、その子の頼みを読む")
    func aRecycledPidIsNotRelinquishedForever() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            _ = try publish(in: facet, gpu: gpu, pid: 100, frames: 1, pointerLock: false)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("pid-recycled-relinquished"))
            defer { stage.close() }
            stage.displayLinkFired()

            // 子 (200) が消えて手放した。番号が一周して、新しい子が 200 を得る
            stage.relinquishSource(pids: [200])
            stage.expectGeneration(pids: [200])
            let fresh = try publish(in: facet, gpu: gpu, pid: 200, frames: 1, pointerLock: true)
            stage.displayLinkFired()
            #expect(stage.displayedPID == 200)
            #expect(stage.pointerLockRequested, "新しい子を手放した扱いにして、頼みを読まなかった")

            // 伝えなければ、従来どおり生まれたときから手放した扱い
            stage.relinquishSource(pids: [300, 200])
            let stale = try publish(in: facet, gpu: gpu, pid: 300, frames: 1, pointerLock: true)
            stage.displayLinkFired()
            #expect(stage.displayedPID == 300 && !stage.pointerLockRequested)
            _ = (fresh, stale)
        }
    }

    @Test("受け取れない知らせに、読めた目録の子の番号が添い、読めない目録・名乗らない目録では nil")
    func undeliverableCarriesTheWriterPid() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let shown = try makeSurface(in: facet, gpu: gpu, drawing: 1)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("pid-undeliverable"))
            defer { stage.close() }
            stage.open()
            stage.warn = { _ in }
            var told: [(UndeliverableGeneration, Int32?)] = []
            stage.onGenerationUndeliverable = { told.append(($0, $1)) }
            stage.displayLinkFired()

            try place(
                manifest: #"{"schemaVersion":1,"ids":[4000000000],"width":10,"height":10,"pid":4242}"#,
                in: facet)
            stage.displayLinkFired()
            try place(
                manifest: #"{"schemaVersion":1,"ids":[4000000001],"width":10,"height":10}"#, in: facet)
            stage.displayLinkFired()
            try place(manifest: #"{"schemaVersion":99,"ids":[1],"width":10,"height":10,"pid":7}"#, in: facet)
            stage.displayLinkFired()

            #expect(told.map(\.0) == [.noSurface, .noSurface, .unreadableManifest])
            #expect(told.map(\.1) == [4242, nil, nil], "\(told.map(\.1))")
            _ = shown
        }
    }

    // MARK: - 手放す世代を番号で指す (#2982・#2983)

    /// 面を作り、目録を (番号つきで) 置く。`pid` が `nil` なら番号を書かない子 (古いライブラリ) の目録。
    private func publish(
        in facet: URL, gpu: RenderDevice, pid: Int32?, frames: Int, pointerLock: Bool
    ) throws -> SharedFrameSurface {
        let surface = try SharedFrameSurface(gpu: gpu, width: 32, height: 32, at: facet)
        let pidField = pid.map { #","pid":\#($0)"# } ?? ""
        try place(
            manifest: #"{"schemaVersion":1,"ids":\#(surface.ids),"width":32,"height":32\#(pidField)}"#,
            in: facet)
        for frame in 0..<frames {
            try draw(surface, frame: frame + 1, gpu: gpu, pointerLock: pointerLock)
        }
        return surface
    }

    /// **乗り換えを待つ子が 1 枚書いてすぐ死に、離脱の知らせが台の拍より先に来ても、台は死んだ子の頼みを読まない**
    /// ([#2983] の反証 6)。伝えた時点では台はまだ死んだ子の目録を採っていないので、番号で指して、採った目録も
    /// 生まれたときから手放した扱いにする。生きた別の世代の頼みには従う。
    ///
    /// [#2983]: https://github.com/mokume-metal/mokume/issues/2983
    @Test("手放した番号の世代の目録は、後から採っても頼みを読まない。別の番号の世代の頼みには従う")
    func aRelinquishedPidIsBornReleased() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let shown = try publish(in: facet, gpu: gpu, pid: 100, frames: 1, pointerLock: true)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("pid-born-released"))
            defer { stage.close() }
            stage.open()
            stage.displayLinkFired()
            #expect(stage.pointerLockRequested, "検査の前提: 映っている世代が頼んでいる")

            // 離脱の知らせが先に来る: 死んだ子 (200) と畳まれる前の世代 (100) を手放す。台はまだ 200 の目録を採っていない
            stage.relinquishSource(pids: [200, 100])
            #expect(!stage.pointerLockRequested)

            // 200 が 1 枚書いて死んでいた。台はそこへ乗り換えるが、頼みは読まない
            let dead = try publish(in: facet, gpu: gpu, pid: 200, frames: 1, pointerLock: true)
            stage.displayLinkFired()
            #expect(!stage.hasIncoming, "検査の前提: 死んだ子へ乗り換えた")
            #expect(!stage.pointerLockRequested, "死んだ子の頼みを読んだ")
            try draw(dead, frame: 2, gpu: gpu, pointerLock: true)
            stage.displayLinkFired()
            #expect(!stage.pointerLockRequested)

            // 別の番号の生きた世代へ乗り換えれば、その頼みには従う
            let alive = try publish(in: facet, gpu: gpu, pid: 300, frames: 1, pointerLock: true)
            stage.displayLinkFired()
            #expect(stage.pointerLockRequested, "生きた別の世代の頼みに従わない")
            _ = (shown, alive)
        }
    }

    /// 映っている世代が名乗る番号が手放す世代でなければ、頼みを下ろさず読み続ける (映っている生きた世代に
    /// 誤って当てない)。番号を名乗らない世代 (古いライブラリ) は、番号で照合できないので今までどおり下ろす。
    @Test("手放す番号に映っている世代が無ければ頼みを下ろさず、番号を名乗らない世代は下ろす")
    func relinquishingMatchesTheDisplayedGenerationByPid() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let live = try publish(in: facet, gpu: gpu, pid: 100, frames: 1, pointerLock: true)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("pid-match"))
            defer { stage.close() }
            stage.open()
            stage.displayLinkFired()
            #expect(stage.pointerLockRequested)

            stage.relinquishSource(pids: [999])
            #expect(stage.pointerLockRequested, "映っている生きた世代の頼みを手放させた")
            try draw(live, frame: 2, gpu: gpu, pointerLock: true)
            stage.displayLinkFired()
            #expect(stage.pointerLockRequested)

            // 番号を名乗らない世代へ乗り換える
            let legacy = try publish(in: facet, gpu: gpu, pid: nil, frames: 1, pointerLock: true)
            stage.displayLinkFired()
            #expect(stage.pointerLockRequested)
            stage.relinquishSource(pids: [999])
            #expect(!stage.pointerLockRequested, "番号を名乗らない世代を下ろさない")
            try draw(legacy, frame: 2, gpu: gpu, pointerLock: true)
            stage.displayLinkFired()
            #expect(!stage.pointerLockRequested)
        }
    }

    /// **手放した覚えは、乗り換えで消える** ([#2983] の反証)。面の番号は再利用されうるので、後の世代が同じ番号の
    /// 並びを得ても、生きた世代の頼みを読まないままにしない。子の番号も同じで、別の世代へ乗り換えたら捨てる。
    ///
    /// [#2983]: https://github.com/mokume-metal/mokume/issues/2983
    @Test("手放した覚えは乗り換えで消える (面の番号・子の番号の使い回しで、生きた世代の頼みを読まないままにしない)")
    func theRelinquishedMemoryEndsAtThePromotion() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            // 番号を名乗らない世代 (古いライブラリ) を手放す
            let legacy = try publish(in: facet, gpu: gpu, pid: nil, frames: 1, pointerLock: true)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("memory-ends"))
            defer { stage.close() }
            stage.open()
            stage.displayLinkFired()
            #expect(stage.pointerLockRequested)
            stage.relinquishSource(pids: [999])
            #expect(!stage.pointerLockRequested)

            // 同じ面の番号の並びを持つ、生きた世代へ乗り換える (目録を置き直し、新しい枚を書く)
            try place(
                manifest: #"{"schemaVersion":1,"ids":\#(legacy.ids),"width":32,"height":32}"#,
                in: facet)
            try draw(legacy, frame: 2, gpu: gpu, pointerLock: true)
            stage.displayLinkFired()
            #expect(!stage.hasIncoming, "検査の前提: 乗り換えた")
            #expect(stage.pointerLockRequested, "面の番号の使い回しで、生きた世代の頼みを読まない")

            // 子の番号: 100 を手放し、別の番号 300 へ乗り換えた後に、また 100 を名乗る世代が来ても読む
            let first = try publish(in: facet, gpu: gpu, pid: 100, frames: 1, pointerLock: true)
            stage.displayLinkFired()
            stage.relinquishSource(pids: [100])
            let other = try publish(in: facet, gpu: gpu, pid: 300, frames: 1, pointerLock: true)
            stage.displayLinkFired()
            #expect(stage.pointerLockRequested)
            let reused = try publish(in: facet, gpu: gpu, pid: 100, frames: 1, pointerLock: true)
            stage.displayLinkFired()
            #expect(stage.pointerLockRequested, "子の番号の使い回しで、生きた世代の頼みを読まない")
            _ = (first, other, reused)
        }
    }

    // MARK: - 世代の重なり

    /// **止めてから起こすと、新しい子が最初の絵を焼くまで出せる絵が無くなる。** 目録が
    /// 変わった瞬間に乗り換えていた頃は、保存のたびに画面が **417 ms** 止まっていた
    /// ([#1142](https://github.com/mokume-metal/mokume/issues/1142))。
    ///
    /// 待つのは「1 枚焼いたか」だけで、時計は見ない (ADR-0032 決定 3)。
    @Test("新しい世代が 1 枚も焼いていないうちは、前の世代を出したままにする")
    func keepsShowingTheOldGenerationUntilTheNewOneDraws() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let leaving = try makeSurface(in: facet, gpu: gpu, drawing: 3)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("overlap"))
            defer { stage.close() }
            var promotions = 0
            stage.onGenerationPromoted = { _ in promotions += 1 }

            stage.displayLinkFired()
            #expect(stage.hasSource, "最初の世代を出していない")
            #expect(promotions == 1)

            // 新しい世代が目録を置いた。**まだ 1 枚も焼いていない**
            let arriving = try makeSurface(in: facet, gpu: gpu, drawing: 0)
            stage.displayLinkFired()
            #expect(stage.hasIncoming, "控えていない")
            #expect(stage.hasSource, "焼く前に前の世代を畳んでいる")
            #expect(promotions == 1, "焼く前に入れ替わっている")

            // 1 枚焼いた
            try draw(arriving, frame: 1, gpu: gpu)
            stage.displayLinkFired()
            #expect(!stage.hasIncoming, "入れ替わっていない")
            #expect(stage.hasSource)
            #expect(promotions == 2, "入れ替わりを知らせていない")
            // 前の世代は、こちらが持っている限り生きている (IOSurface は参照計数)
            #expect(SharedFrameSurface.newest(among: leaving.ids)?.frame == 3)
        }
    }

    /// **最初の 1 回は待たない。** 出している世代が無いなら、待っても出るものが無い。
    @Test("出している世代が無ければ、1 枚も焼いていなくても引き受ける")
    func theFirstGenerationIsTakenWithoutWaiting() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let arriving = try makeSurface(in: facet, gpu: gpu, drawing: 0)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("first"))
            defer { stage.close() }

            stage.displayLinkFired()
            #expect(stage.hasSource, "最初の世代を待っている")
            #expect(!stage.hasIncoming)
            _ = arriving
        }
    }

    // MARK: - 面の保持 (#2368)

    /// **面を引くのは、番号の組が変わったときだけである。** 毎リフレッシュ面の数だけ
    /// `IOSurfaceLookup` を出していた ([#2368])。握ったままでも、書き手が載せ替える枚数と
    /// 要求は読めること (読めなくなると、絵が止まるか要求が古いままになる) を一緒に見る。
    ///
    /// [#2368]: https://github.com/mokume-metal/mokume/issues/2368
    @Test("番号の組が変わらない間は、リフレッシュを重ねても面を引き直さない")
    func doesNotLookTheSurfacesUpAgainWhileTheIdsStay() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let first = try makeSurface(in: facet, gpu: gpu, drawing: 1)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("lookups"))
            defer { stage.close() }

            stage.displayLinkFired()
            #expect(stage.hasSource)
            let afterAdopting = stage.surfaceLookups
            #expect(afterAdopting > 0, "数える口が数えていない")

            // 書き手が枚数と要求を載せ替え続けても、握った面から読める
            for frame in 2...12 {
                try draw(first, frame: frame, gpu: gpu, pointerLock: frame == 12)
                stage.displayLinkFired()
            }
            #expect(stage.pointerLockRequested, "握った面から、載せ替えた要求を読めていない")
            #expect(stage.surfaceLookups == afterAdopting, "番号の組が同じなのに面を引き直している")

            // 入れ替わった (別の番号の組) ら、新しい面を引く
            let second = try makeSurface(in: facet, gpu: gpu, drawing: 1)
            stage.displayLinkFired()
            #expect(stage.surfaceLookups > afterAdopting, "新しい世代の面を引いていない")
            _ = second
        }
    }

    /// 引けなかった番号は持たない — 置いた側がまだ作っていないだけかもしれないので、次の機会に引き直す。
    @Test("引けなかった番号は持たず、引けた面は引き直さない")
    func retriesAnIdThatCouldNotBeLooked() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let shared = try makeSurface(in: facet, gpu: gpu, drawing: 1)
            let missing = UInt32.max
            let lookup = SharedFrameSurface.Lookup(ids: [missing] + shared.ids)
            let newest = try #require(lookup.newest())
            #expect(shared.ids.contains(newest.id))
            let afterFirst = lookup.lookups
            #expect(lookup.newest()?.id == newest.id)
            // 引けた面は引き直さず、引けなかった 1 つだけを引き直す
            #expect(lookup.lookups == afterFirst + 1)
            #expect(lookup.surface(missing) == nil)
        }
    }

    // MARK: - 捕まえの要求 (#1144)

    /// 捕まえるのは道具の窓で、要求は子が面の属性に載せる。**保存で子が入れ替わったら、新しい
    /// 子の面で判定し直す** — 要求していない子なら外れる。窓を開かずに、台が読んだ値を見る
    /// (窓を開いて捕まえるのは手で確かめる)。
    @Test("子の捕まえの要求を面から読み、入れ替わった後は新しい世代の面で読み直す")
    func readsThePointerLockRequestPerGeneration() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let requesting = try makeSurface(in: facet, gpu: gpu, drawing: 0)
            try draw(requesting, frame: 1, gpu: gpu, pointerLock: true)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("pointer-lock"))
            defer { stage.close() }

            stage.displayLinkFired()
            #expect(stage.pointerLockRequested, "子の要求を読んでいない")

            // 同じ子が取り下げた
            try draw(requesting, frame: 2, gpu: gpu, pointerLock: false)
            stage.displayLinkFired()
            #expect(!stage.pointerLockRequested, "取り下げた要求が残っている")

            // 要求していた子から、要求しない子へ入れ替わる
            try draw(requesting, frame: 3, gpu: gpu, pointerLock: true)
            stage.displayLinkFired()
            #expect(stage.pointerLockRequested)
            let silent = try makeSurface(in: facet, gpu: gpu, drawing: 0)
            stage.displayLinkFired()
            #expect(stage.pointerLockRequested, "焼く前の世代の要求で判定した")
            try draw(silent, frame: 1, gpu: gpu)
            stage.displayLinkFired()
            #expect(!stage.pointerLockRequested, "入れ替わった後も前の世代の要求が残っている")
        }
    }

    // MARK: - 矢印を隠す要求 (#2439)

    /// 隠すのは道具の窓で、要求は子が面の属性に載せる。**窓は自分が映す世代の頼みに従う** — 保存で
    /// 子が入れ替わったら、新しい子の面で判定し直す (`noCursor()` を呼ばない子なら戻る)。捕まえの要求と
    /// 別の属性なので、片方だけを頼む子も読み分けられる。窓を開かずに、台が読んだ値を見る。
    @Test("子の矢印を隠す要求を面から読み、入れ替わった後は新しい世代の面で読み直す")
    func readsTheCursorHidingRequestPerGeneration() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let hiding = try makeSurface(in: facet, gpu: gpu, drawing: 0)
            try draw(hiding, frame: 1, gpu: gpu, cursorHidden: true)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("cursor-hiding"))
            defer { stage.close() }

            stage.displayLinkFired()
            #expect(stage.cursorHiddenRequested, "子の要求を読んでいない")
            #expect(!stage.pointerLockRequested, "捕まえの要求と取り違えた")

            // 同じ子が cursor() で戻した
            try draw(hiding, frame: 2, gpu: gpu, cursorHidden: false)
            stage.displayLinkFired()
            #expect(!stage.cursorHiddenRequested, "戻した要求が残っている")

            // 隠していた子から、隠さない子へ入れ替わる
            try draw(hiding, frame: 3, gpu: gpu, cursorHidden: true)
            stage.displayLinkFired()
            #expect(stage.cursorHiddenRequested)
            let silent = try makeSurface(in: facet, gpu: gpu, drawing: 0)
            stage.displayLinkFired()
            #expect(stage.cursorHiddenRequested, "焼く前の世代の要求で判定した")
            try draw(silent, frame: 1, gpu: gpu)
            stage.displayLinkFired()
            #expect(!stage.cursorHiddenRequested, "入れ替わった後も前の世代の要求が残っている")
        }
    }

    // MARK: - 開く大きさ (#1624)

    /// **作品の窓は、直に走らせたときと同じ大きさで見える** ([ADR-0032] 決定 1)。差し出し元が
    /// 名乗る倍率に合わせ、名乗りが変わらない入れ替えでは手で変えた大きさを残す (#679)。
    /// プレビューは従わない。
    ///
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    @Test("作品の窓は差し出し元の倍率に合わせ、倍率が変わらない入れ替えでは手で変えた大きさを残す")
    func artworkWindowFollowsTheRequestedSize() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let suite = "mokume.test.stage.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }

            var artworkLook = look(fresh())
            artworkLook.followsRequestedSize = true
            let artwork = try SharedFrameStage(gpu: gpu, facet: facet, look: artworkLook)
            let preview = try SharedFrameStage(
                gpu: gpu, facet: facet, look: look(fresh(), size: SharedFramePreview.defaultSize))
            for stage in [artwork, preview] {
                stage.defaults = defaults
                stage.open()
            }
            defer {
                artwork.close()
                preview.close()
            }

            // 32x32 を 1 画素 4 点で
            var arriving = try makeSurface(in: facet, gpu: gpu, drawing: 1, windowScale: 4)
            artwork.displayLinkFired()
            preview.displayLinkFired()
            #expect(artwork.window?.contentLayoutRect.size == NSSize(width: 128, height: 128))
            #expect(preview.window?.contentLayoutRect.size == SharedFramePreview.defaultSize)

            // 人が手で広げた後、同じ倍率の子へ入れ替わった (保存)
            let resized = NSSize(width: 300, height: 200)
            artwork.window?.setContentSize(resized)
            arriving = try makeSurface(in: facet, gpu: gpu, drawing: 1, windowScale: 4)
            artwork.displayLinkFired()
            #expect(artwork.window?.contentLayoutRect.size == resized, "保存で窓が戻った")

            // 倍率を変えて保存した
            arriving = try makeSurface(in: facet, gpu: gpu, drawing: 1, windowScale: 2)
            artwork.displayLinkFired()
            #expect(artwork.window?.contentLayoutRect.size == NSSize(width: 64, height: 64))

            // 倍率を名乗らない子 (古いライブラリ) なら触らない
            artwork.window?.setContentSize(resized)
            arriving = try makeSurface(in: facet, gpu: gpu, drawing: 1)
            artwork.displayLinkFired()
            #expect(artwork.window?.contentLayoutRect.size == resized)
            _ = arriving
        }
    }

    // MARK: - 1 枚目の前の層 (#2876)

    /// **絵が来るまでの層は、不透明な黒で塗る。** 窓は 1 枚目の前に出るので、一度も present していない層の
    /// 透明か不定の中身が見える。層を作るのは `SketchSurface` で、道具の窓も直に走らせる窓も同じ
    /// 面を使う — 起こし方ごとに塗らず、作る所 1 か所で塗る。直に走らせる窓の層は
    /// `LaunchedByToolTests` (窓で開く・窓へ倒れた)・`FullScreenTests` (全画面) が、起こした窓の層を同じ判定
    /// (``OpaqueBlackLayer``) に掛ける。
    @Test("層を作る所が不透明な黒を置き、道具の窓の層も不透明な黒である")
    func theLayerIsPaintedBlackBeforeTheFirstPicture() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = SketchSurface(
            frame: NSRect(x: 0, y: 0, width: 64, height: 64), device: device, input: InputState(),
            canvasSize: (64, 64))
        surface.wantsLayer = true
        #expect(OpaqueBlackLayer.problem(with: surface.metalLayer) == nil, "層を作る所")

        try withFacet { facet in
            let stage = try SharedFrameStage(gpu: RenderDevice(), facet: facet, look: look(fresh()))
            stage.open()
            defer { stage.close() }
            #expect(
                OpaqueBlackLayer.problem(with: stage.window?.contentView?.layer) == nil, "道具の窓の層")
        }
    }

    // MARK: - 全画面 (#2188)

    /// 全画面の口を差し替えた記録。**本物の口は検査を走らせた機械の画面を全画面にしてしまう。**
    private final class FullScreenLog {
        var entered: [NSWindow] = []
        var left: [NSWindow] = []
        /// いま全画面か。
        var isFullScreen = false
        /// 窓がいる画面の識別子。既定は頼まれた画面とは別の画面 (窓を移す道を通す)。
        var windowScreenID: UInt32? = 999
        /// 引ける画面の識別子。**機械の画面は 1 枚でよい** — 引ける識別子には同じ画面を返し、引き方だけを検査する。
        var known: Set<UInt32> = [7, 8]

        func access(screen: NSScreen) -> SharedFrameStage.FullScreenAccess {
            SharedFrameStage.FullScreenAccess(
                screen: { [self] request in known.contains(request.screenID) ? screen : nil },
                windowScreenID: { [self] _ in windowScreenID },
                isFullScreen: { [self] _ in isFullScreen },
                enter: { [self] in entered.append($0) },
                leave: { [self] in left.append($0) })
        }
    }

    private static let projector = SharedFrameSurface.FullScreenDisplay(
        number: 2, name: "Projector", screenID: 7)
    private static let wall = SharedFrameSurface.FullScreenDisplay(
        number: 3, name: "Wall", screenID: 8)

    /// 全画面の口を差し替えた作品の窓を開いて、`body` へ渡す。
    private func withFullScreenStage(
        followsRequestedSize: Bool = true,
        _ body: (SharedFrameStage, FullScreenLog, URL, RenderDevice) throws -> Void
    ) throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let suite = "mokume.test.stage.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let screen = try #require(NSScreen.main ?? NSScreen.screens.first, "画面が無い実行環境")
            var artworkLook = look(fresh())
            artworkLook.followsRequestedSize = followsRequestedSize
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: artworkLook)
            let log = FullScreenLog()
            stage.fullScreen = log.access(screen: screen)
            stage.defaults = defaults
            stage.open()
            defer { stage.close() }
            try body(stage, log, facet, gpu)
        }
    }

    /// **頼みどおりの画面へ置いて、全画面を 1 度頼む。同じ頼みの世代が続いても、手で全画面を抜けた後に同じ頼みの
    /// 世代が来ても、2 度目は頼まない。頼みが変わったら頼む。** 保存のたびに戻ってはならない (ADR-0032 決定 1)。
    @Test("全画面の頼みは、頼まれた画面へ置いて 1 度だけ当て、同じ頼みの世代では当て直さず、変わったら当てる")
    func fullScreenIsAskedOnceUntilTheRequestChanges() throws {
        try withFullScreenStage { stage, log, facet, gpu in
            // 窓が画面の外にいる (別の画面を模す) — 当てると頼まれた画面の使える範囲に収まる
            let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
            stage.window?.setFrameOrigin(NSPoint(x: -20000, y: -20000))

            var arriving = try makeSurface(
                in: facet, gpu: gpu, drawing: 1, fullScreenDisplay: Self.projector)
            stage.displayLinkFired()
            #expect(log.entered.count == 1, "頼まれたのに全画面にしていない")
            #expect(log.entered.first === stage.window)
            #expect(log.left.isEmpty)
            #expect(stage.appliedFullScreen == Self.projector)
            let frame = try #require(stage.window?.frame)
            #expect(
                screen.visibleFrame.contains(frame),
                "窓を頼まれた画面へ移していない (窓 \(frame) / 画面 \(screen.visibleFrame))")
            #expect(stage.window?.collectionBehavior.contains(.fullScreenPrimary) == true)

            // 保存して子が入れ替わった。同じ頼み
            arriving = try makeSurface(
                in: facet, gpu: gpu, drawing: 1, fullScreenDisplay: Self.projector)
            stage.displayLinkFired()
            #expect(log.entered.count == 1, "同じ頼みの世代で、また全画面にした")

            // 手で全画面を抜けた後に保存した
            log.isFullScreen = false
            arriving = try makeSurface(
                in: facet, gpu: gpu, drawing: 1, fullScreenDisplay: Self.projector)
            stage.displayLinkFired()
            #expect(log.entered.count == 1, "手で抜けた全画面へ、保存で戻した")

            // 宣言を 3 枚目へ変えた
            arriving = try makeSurface(in: facet, gpu: gpu, drawing: 1, fullScreenDisplay: Self.wall)
            stage.displayLinkFired()
            #expect(log.entered.count == 2, "頼みが変わったのに当てていない")
            #expect(stage.appliedFullScreen == Self.wall)
            _ = arriving
        }
    }

    @Test("全画面を頼まない世代は何もせず、その後に同じ頼みが戻れば、変わったものとして当てる")
    func aGenerationWithoutTheRequestAsksForNothing() throws {
        try withFullScreenStage { stage, log, facet, gpu in
            var arriving = try makeSurface(in: facet, gpu: gpu, drawing: 1)
            stage.displayLinkFired()
            #expect(log.entered.isEmpty, "欄が無いのに全画面にした")
            #expect(stage.appliedFullScreen == nil)

            arriving = try makeSurface(
                in: facet, gpu: gpu, drawing: 1, fullScreenDisplay: Self.projector)
            stage.displayLinkFired()
            #expect(log.entered.count == 1)

            // 全画面をやめた作品 (窓で開く宣言) に変えて保存した。全画面はそのままにする
            log.isFullScreen = true
            arriving = try makeSurface(in: facet, gpu: gpu, drawing: 1)
            stage.displayLinkFired()
            #expect(log.entered.count == 1)
            #expect(log.left.isEmpty, "頼みが無くなったからと、全画面を抜けさせた")
            #expect(stage.appliedFullScreen == nil)

            // 頼みが戻った — 覚えは捨てたので、変わったものとして当てる
            log.isFullScreen = false
            arriving = try makeSurface(
                in: facet, gpu: gpu, drawing: 1, fullScreenDisplay: Self.projector)
            stage.displayLinkFired()
            #expect(log.entered.count == 2)
            _ = arriving
        }
    }

    @Test("頼まれた画面が引けなければ窓のままにして 1 行言い、覚えずに、次の世代で引ければ当てる")
    func anUnknownDisplayLeavesTheWindowAndSaysSo() throws {
        try withFullScreenStage { stage, log, facet, gpu in
            var said: [String] = []
            stage.warn = { said.append($0) }
            log.known = []

            var arriving = try makeSurface(
                in: facet, gpu: gpu, drawing: 1, fullScreenDisplay: Self.projector)
            stage.displayLinkFired()
            #expect(log.entered.isEmpty)
            #expect(said.count == 1, "\(said)")
            #expect(said.first?.contains("display 2 (Projector)") == true)
            #expect(stage.appliedFullScreen == nil, "引けなかった頼みを、当てたものとして覚えた")

            log.known = [7]
            arriving = try makeSurface(
                in: facet, gpu: gpu, drawing: 1, fullScreenDisplay: Self.projector)
            stage.displayLinkFired()
            #expect(log.entered.count == 1, "画面が繋がった後の世代で当てていない")
            #expect(said.count == 1)
            _ = arriving
        }
    }

    @Test("プレビュー (大きさの頼みに従わない窓) は、全画面の頼みにも従わない")
    func aWindowThatDoesNotFollowTheRequestIgnoresFullScreen() throws {
        try withFullScreenStage(followsRequestedSize: false) { stage, log, facet, gpu in
            let arriving = try makeSurface(
                in: facet, gpu: gpu, drawing: 1, fullScreenDisplay: Self.projector)
            stage.displayLinkFired()
            #expect(log.entered.isEmpty)
            #expect(stage.appliedFullScreen == nil)
            _ = arriving
        }
    }

    /// **全画面の窓は動かせない** — 別の画面へ頼みが変わったときは、抜けてから移して入り直す。手で抜けたときは戻さない。
    @Test("全画面のまま別の画面へ頼みが変わったら、抜け終わってから移して入り直し、手で抜けたときは入らない")
    func movingAFullScreenWindowLeavesFirst() throws {
        try withFullScreenStage { stage, log, facet, gpu in
            var arriving = try makeSurface(
                in: facet, gpu: gpu, drawing: 1, fullScreenDisplay: Self.projector)
            stage.displayLinkFired()
            #expect(log.entered.count == 1)

            // 手で抜けた。頼みは持っていないので、抜け終わっても入らない
            stage.didExitFullScreen()
            #expect(log.entered.count == 1, "手で抜けた窓へ入り直した")

            // 全画面に戻って (いまは頼まれた画面とは別の画面にいる)、3 枚目 (8) へ変えて保存した
            log.isFullScreen = true
            log.windowScreenID = 7
            arriving = try makeSurface(in: facet, gpu: gpu, drawing: 1, fullScreenDisplay: Self.wall)
            stage.displayLinkFired()
            #expect(log.left.count == 1, "全画面のまま別の画面へ移そうとした")
            #expect(log.entered.count == 1, "抜け終わる前に入った")
            #expect(stage.appliedFullScreen == Self.wall)

            log.isFullScreen = false
            stage.didExitFullScreen()
            #expect(log.entered.count == 2, "抜け終わっても入り直していない")

            // 二度目の抜け終わりでは入らない (頼みは使い切った)
            stage.didExitFullScreen()
            #expect(log.entered.count == 2)
            _ = arriving
        }
    }

    @Test("頼まれた画面の全画面にもういるなら、抜けも入りもしない")
    func alreadyFullScreenOnTheRequestedDisplay() throws {
        try withFullScreenStage { stage, log, facet, gpu in
            // 引ける画面は機械の画面 1 枚 (``FullScreenLog/access(screen:)``)。窓がそこの全画面にいる
            let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
            log.isFullScreen = true
            log.windowScreenID = screen.screenID
            let arriving = try makeSurface(
                in: facet, gpu: gpu, drawing: 1, fullScreenDisplay: Self.projector)
            stage.displayLinkFired()
            #expect(log.entered.isEmpty)
            #expect(log.left.isEmpty)
            #expect(stage.appliedFullScreen == Self.projector)
            _ = arriving
        }
    }

    /// 作品の窓とプレビューを開き、差し出し元を 1 つ来させる。
    private func openPair(
        facet: URL, gpu: RenderDevice, defaults: UserDefaults, width: Int, height: Int,
        windowScale: Float
    ) throws -> (artwork: SharedFrameStage, preview: SharedFrameStage, surface: SharedFrameSurface) {
        var artworkLook = look(fresh())
        artworkLook.followsRequestedSize = true
        var previewLook = look(fresh(), size: SharedFramePreview.defaultSize)
        previewLook.nudge = SharedFramePreview.nudge
        previewLook.placesBeneathRequestedArtwork = true
        let artwork = try SharedFrameStage(gpu: gpu, facet: facet, look: artworkLook)
        let preview = try SharedFrameStage(gpu: gpu, facet: facet, look: previewLook)
        for stage in [artwork, preview] {
            stage.defaults = defaults
            stage.open()
        }
        let surface = try SharedFrameSurface(
            gpu: gpu, width: width, height: height, windowScale: windowScale, at: facet)
        try surface.publishManifest()
        try draw(surface, frame: 1, gpu: gpu, width: width, height: height)
        artwork.displayLinkFired()
        preview.displayLinkFired()
        return (artwork, preview, surface)
    }

    /// **作品の窓が高いスケッチでも、プレビューはその真下に並ぶ。** 既定の 480x270 を前提に
    /// した初めの位置のままだと、作品の窓が描く大きさ × 倍率で開いたときに 2 枚が重なる (#1624)。
    @Test("作品の窓が頼まれた大きさで置き直されると、プレビューはその真下へ置き直す")
    func previewMovesBeneathAResizedArtworkWindow() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let suite = "mokume.test.stage.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            // 32x16 を 1 画素 20 点で = 640x320 (既定の 270 より高い)
            let (artwork, preview, surface) = try openPair(
                facet: facet, gpu: gpu, defaults: defaults, width: 32, height: 16, windowScale: 20)
            defer {
                artwork.close()
                preview.close()
            }
            let above = try #require(artwork.window?.frame)
            let below = try #require(preview.window?.frame)
            #expect(artwork.window?.contentLayoutRect.size == NSSize(width: 640, height: 320))
            #expect(
                below.maxY <= above.minY,
                "プレビューが作品の窓に \(below.maxY - above.minY)pt 重なっている (作品の窓 \(above) / プレビュー \(below))")
            #expect(abs(below.midX - above.midX) <= 1, "横の中央が揃っていない")
            // 大きさは変えない
            #expect(preview.window?.contentLayoutRect.size == SharedFramePreview.defaultSize)
            _ = surface
        }
    }

    /// **既定の 480x270 なら、これまでの並び (中央からのずらし量) と同じ。**
    @Test("既定のスケッチ (960x540・倍率 0.5) では、プレビューは従来のずらし量で真下に並ぶ")
    func defaultSketchKeepsTheFormerSpacing() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let suite = "mokume.test.stage.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let (artwork, preview, surface) = try openPair(
                facet: facet, gpu: gpu, defaults: defaults, width: 960, height: 540,
                windowScale: 0.5)
            defer {
                artwork.close()
                preview.close()
            }
            let above = try #require(artwork.window?.frame)
            let below = try #require(preview.window?.frame)
            #expect(artwork.window?.contentLayoutRect.size == SharedFrameWindow.defaultSize)
            #expect(abs((below.midY - above.midY) - SharedFramePreview.nudge.height) <= 1)
            #expect(below.maxY <= above.minY)
            _ = surface
        }
    }

    // MARK: - 手放したときの常駐

    // 下の 2 本は、差し替えのときは面を常駐から外すが、持ち主ごと手放したときは外して
    // いなかった形を見る ([#795])。どちらも `RenderDevice` を渡して持つので、窓や面を
    // 畳んでも土台が生きていれば面が残り続けていた。
    //
    // [#795]: https://github.com/mokume-metal/mokume/issues/795

    /// 作っては手放す回数。
    private static let churns = 8

    @Test("絵を渡す面を作っては手放しても、常駐の集合が増え続けない")
    func discardedSurfacesLeaveTheResidencySet() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            _ = try SharedFrameSurface(gpu: gpu, width: 32, height: 32, at: facet)
            try gpu.settle()
            let settled = gpu.residencySet.allocationCount

            for _ in 0..<Self.churns {
                _ = try SharedFrameSurface(gpu: gpu, width: 32, height: 32, at: facet)
            }
            try gpu.settle()
            let after = gpu.residencySet.allocationCount

            #expect(
                after == settled,
                """
                絵を渡す面を \(Self.churns) 個作って手放したら、常駐の集合が \(after - settled) 個
                残った (増減 0 のはず)。面に被せたテクスチャが退いていない (#795)
                """)
            #expect(gpu.retiredResourceCount == 0)
        }
    }

    @Test("差し出し元を引いた台を手放すと、引いた面が常駐から外れる")
    func discardedStageLeavesTheResidencySet() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let surface = try makeSurface(in: facet, gpu: gpu, drawing: 0)

            @MainActor func churn() throws {
                let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("churn"))
                stage.displayLinkFired()
                try #require(stage.hasSource, "差し出し元を引いていない (これでは何も測れない)")
            }

            try churn()
            try gpu.settle()
            let settled = gpu.residencySet.allocationCount

            for _ in 0..<Self.churns { try churn() }
            try gpu.settle()
            let after = gpu.residencySet.allocationCount

            #expect(
                after == settled,
                """
                差し出し元を引いた台を \(Self.churns) 個作って手放したら、常駐の集合が
                \(after - settled) 個残った (増減 0 のはず)。台は世代の差し替えでは面を外すが、
                手放したときに外していない (#795)
                """)
            #expect(gpu.retiredResourceCount == 0)
            _ = surface
        }
    }

    // MARK: - 打ち切られた差し出し (#2735)

    /// **差し出しの投入を GPU が打ち切ったら、枚数が進むのを待たずに同じ枚を出し直す。** 台は投入の
    /// 直後に「出した」と記すので、記しを戻さないと、書き手が書くのをやめたとき (子の終了・異常終了・
    /// 詰まり) 窓は打ち切られる前の絵のままになる
    /// ([#2735](https://github.com/mokume-metal/mokume/issues/2735))。
    ///
    /// 打ち切りは GPU を止めずに作る (`dropsNextSubmissionForTesting` は結末の記録だけを打ち切りに
    /// する)。見るのは差し出した回数である。打ち切りの無い側では、結末が届いた後も差し出しを
    /// 足さない (ADR-0023 決定 5 — 毎リフレッシュの経路に乗る照会が、普段の差し出しを増やさない)。
    @Test(
        "差し出しの投入が打ち切られたら、枚数が進まなくても結末の後のリフレッシュで同じ枚を出し直す。無ければ出し直さない",
        arguments: [true, false])
    func aDroppedHandOverIsPresentedAgain(dropped: Bool) throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let surface = try makeSurface(in: facet, gpu: gpu, drawing: 1)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("redeliver"))
            stage.open()
            defer { stage.close() }
            stage.displayLinkFired()
            try #require(stage.presentations == 1, "最初の 1 枚を差し出していない (これでは何も測れない)")

            // 書き手が 1 枚進めて書くのをやめる。その 1 枚の差し出しが打ち切られる
            try draw(surface, frame: 2, gpu: gpu)
            if dropped { gpu.dropsNextSubmissionForTesting = DroppedWorkReadersTests.victim }
            stage.displayLinkFired()
            try #require(stage.presentations == 2, "2 枚目を差し出していない (これでは何も測れない)")

            // 結末が届いた後のリフレッシュ。枚数は進んでいない
            try gpu.settle()
            awaitOutcomes(gpu)
            stage.displayLinkFired()
            #expect(
                stage.presentations == (dropped ? 3 : 2),
                "結末の後のリフレッシュで差し出した回数が違う (通算 \(stage.presentations))")

            // 出し直した後も、打ち切りの無かった側も、枚数が進まなければ差し出さない
            try gpu.settle()
            awaitOutcomes(gpu)
            for _ in 0..<3 { stage.displayLinkFired() }
            #expect(
                stage.presentations == (dropped ? 3 : 2),
                "枚数が進まないのに差し出し続けた (通算 \(stage.presentations))")
            #expect(gpu.droppedDeliveriesRevoked == (dropped ? 1 : 0))
            #expect(gpu.pendingRevocationCount == 0, "結末の届いた預けが刈られていない")
        }
    }

    /// **後の差し出しが記し直していれば、前の差し出しの打ち切りでは出し直さない。** 後の絵が既に
    /// 出ているので、出し直すと同じ絵の差し出しを 1 回足すだけになる。
    @Test("打ち切られた差し出しの結末が届く前に新しい枚を出していれば、出し直さない")
    func aDropOvertakenByANewerHandOverIsNotPresentedAgain() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            let surface = try makeSurface(in: facet, gpu: gpu, drawing: 1)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("overtaken"))
            stage.open()
            defer { stage.close() }
            stage.displayLinkFired()

            try draw(surface, frame: 2, gpu: gpu)
            gpu.dropsNextSubmissionForTesting = DroppedWorkReadersTests.victim
            stage.displayLinkFired()
            // 結末を照らす前に、書き手が次の 1 枚を出した。**照会を止めて**その順を作る — 止めないと、
            // 2 枚目の結末が 3 枚目を差し出すリフレッシュの頭で先に照らされ、順が入れ替わらない
            try draw(surface, frame: 3, gpu: gpu)
            gpu.holdRevocations()
            stage.displayLinkFired()
            gpu.releaseRevocations()
            try #require(stage.presentations == 3, "3 枚を差し出していない (これでは何も測れない)")

            try gpu.settle()
            awaitOutcomes(gpu)
            for _ in 0..<3 { stage.displayLinkFired() }
            #expect(
                stage.presentations == 3,
                "後の差し出しが記し直した後に、前の打ち切りで出し直した (通算 \(stage.presentations))")
            #expect(gpu.droppedDeliveriesRevoked == 1, "打ち切りの結末を照らしていない — 前提が崩れている")
        }
    }

    /// **結末を失った差し出しも出し直す** ([#2735] の反証)。記帳を取り消す口は、確かめられない結末を
    /// 正常の側へ倒す (#2199) が、台は同じ絵をもう一度出すだけなので、届けられなかった側へ倒す。
    ///
    /// 失った結末は `losesNextOutcomeForTesting` で作り、投げる読む口と同じ待ち (`droppedWork`) が
    /// 期限で「結末を失った」と記してから照らす。
    ///
    /// [#2735]: https://github.com/mokume-metal/mokume/issues/2735
    @Test("差し出しの投入の結末を失ったら、結末の後のリフレッシュで同じ枚を出し直す")
    func aHandOverWhoseOutcomeWasLostIsPresentedAgain() throws {
        try withFacet { facet in
            let gpu = try RenderDevice()
            gpu.outcomeWaitLimit = .milliseconds(200)
            let surface = try makeSurface(in: facet, gpu: gpu, drawing: 1)
            let stage = try SharedFrameStage(gpu: gpu, facet: facet, look: look("lost"))
            stage.open()
            defer { stage.close() }
            stage.displayLinkFired()

            try draw(surface, frame: 2, gpu: gpu)
            gpu.losesNextOutcomeForTesting = true
            stage.displayLinkFired()
            try #require(stage.presentations == 2, "2 枚目を差し出していない (これでは何も測れない)")

            // 期限まで待って、届かなかった結末を「失った」と記す
            try gpu.settle()
            awaitOutcomes(gpu)
            stage.displayLinkFired()
            #expect(stage.presentations == 3, "結末を失った差し出しを出し直していない (通算 \(stage.presentations))")
            for _ in 0..<3 { stage.displayLinkFired() }
            #expect(stage.presentations == 3, "出し直した後も差し出し続けた (通算 \(stage.presentations))")
        }
    }

    /// 積んである投入の結末がすべて届くまで待つ (`DroppedWorkRedeliveryTests` と同じ)。
    private func awaitOutcomes(_ gpu: RenderDevice) {
        _ = gpu.droppedWork(after: 0, through: gpu.submissionCount)
    }

    /// 面を 1 つ作り、目録を置いて、`drawing` 枚だけ焼く。
    ///
    /// **同じ区画へ 2 つ作ると、目録は後から置いたほうで上書きされる** — それが子の
    /// 入れ替えで起きることそのものである。
    private func makeSurface(
        in facet: URL, gpu: RenderDevice, drawing frames: Int, windowScale: Float? = nil,
        fullScreenDisplay: SharedFrameSurface.FullScreenDisplay? = nil
    ) throws -> SharedFrameSurface {
        let shared = try SharedFrameSurface(
            gpu: gpu, width: 32, height: 32, windowScale: windowScale,
            fullScreenDisplay: fullScreenDisplay, at: facet)
        try shared.publishManifest()
        // **更新時刻を必ず動かす。** 見張りは時刻が変わったときだけ読み直すので、同じ刻みに
        // 収まると 2 つ目の目録を読まない (``WatchedFile``)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: facet.appendingPathComponent(SharedFrameSurface.manifestName).path)
        for frame in 0..<frames { try draw(shared, frame: frame + 1, gpu: gpu) }
        return shared
    }

    /// 面へ 1 枚焼いて名乗らせる。**中身は何でもよい** — 見ているのは枚数が上がることである。
    ///
    /// **控えも名乗らせる。** 書き手の公開は 1 枚遅れる (#748) ので、書いただけでは読み手から
    /// 見えない — ここが見ているのは読み手の乗り換えであって、書き手の遅れ方ではない。
    private func draw(
        _ shared: SharedFrameSurface, frame: Int, gpu: RenderDevice, width: Int = 32,
        height: Int = 32, pointerLock: Bool = false, cursorHidden: Bool = false,
        numbers: FrameNumbers? = nil, selection: SelectionBroker.Request? = nil
    ) throws {
        let source = try RenderTarget(gpu: gpu, width: width, height: height)
        try source.fill(with: .linear(red: 0, green: 0, blue: 0))
        let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        try shared.write(
            source, using: presenter,
            numbers: numbers ?? SharedFrameSurfaceTests.numbers(frame: frame),
            pointerLock: pointerLock, cursorHidden: cursorHidden, selection: selection)
        // 名乗りは焼きの結末を見てからなので、結末が届くのを待ってから名乗らせる (#2735)
        awaitOutcomes(gpu)
        try shared.publishPending()
    }
}
