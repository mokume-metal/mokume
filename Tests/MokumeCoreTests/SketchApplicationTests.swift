// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import Testing

@testable import MokumeCore

/// スケッチが自分で持つ窓 ([#714](https://github.com/mokume-metal/mokume/issues/714))。
///
/// **窓の寿命を、窓自身に決めさせない。** 素の `NSWindow` の既定は「閉じたら自分を解放する」
/// なので、こちらが強い参照を持ったまま閉じられると、参照の指す先が消える。以後その参照を
/// 触るのは未定義で、**症状は原因から遠いところにしか出ない** — 隣の ``SharedFrameStage``
/// では検査の走り終わりでの落下 (signal 11) として出た
/// ([#705](https://github.com/mokume-metal/mokume/issues/705))。
///
/// **戻し忘れを見る trait (``SignalStateKept``) は付けない。** 付けると、本体の検査を全部
/// 回したときに走者が要約を残さずに消えた (3 回中 3 回・外すと 2 回とも通った・#1937)。
/// 原因は分かっていない (#1527 の材料)。この suite で旗を立てる検査は、それぞれ
/// ``SignalState`` で控えて戻す。
@Suite(
    "スケッチの窓",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct SketchApplicationTests {
    /// 何も描かないスケッチ。窓を開くのに要るのは大きさだけなので、既定のままでよい。
    private final class Blank: Sketch {}

    /// 組む。**終わりの行き先は、呼ばれたら赤を記録する口へ差し替える** ([#1937])。
    ///
    /// 既定の口 (`terminate(nil)`) は、run loop を回していない検査のプロセスをその場で
    /// `exit(0)` させる。この口へは 2 つの経路から来る (``SketchApplication/pollStopSignal()``)。
    /// 旗 `sketchStopRequested` が残っていたときと、道具が居なくなった (標準入力の管が畳まれた)
    /// と読んだときである。どちらでも、拾った検査 (駆動源の代わりに `displayLinkFired()` を
    /// 叩くもの・繋いだ駆動源が鳴るもの) が走者ごと緑のまま消える。終わりを数える検査は、
    /// 自分の口で上書きする。
    ///
    /// [#1937]: https://github.com/mokume-metal/mokume/issues/1937
    private func makeApplication(_ sketch: any Sketch) throws -> SketchApplication {
        let application = try SketchApplication(sketch: sketch, gpu: RenderDevice())
        application.onStopSignal = {
            Issue.record(
                """
                終わりを頼んだ — 検査は合図を送っていないので、旗 sketchStopRequested が残っていたか、\
                道具が居なくなった (標準入力の管が畳まれた) と読んだ
                """)
        }
        return application
    }

    /// 毎フレームの `time` と `deltaTime` を控えるスケッチ。
    private final class Timed: Sketch {
        nonisolated(unsafe) static var seen: [(time: Float, deltaTime: Float)] = []
        func draw() { Self.seen.append((time, deltaTime)) }
    }

    /// **窓の経路は、表示のリフレッシュが運んだ予定の時刻を、その枚の時刻にする** ([#2390])。
    ///
    /// 駆動源 (`displayLinkFired(at:)`) が持ち主へ運んだ時刻が、ランタイムの時計へ届く区間を見る。
    /// 時刻は実時間 (`CACurrentMediaTime()`) より先の等間隔の列にして、コールバックの時点 (いまの時刻) が
    /// 時計へ入ると食い違うようにする。
    ///
    /// [#2390]: https://github.com/mokume-metal/mokume/issues/2390
    @Test("窓の経路の time と deltaTime は、表示の予定の時刻の間隔で進む")
    func theWindowAdvancesByTheDisplayTime() throws {
        Timed.seen = []
        let application = try makeApplication(Timed())
        defer { application.willTerminate() }
        let step = 1.0 / 60
        let start = CACurrentMediaTime() + 1000
        // 4 枚目の前で 1 刻み飛ぶ
        let targets = [0, 1, 2, 3, 5, 6].map { start + Double($0) * step }
        for target in targets { application.displayLinkFired(at: target) }
        #expect(Timed.seen.count == targets.count)
        for (index, row) in Timed.seen.enumerated() {
            #expect(row.time == Float(targets[index] - targets[0]), "\(index + 1) 枚目の time")
            let expected = index == 0 ? step : targets[index] - targets[index - 1]
            #expect(row.deltaTime == Float(expected), "\(index + 1) 枚目の deltaTime")
        }
    }

    /// **閉じた窓を、閉じた後に触る。**
    ///
    /// 窓を閉じるとアプリケーションは終わりに向かうが、即死ではない。加えてフレームの
    /// 駆動源は窓ではなく**画面**に紐づいているので
    /// ([#223](https://github.com/mokume-metal/mokume/issues/223))、窓が消えた後も
    /// `step(_:)` は呼ばれ続け、`presentFrame()` から `window?.occlusionState` を触る。
    ///
    /// ## 落ちるのを待つ形にしていない理由
    ///
    /// 閉じた瞬間に解放されるわけではない。実測すると、閉じた直後の窓には AppKit の側から
    /// 数百の参照が付いている — つまり**解放が 1 回余分になったことは、ここでは何も起こさない**。
    /// #705 でそれが signal 11 として出たのは 1008 本を走らせた最後であり、いつ・どこで
    /// 出るかを検査から決められない。
    ///
    /// だから**窓が自分を解放しないこと自体**を見る。これは実装の細部ではなく、この窓が
    /// AppKit と結んでいる約束そのものである。開いて閉じて触るところまでを同じ検査に置くのは、
    /// 約束が実際の経路の窓に掛かっていることと、走り終わりまで生きていることを併せて見るため。
    @Test("窓を閉じても、その後に窓を触る経路が未定義にならない")
    func theWindowOutlivesItsClosing() throws {
        let application = try makeApplication(Blank())
        application.didFinishLaunching()
        defer { application.willTerminate() }

        let window = try #require(application.window)
        #expect(!window.isReleasedWhenClosed)

        window.close()
        #expect(!application.isWindowOnScreen)
    }

    /// **スケッチ自身の窓でも、キーは面へ届く。**
    ///
    /// キーは第一応答者へ配られるので、面がそこに居ない窓では `keyDown` が 1 度も呼ばれず、
    /// 警告も出ない。据え方は道具が出す窓と揃えてあるが ([#963])、揃っていることを人の目に
    /// 委ねると片方だけが直る形になるので、**両方の経路で同じ形の検査を持つ**。
    ///
    /// 合流点ではなく運び先 (`relay`) から見るのは、走らせている入れ物が `private` で
    /// 検査から触れないためである。見たい区間 (窓 → 第一応答者 → 面) はどちらでも同じだけ
    /// 通る。
    ///
    /// [#963]: https://github.com/mokume-metal/mokume/issues/963
    @Test("スケッチの窓へ送ったキーも、面へ届く")
    func keysReachTheSurfaceThroughTheWindow() throws {
        let application = try makeApplication(Blank())
        application.didFinishLaunching()
        defer { application.willTerminate() }

        let window = try #require(application.window)
        let surface = try #require(window.contentView as? SketchSurface)
        var lines: [String] = []
        surface.relay = { lines.append($0) }

        let event = try #require(KeyEventFixture.keyDown(in: window, characters: "a", keyCode: 0))
        window.sendEvent(event)
        #expect(
            lines == [
                InputEvent.keyDown(code: Key(rawValue: 0), characters: "a", isRepeat: false)
                    .wireLine
            ])
    }

    /// **スケッチ自身の窓でも、落としたファイルは面へ届く** ([#3061](https://github.com/mokume-metal/mokume/issues/3061))。
    /// 道具の窓 (`SharedFrameStageTests`) と同じ形で、窓から取り出した面へ落としを渡して運び先まで見る。
    @Test("スケッチの窓へ落としたファイルも、面へ届く")
    func droppedFilesReachTheSurfaceThroughTheWindow() throws {
        let application = try makeApplication(Blank())
        application.didFinishLaunching()
        defer { application.willTerminate() }

        let window = try #require(application.window)
        let surface = try #require(window.contentView as? SketchSurface)
        #expect(surface.registeredDraggedTypes.contains(.fileURL), "ファイルを受けるよう登録されていない")
        var lines: [String] = []
        surface.relay = { lines.append($0) }
        let center = surface.convert(NSPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: nil)
        let dragging = FakeDraggingInfo.files(["/tmp/a.png", "/tmp/b.png"], at: center)
        #expect(surface.performDragOperation(dragging))
        let raw = try JSONDecoder().decode(
            RawInputEvent.self, from: Data(try #require(lines.first).utf8))
        guard case .fileDropped(let paths, let x, let y)? = raw.event else {
            Issue.record("落としではない: \(lines)")
            return
        }
        #expect(lines.count == 1 && paths == ["/tmp/a.png", "/tmp/b.png"])
        // 面の真ん中を落とした。描く大きさ (既定は 960x540) の真ん中に写る
        #expect(abs(x - 480) < 1 && abs(y - 270) < 1, "(\(x), \(y))")
    }

    /// `setup()` で `selectInput` を頼む (`Task` から) スケッチ。
    private final class SelectAsker: Sketch {
        var result: String??
        func setup() {
            Task { result = .some(await selectInput("pick")) }
        }
    }

    /// **スケッチ自身の窓は、頼まれたファイルを選ばせるダイアログを自分の窓に出し、結果を同じ形の出来事にして
    /// 自分の合流点へ積む** ([#3062](https://github.com/mokume-metal/mokume/issues/3062))。同じ頼みを出し直さず、
    /// 結果が当たって頼みが消えたら、出していたダイアログを閉じる。
    @Test("スケッチの窓は頼まれた選ばせるダイアログを 1 度だけ出し、結果で待ちを終える")
    func theWindowShowsTheSelectionAndEndsTheWait() async throws {
        let sketch = SelectAsker()
        let application = try makeApplication(sketch)
        let picker = FakeFilePicker()
        application.filePicker = picker
        application.didFinishLaunching()
        defer { application.willTerminate() }

        #expect(await eventually { application.displayLinkFired(); return !picker.shown.isEmpty })
        #expect(picker.shown.map(\.prompt) == ["pick"], "頼みの窓に出ていない")
        application.displayLinkFired()
        #expect(picker.shown.count == 1, "同じ頼みを出し直した")
        #expect(sketch.result == nil)

        picker.answer(0, "/tmp/a.csv")
        #expect(await eventually { application.displayLinkFired(); return sketch.result != nil })
        #expect(sketch.result == .some("/tmp/a.csv"), "結果で待ちが終わらない")
        application.displayLinkFired()
        #expect(picker.shown.count == 1, "終わった頼みをまた出した")
    }

    /// **窓が key でなくなったら、押していたキーを離した扱いにする** (#2443)。退いている間に
    /// 離したキーは窓へ届かないので、流さないと押されたまま残る。
    @Test("窓が退く知らせで、押していたキーの解放が流れる")
    func resigningKeyReleasesHeldKeys() throws {
        let application = try makeApplication(Blank())
        application.didFinishLaunching()
        defer { application.willTerminate() }

        let window = try #require(application.window)
        let surface = try #require(window.contentView as? SketchSurface)
        var lines: [String] = []
        surface.relay = { lines.append($0) }

        window.sendEvent(
            try #require(KeyEventFixture.keyDown(in: window, characters: "\u{F703}", keyCode: 124)))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(
            lines == [
                InputEvent.keyDown(code: .arrowRight, characters: "\u{F703}", isRepeat: false)
                    .wireLine,
                InputEvent.keyUp(code: .arrowRight).wireLine,
            ])
    }

    /// **同じ窓の中で第一応答者が面から移っても離す** (#2443 の兄弟)。窓は key のままなので、
    /// 退く知らせは来ず、押していたキーの解放は移った先へ配られる。
    @Test("第一応答者が面から移ると、押していたキーの解放が流れる")
    func losingFirstResponderReleasesHeldKeys() throws {
        let application = try makeApplication(Blank())
        application.didFinishLaunching()
        defer { application.willTerminate() }

        let window = try #require(application.window)
        let surface = try #require(window.contentView as? SketchSurface)
        var lines: [String] = []
        surface.relay = { lines.append($0) }

        window.sendEvent(
            try #require(KeyEventFixture.keyDown(in: window, characters: "a", keyCode: 0)))
        #expect(window.makeFirstResponder(nil))
        #expect(lines.last == InputEvent.keyUp(code: .a).wireLine)
        window.makeFirstResponder(surface)
    }

    /// 退いて離した扱いにした釦の、本物の解放は流さない。押した窓は解放も受け取るので、
    /// 流すと `mouseReleased()` が 2 度呼ばれる (#2443 の反証の指摘 4)。
    @Test("退いて離した扱いにした釦の、本物の解放は流さない")
    func doesNotReleaseAButtonTwice() throws {
        let application = try makeApplication(Blank())
        application.didFinishLaunching()
        defer { application.willTerminate() }

        let window = try #require(application.window)
        let surface = try #require(window.contentView as? SketchSurface)
        var lines: [String] = []
        surface.relay = { lines.append($0) }

        let center = NSPoint(x: surface.bounds.midX, y: surface.bounds.midY)
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: surface.convert(center, to: nil), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1))
        }
        surface.mouseDown(with: try mouse(.leftMouseDown))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        surface.mouseUp(with: try mouse(.leftMouseUp))
        // 押し直した後の解放は流す
        surface.mouseDown(with: try mouse(.leftMouseDown))
        surface.mouseUp(with: try mouse(.leftMouseUp))

        let kinds = lines.compactMap { line in
            ["mouseDown", "mouseUp"].first { line.contains("\"\($0)\"") }
        }
        #expect(kinds == ["mouseDown", "mouseUp", "mouseDown", "mouseUp"])

        // 退いた後に本物の解放が来ないまま押し直したら (窓の外で離した、など)、次の解放は流す
        lines.removeAll()
        surface.mouseDown(with: try mouse(.leftMouseDown))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        surface.mouseDown(with: try mouse(.leftMouseDown))
        surface.mouseUp(with: try mouse(.leftMouseUp))
        let again = lines.compactMap { line in
            ["mouseDown", "mouseUp"].first { line.contains("\"\($0)\"") }
        }
        #expect(again == ["mouseDown", "mouseUp", "mouseDown", "mouseUp"])
    }

    /// **AppKit は ⌘ を伴う keyUp を窓へ配らない** (#2435)。アプリへ送った 1 件が、面の
    /// 監視を通って解放として流れることを見る。窓へ直に送る (`window.sendEvent`) と、落とす
    /// 区間 (`NSApplication.sendEvent(_:)`) を飛ばしてしまう。
    @Test("⌘ を押したままの keyUp も、面へ届く")
    func commandKeyUpReachesTheSurface() throws {
        let application = try makeApplication(Blank())
        application.didFinishLaunching()
        defer { application.willTerminate() }

        let window = try #require(application.window)
        let surface = try #require(window.contentView as? SketchSurface)
        var lines: [String] = []
        surface.relay = { lines.append($0) }

        let keyUp = try #require(
            NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "s",
                charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        NSApplication.shared.sendEvent(keyUp)
        #expect(lines == [InputEvent.keyUp(code: .s).wireLine])
    }

    // MARK: - 最後の窓が閉じたときに終わるか (#1102)

    /// 区画を 1 つ作って渡す。後片付けまで面倒を見る。
    private func withFacet<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-viewport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    /// **窓を 1 枚も開かずに見る。** `didFinishLaunching()` を呼ばないので、この 2 本は
    /// AppKit の窓を建てない — 見たいのは判定であって、窓の建ち方ではない。
    ///
    /// 名乗り (``SketchPresence``) を実際に出して確かめる形は採れない。出せば走らせるたびに
    /// メニューバーへ物が増える (#473 の理由で、名乗り自体は検査から出さない)。
    @Test("窓を道具が持つ経路では、最後の窓が閉じてもスケッチは終わらない")
    func theSketchOutlivesTheLastWindowWhenTheToolOwnsIt() throws {
        try withFacet { facet in
            let application = try makeApplication(Blank())
            defer { application.willTerminate() }
            // 管は検査の側で張る — 既定のままだと、検査を走らせている標準入力を読みに行く
            let pipe = Pipe()
            defer { try? pipe.fileHandleForWriting.close() }
            application.toolInput = pipe.fileHandleForReading.fileDescriptor
            // 窓を持つ道具に起こされた子と同じ形 (#2028)
            application.resolveOutlet(at: facet, owner: "mokume watch")

            let delegate = SketchApplicationDelegate(application: application)
            #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
        }
    }

    /// **窓の経路は動かさない。** 作品の窓の × が作品を終えることは ADR-0032 の追補
    /// (#826) が決めており、#1102 が触ってよいのは窓を持たない側だけである。
    @Test("自分の窓を持つ経路では、最後の窓が閉じたらスケッチも終わる")
    func theSketchEndsWithItsOwnLastWindow() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-viewport-\(UUID().uuidString)", isDirectory: true)
        let application = try makeApplication(Blank())
        defer { application.willTerminate() }
        // 区画が無いので、窓を持つ道具に起こされていても出口は窓のまま
        application.resolveOutlet(at: missing, owner: "mokume watch")

        let delegate = SketchApplicationDelegate(application: application)
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
    }

    // MARK: - × を押した人に確かめる (#1120)

    /// 検査で使う問い。**中身は問わない** — 見ているのは言葉ではなく経路である。
    private static let question = CloseQuestion(
        message: "Quit?", detail: "It stops.", confirm: "Quit", cancel: "Keep running")

    /// 窓の × を押す。**中継まで含めて訊く** (`SharedFrameStageTests` と同じ形) — 台を直に
    /// 呼ぶと、delegate を据える配線が外れたことに気付けない。
    ///
    /// delegate が据わっていない窓は AppKit の既定でそのまま閉じるので `true` を返す。
    private func asksToClose(_ application: SketchApplication) throws -> Bool {
        let window = try #require(application.window)
        guard let delegate = window.delegate else { return true }
        return try #require(delegate.windowShouldClose?(window))
    }

    /// **道具が起こしたのでなければ、何も足さない。** 直に走らせたスケッチと束ねた `.app`
    /// は、いままでどおり × で終わる ([ADR-0032] 決定 1 の「作品は道具に依存しない」)。
    @Test("合図が無ければ、× はそのまま閉じる")
    func closesWithoutTheSignal() throws {
        let application = try makeApplication(Blank())
        application.closeQuestion = nil
        application.didFinishLaunching()
        defer { application.willTerminate() }

        #expect(try #require(application.window).delegate == nil, "問いを持たない窓が受け口を持つ")
        #expect(try asksToClose(application))
    }

    /// **× を押した瞬間には閉じない** (#1120)。窓はこの経路の唯一の出口なので、閉じれば
    /// 制作中の作品がそのまま終わる。
    @Test("合図があれば、× ではまだ閉じず、問いが出る")
    func asksInsteadOfClosing() throws {
        let application = try makeApplication(Blank())
        application.closeQuestion = Self.question
        var asked: CloseQuestion?
        application.presentQuestion = { question, _, _ in asked = question }
        application.didFinishLaunching()
        defer { application.willTerminate() }

        #expect(try !asksToClose(application), "問いを出す前に閉じている")
        #expect(asked?.confirm == Self.question.confirm)
    }

    /// **確定するまで終わらせない。** 取り消したのに終わらせると、続けるつもりで押した人の
    /// 作品が止まる。
    @Test("終えると答えたときだけ、スケッチを終わらせる")
    func endsOnlyWhenConfirmed() throws {
        for confirmed in [true, false] {
            let application = try makeApplication(Blank())
            var ended = 0
            application.closeQuestion = Self.question
            application.presentQuestion = { _, _, answer in answer(confirmed) }
            application.onCloseConfirmed = { ended += 1 }
            application.didFinishLaunching()
            defer { application.willTerminate() }

            #expect(try !asksToClose(application))
            #expect(ended == (confirmed ? 1 : 0))
        }
    }

    // MARK: - 終わるときに、後始末を塞がずに待つ (#978)

    /// 最初のフレームで動画を撮り始め、止めないスケッチ。行き先は検査ごとに差し替える。
    private final class Recording: Sketch {
        nonisolated(unsafe) static var path = ""

        var settings: SketchSettings { SketchSettings(width: 64, height: 48, frameRate: 60) }
        func draw() {
            if frameCount == 1 { beginRecord(Self.path) }
        }
    }

    /// **いつもの終わり方は変えない。** 待つものが無いのに返事を後回しにすると、終わるたびに
    /// run loop を 1 周余計に回すことになる。
    @Test("何も書き出していなければ、その場で終わってよいと答える")
    func terminatesAtOnceWithNothingToWaitFor() throws {
        let application = try makeApplication(Blank())
        var replies = 0
        application.replyToTermination = { replies += 1 }
        defer { application.willTerminate() }

        let delegate = SketchApplicationDelegate(application: application)
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateNow)
        application.pollTermination()
        #expect(replies == 0, "その場で終わると答えたのに、後からも返事をした")
    }

    /// **撮っている最中に終わるなら、main を塞がずに閉じ終えるのを待たせる** ([#978])。
    ///
    /// 塞いで待っていれば、問いに答える時点で閉じ終えているので `.terminateNow` が返る —
    /// それは `AVAssetWriter.finishWriting` の間 main を塞いでいたということである。
    /// `.terminateLater` の後に、見に来た回で 1 回だけ返事が出ることを見る。
    ///
    /// 最初の答えが「後で」になるのは、閉じた合図までに配ったばかりの 1 枚の符号化と最終化が
    /// 要るからである (幅の実測は `RecordMovieTests` の「閉じ終えるのを待っている間は」)。
    ///
    /// [#978]: https://github.com/mokume-metal/mokume/issues/978
    @Test(
        "撮っている最中なら、閉じ終えるまで返事を待たせ、済んだら 1 回だけ終わってよいと返す",
        .enabled(if: MovieFile.isAvailable, "この機械には ProRes 4444 の符号化器が無い"))
    func waitsForTheMovieWithoutBlocking() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-quit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        Recording.path = directory.appendingPathComponent("quit.mov").path

        let application = try makeApplication(Recording())
        var replies = 0
        var closedAtReply: [Bool] = []
        application.replyToTermination = {
            replies += 1
            closedAtReply.append(movieHasClosed(Recording.path))
        }
        defer { application.willTerminate() }
        for _ in 0..<3 { application.displayLinkFired() }

        let delegate = SketchApplicationDelegate(application: application)
        #expect(
            delegate.applicationShouldTerminate(.shared) == .terminateLater,
            "閉じ終えるまで塞いでから答えている")
        #expect(replies == 0, "閉じ終える前に返事をした")

        // 検査は run loop を回さないので、Timer に代わって見に来る
        try #require(
            pollUntilSettled(within: MovieWriter.closeLimitSeconds + 10) {
                application.pollTermination()
                return replies > 0
            },
            "閉じる期限を過ぎても返事が無い")
        application.pollTermination()
        #expect(replies == 1, "返事が重なった")
        // **返事の直後にプロセスは消える。** その時点で閉じ終えていなければ、再生できない
        // ファイルが残る
        #expect(closedAtReply == [true], "閉じ終える前に、終わってよいと返した")
    }

    /// **終わりに向かっている間の × は問わずに閉じる** ([#978])。
    ///
    /// 問いの先は `terminate(_:)` で、後始末を待っている間にそれを重ねると、AppKit は
    /// 問い直さずに待ちを飛ばして終わる (実測)。
    ///
    /// [#978]: https://github.com/mokume-metal/mokume/issues/978
    @Test("終わりに向かっている間の × では問わない")
    func doesNotAskWhileTerminating() throws {
        let application = try makeApplication(Blank())
        var asked = 0
        application.closeQuestion = Self.question
        application.presentQuestion = { _, _, _ in asked += 1 }
        application.replyToTermination = {}
        application.didFinishLaunching()
        defer { application.willTerminate() }

        _ = SketchApplicationDelegate(application: application).applicationShouldTerminate(.shared)

        #expect(try asksToClose(application))
        #expect(asked == 0, "終わりに向かっている間に問いを出した")
    }

    /// **問いが出ている間に終わりが始まったら、答えで終わりを重ねない** ([#978])。
    ///
    /// シートは窓にだけ掛かるので、出ている間も Dock からの終了は届く。そのまま「終える」の
    /// 答えで `terminate(_:)` を呼ぶと、待っている後始末が飛ばされる。
    ///
    /// [#978]: https://github.com/mokume-metal/mokume/issues/978
    @Test("問いが出ている間に終わりが始まったら、終えるという答えで終わりを重ねない")
    func anAnswerDoesNotTerminateAgain() throws {
        let application = try makeApplication(Blank())
        var answer: ((Bool) -> Void)?
        var ended = 0
        application.closeQuestion = Self.question
        application.presentQuestion = { _, _, reply in answer = reply }
        application.onCloseConfirmed = { ended += 1 }
        application.replyToTermination = {}
        application.didFinishLaunching()
        defer { application.willTerminate() }

        #expect(try !asksToClose(application))
        _ = SketchApplicationDelegate(application: application).applicationShouldTerminate(.shared)
        let reply = try #require(answer, "問いが出ていない")
        reply(true)

        #expect(ended == 0, "終わりに向かっている間に、答えで終わりを重ねた")
    }

    // MARK: - 終わりの合図 (#1219)

    /// **合図を、後始末を待つ経路へ入れる。** 受け口が無かった頃は合図を受けた瞬間に消え、
    /// 撮っていた動画が開けないまま残った ([#1219])。**1 度の合図で 1 度だけ頼む** — 見に来る
    /// のは刻みごとなので、旗を下ろさなければ刻みの数だけ頼む。
    ///
    /// [#1219]: https://github.com/mokume-metal/mokume/issues/1219
    @Test("終わりの合図を受けていたら、終わりを 1 度だけ頼む")
    func asksToEndOnceAfterAStopSignal() throws {
        let kept = SignalState.current()
        defer { kept.restore() }
        sketchStopRequested = 0
        let application = try makeApplication(Blank())
        var ended = 0
        application.onStopSignal = { ended += 1 }
        defer { application.willTerminate() }

        application.pollStopSignal()
        #expect(ended == 0, "合図を受けていないのに、終わりを頼んだ")
        sketchStopRequested = 1
        application.pollStopSignal()
        application.pollStopSignal()
        #expect(ended == 1)
    }

    /// **返事を待たせている間に `terminate(_:)` を重ねない。** 重ねると AppKit は返事を待たずに
    /// 終わらせ、待っていた後始末 (動画を閉じる) が飛ばされる ([#1219])。
    ///
    /// [#1219]: https://github.com/mokume-metal/mokume/issues/1219
    @Test("終わりに向かっている間の合図では、終わりを重ねない")
    func aStopSignalDoesNotTerminateAgain() throws {
        let kept = SignalState.current()
        defer { kept.restore() }
        sketchStopRequested = 0
        let application = try makeApplication(Blank())
        var ended = 0
        application.onStopSignal = { ended += 1 }
        application.replyToTermination = {}
        defer { application.willTerminate() }

        _ = SketchApplicationDelegate(application: application).applicationShouldTerminate(.shared)
        sketchStopRequested = 1
        application.pollStopSignal()

        #expect(ended == 0, "終わりに向かっている間に、合図で終わりを重ねた")
        #expect(!StopSignals.takeRequest(), "受け流した合図が、旗に残っている")
    }

    // MARK: - 起こした道具が居なくなったとき (#1427)

    /// **道具が居なくなったら、終わりの合図と同じ経路で終わる。** 窓は道具のものなので一緒に
    /// 消えており、残った子には人が止める入口が無い ([#1427])。
    ///
    /// [#1427]: https://github.com/mokume-metal/mokume/issues/1427
    @Test("起こした道具が居なくなったら、終わりを頼む")
    func asksToEndWhenTheDriverIsGone() throws {
        let kept = SignalState.current()
        defer { kept.restore() }
        sketchStopRequested = 0
        let application = try makeApplication(Blank())
        var ended = 0
        var gone = false
        application.onStopSignal = { ended += 1 }
        application.driverDeparted = { gone }
        defer { application.willTerminate() }

        application.pollStopSignal()
        #expect(ended == 0, "道具が居るのに、終わりを頼んだ")
        gone = true
        application.pollStopSignal()
        #expect(ended == 1)
    }

    /// **合図と管が同じ刻みに来ても、頼むのは 1 度である。** 両方の印を下ろすので、次の刻みで
    /// 読み残した側が重ねて頼むこともない。
    @Test("合図と道具の消失が重なっても、終わりは 1 度だけ頼む")
    func asksOnceWhenBothArrive() throws {
        let kept = SignalState.current()
        defer { kept.restore() }
        sketchStopRequested = 0
        let application = try makeApplication(Blank())
        var ended = 0
        var departures = [true]
        application.onStopSignal = { ended += 1 }
        application.driverDeparted = { departures.popLast() ?? false }
        defer { application.willTerminate() }

        sketchStopRequested = 1
        application.pollStopSignal()
        application.pollStopSignal()

        #expect(ended == 1)
        #expect(departures.isEmpty, "合図があった刻みで、道具の消失を読み残した")
    }

    /// **終わりに向かっている間は重ねない** (``aStopSignalDoesNotTerminateAgain()`` と同じ理由)。
    @Test("終わりに向かっている間に道具が居なくなっても、終わりを重ねない")
    func theDriverLeavingDoesNotTerminateAgain() throws {
        let kept = SignalState.current()
        defer { kept.restore() }
        sketchStopRequested = 0
        let application = try makeApplication(Blank())
        var ended = 0
        application.onStopSignal = { ended += 1 }
        application.driverDeparted = { true }
        application.replyToTermination = {}
        defer { application.willTerminate() }

        _ = SketchApplicationDelegate(application: application).applicationShouldTerminate(.shared)
        application.pollStopSignal()

        #expect(ended == 0, "終わりに向かっている間に、道具の消失で終わりを重ねた")
    }

    /// **検査のプロセスは道具から起こされていないので、既定の口は何も言わない。** 直に走らせた
    /// スケッチの標準入力 (端末) が閉じても終わらないことは、ここから従う。
    @Test("道具から起こされていなければ、居なくなったとは言わない")
    func notDrivenMeansNeverDeparted() throws {
        let application = try makeApplication(Blank())
        defer { application.willTerminate() }
        #expect(!application.driverDeparted())
    }
}
