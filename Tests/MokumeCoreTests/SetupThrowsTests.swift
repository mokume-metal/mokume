// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// `setup()` は `throws` で書ける ([#2401])。
///
/// 約束は 3 つ。**投げない `func setup()` はこれまでどおり組めて、呼ばれる** / **投げたら、`draw()` を 1 度も呼ばずに
/// 起動の失敗として止まり、失敗の全文が運ばれる** / **どの経路 (`SketchRuntime` を直に回す・書き出す・窓) でも同じ
/// 失敗で止まる**。
///
/// [#2401]: https://github.com/mokume-metal/mokume/issues/2401
@Suite(
    "setup() が投げたとき",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SetupThrowsTests {
    /// 投げない `func setup()` を書いた、これまでの形のスケッチ。
    final class Quiet: Sketch {
        var settings = SketchSettings(width: 32, height: 32)
        var setups = 0
        var draws = 0
        init() {}
        func setup() { setups += 1 }
        func draw() {
            draws += 1
            background(20)
        }
    }

    /// 読み込みの失敗を `try` で通すスケッチ。`var cat: Image!` と `cat = try loadImage(…)` の形。
    final class Missing: Sketch {
        var settings = SketchSettings(width: 32, height: 32)
        var cat: Image!
        /// 投げる前に、読み込みの失敗そのものから取った文面。運ばれた文面と突き合わせる
        var original: String?
        var draws = 0
        init() {}
        func setup() throws {
            do {
                cat = try loadImage("assets/does-not-exist.png")
            } catch {
                original = "\(error)"
                throw error
            }
        }
        func draw() { draws += 1 }
    }

    /// 型を問わない — 資源ごとの失敗でなくても、自分の型で投げてよい。
    struct Custom: Error, CustomStringConvertible {
        var description: String { "my own failure\nfix it and run again" }
    }

    final class Plain: Sketch {
        var settings = SketchSettings(width: 32, height: 32)
        var draws = 0
        init() {}
        func setup() throws { throw Custom() }
        func draw() { draws += 1 }
    }

    /// 1 枚進めて、投げた失敗を返す。
    private func failure(of runtime: SketchRuntime) -> RenderFailure? {
        do {
            try runtime.advance()
            return nil
        } catch {
            return error
        }
    }

    // MARK: - 投げない setup はこれまでどおり

    @Test("投げない func setup() は組めて、1 度だけ呼ばれ、draw() も呼ばれる")
    func aNonThrowingSetupStillRuns() throws {
        let sketch = Quiet()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        try runtime.advance()
        try runtime.advance()
        #expect(sketch.setups == 1, "setup() が 1 度だけ呼ばれていない: \(sketch.setups)")
        #expect(sketch.draws == 2)
        #expect(runtime.setupFailure == nil)
    }

    // MARK: - 投げたら止まる

    @Test("setup() が loadImage の失敗を投げたら、draw() を呼ばずに止まり、失敗の全文を運ぶ")
    func aThrownLoadFailureStopsTheSketch() throws {
        let sketch = Missing()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        let first = try #require(failure(of: runtime), "setup() が投げたのに、フレームが進んだ")
        let original = try #require(sketch.original, "loadImage が失敗していない")
        #expect(original.contains("does-not-exist.png"), "検体が読み込みの失敗を起こしていない: \(original)")
        #expect(first == .setupFailed(reason: original), "投げた失敗の全文が運ばれていない: \(first)")
        #expect(sketch.draws == 0, "draw() が呼ばれた")
        #expect(runtime.frameCount == 0, "時計が進んだ")

        // 呼び直しても同じ失敗が返り、draw() は 1 度も呼ばれない
        #expect(failure(of: runtime) == first)
        #expect(sketch.draws == 0)
    }

    @Test("起動の失敗の文面は、名乗りと失敗の全文 (次にすることまで) を持つ")
    func theStartupTextCarriesTheWholeFailure() throws {
        let sketch = Missing()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        let thrown = try #require(failure(of: runtime))
        let original = try #require(sketch.original)
        let text = startupFailureText(thrown)
        #expect(text.hasPrefix("The sketch could not start.\n"))
        #expect(text.contains(original), "失敗の全文が文面に入っていない")
        #expect(text.split(separator: "\n").count >= 3, "次にすることまで書かれていない")
    }

    @Test("投げる型は問わない。自分の型で投げた失敗の文面も運ばれる")
    func anyErrorTypeIsCarried() throws {
        let sketch = Plain()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        #expect(failure(of: runtime) == .setupFailed(reason: Custom().description))
        #expect(sketch.draws == 0)
    }

    @Test("1 枚だけ書き出す口も、同じ失敗で止まり、ファイルを書かない")
    func renderingOneFrameStopsTheSameWay() throws {
        let sketch = Missing()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        let url = TestScratch.path("mokume-setup-throws", pathExtension: "png")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: RenderFailure.self) { try runtime.renderFrame(to: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path), "止まったのにファイルを書いた")
        #expect(sketch.draws == 0)
    }

    // MARK: - 窓の経路

    @Test("窓の経路は、起動の失敗として 1 を終了コードに終わり、draw() を呼ばない")
    func theApplicationStopsWithStatusOne() throws {
        let sketch = Missing()
        let application = try SketchApplication(sketch: sketch, gpu: RenderDevice())
        var statuses: [Int32] = []
        application.exitProcess = { statuses.append($0) }
        application.didFinishLaunching()
        for _ in 0..<3 { application.displayLinkFired() }
        #expect(statuses == [1], "終了コードが 1 を 1 度だけ渡していない: \(statuses)")
        #expect(sketch.draws == 0, "draw() が呼ばれた")
    }

    // MARK: - どの枝からも通り抜けない (反証 1)

    /// `setup()` で `noLoop()` を呼んでから投げるスケッチ (Issue の想定例の 1 行目の形)。止めた後に入力を数える。
    final class StopsThenThrows: Sketch {
        var settings = SketchSettings(width: 32, height: 32)
        var draws = 0
        var keys = 0
        init() {}
        func setup() throws {
            noLoop()
            throw Custom()
        }
        func draw() { draws += 1 }
        func keyPressed() { keys += 1 }
    }

    @Test("setup() で noLoop() を呼んでから投げても、以後のフレームはずっと同じ失敗を投げ、入力を配らない")
    func aStoppedSketchThatThrewKeepsThrowing() throws {
        let sketch = StopsThenThrows()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        let first = try #require(failure(of: runtime))
        #expect(first == .setupFailed(reason: Custom().description))
        for _ in 0..<3 {
            runtime.input.enqueue(.keyDown(code: .space, characters: " ", isRepeat: false))
            #expect(failure(of: runtime) == first, "止めた後のフレームが失敗を投げない")
        }
        #expect(sketch.keys == 0, "失敗したスケッチへ入力が配られた")
        #expect(sketch.draws == 0)

        // 始めてから 1 枚も進めずに書き出しても、ファイルを書かない
        let url = TestScratch.path("mokume-setup-throws", pathExtension: "png")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: RenderFailure.self) { try runtime.renderFrame(to: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// 観測のある往復。`Talker` の代わりに、`setup()` が投げる検体を使う。
    private func report(
        _ body: String, in facet: URL, with runtime: SketchRuntime
    ) throws -> (warnings: [String], complete: Bool?, thrown: RenderFailure?) {
        try AtomicFile.write(
            Data(#"{"id":"o\#(UUID().uuidString.prefix(6))"\#(body)}"#.utf8),
            to: facet.appendingPathComponent("request.json"))
        let thrown = failure(of: runtime)
        let data = try Data(contentsOf: facet.appendingPathComponent("report.json"))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return (parsed["warnings"] as? [String] ?? [], parsed["complete"] as? Bool, thrown)
    }

    private func makeFacet() throws -> URL {
        let directory = try TestScratch.directory("mokume-setup-throws-facet")
        return directory
    }

    @Test("時刻を指定した観測は、setup() が投げたなら断り、断りの文に投げた理由の最初の行が入る。2 度目以降も同じ")
    func aTimedObservationNamesTheSetupFailure() throws {
        let facet = try makeFacet()
        let sketch = Plain()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: nil, now: { 0 },
            observer: FrameObserver(directory: facet))
        for round in 0..<2 {
            let answer = try report(#","time":0.5"#, in: facet, with: runtime)
            let all = answer.warnings.joined(separator: "\n")
            #expect(all.contains("my own failure"), "\(round) 回目: 断りに理由が載っていない: \(all)")
            #expect(answer.complete != true, "\(round) 回目: 撮れたと答えた")
            // **最初のフレームも投げる** (2 回目の反証 4a)。断って返ると、窓の経路は絵を出しに進む
            #expect(
                answer.thrown == .setupFailed(reason: Custom().description),
                "\(round) 回目: 投げずに返った: \(String(describing: answer.thrown))")
        }
        #expect(sketch.draws == 0)
    }

    @Test("外から止められた観測のない一枚描きでも、setup() の失敗を撮れたと答えない")
    func aPausedFirstObservationDoesNotClaimASuccess() throws {
        let facet = try makeFacet()
        let sketch = Plain()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: nil, now: { 0 },
            observer: FrameObserver(directory: facet))
        runtime.pause()
        let answer = try report("", in: facet, with: runtime)
        let all = answer.warnings.joined(separator: "\n")
        #expect(all.contains("my own failure"), "応えに理由が載っていない: \(all)")
        #expect(answer.complete != true, "撮れたと答えた")
        // **最初のフレームも投げる** (2 回目の反証 4b)。投げずに返ると、窓の経路は絵を出しに進む
        #expect(
            answer.thrown == .setupFailed(reason: Custom().description),
            "投げずに返った: \(String(describing: answer.thrown))")
        #expect(sketch.draws == 0)
    }

    @Test("作者が止めた枝 (最初のフレームの前に noLoop()) の観測の一枚描きも、応えた後で投げる")
    func aStoppedFirstObservationThrowsToo() throws {
        let facet = try makeFacet()
        let sketch = Plain()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: nil, now: { 0 },
            observer: FrameObserver(directory: facet))
        runtime.noLoop()
        let answer = try report("", in: facet, with: runtime)
        let all = answer.warnings.joined(separator: "\n")
        #expect(all.contains("my own failure"), "応えに理由が載っていない: \(all)")
        #expect(answer.complete != true, "撮れたと答えた")
        #expect(
            answer.thrown == .setupFailed(reason: Custom().description),
            "投げずに返った: \(String(describing: answer.thrown))")
        #expect(sketch.draws == 0)
    }

    @Test("名乗りのメニューが進めた回に setup() が投げたら、捨てずに窓の経路へ知らせる")
    func presenceReportsTheSetupFailure() throws {
        let sketch = Plain()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: RenderDevice(), clock: nil, now: { 100 })
        var told: [RenderFailure] = []
        runtime.setupFailureHandler = { told.append($0) }
        runtime.advanceForPresence()
        #expect(told == [.setupFailed(reason: Custom().description)], "\(told)")
        #expect(sketch.draws == 0)
    }

    // MARK: - 文面 (反証 2・6)

    /// `LocalizedError` だけを持つ型。`"\(error)"` では構造体のダンプになる。
    struct OnlyLocalized: LocalizedError {
        var errorDescription: String? { "the disk is full" }
        var recoverySuggestion: String? { "free some space and run again" }
    }

    final class Localized: Sketch {
        var settings = SketchSettings(width: 32, height: 32)
        init() {}
        func setup() throws { throw OnlyLocalized() }
    }

    final class Unwritable: Sketch {
        var settings = SketchSettings(width: 32, height: 32)
        init() {}
        func setup() throws { throw ImageWriteFailure.writeFailed(path: "/nowhere/a.png") }
    }

    @Test("文面は Diagnostics の読み方 1 つで、型を問わず全文になる (LocalizedError は説明・次の一手まで)")
    func theFailureTextIsReadInOneOrder() throws {
        let localized = try #require(failure(of: SketchRuntime(sketch: Localized(), gpu: RenderDevice())))
        #expect(
            localized == .setupFailed(reason: "the disk is full\nfree some space and run again"),
            "LocalizedError の説明が運ばれていない: \(localized)")
        let unwritable = try #require(failure(of: SketchRuntime(sketch: Unwritable(), gpu: RenderDevice())))
        guard case .setupFailed(let reason) = unwritable else {
            Issue.record("setupFailed でない: \(unwritable)")
            return
        }
        #expect(reason == "the file could not be written", Comment(rawValue: reason))
    }

    /// 読み込みの失敗が `NSError` のまま届く形 (`String(contentsOf:)`)。
    final class ReadsAFile: Sketch {
        var settings = SketchSettings(width: 32, height: 32)
        init() {}
        func setup() throws {
            _ = try String(contentsOf: URL(fileURLWithPath: "/nonexistent-setup-throws/a.txt"), encoding: .utf8)
        }
    }

    @Test("NSError を投げても、構造体のダンプにならず、Diagnostics の読み方の文になる")
    func anNSErrorFailureIsNotDumped() throws {
        let thrown = try #require(failure(of: SketchRuntime(sketch: ReadsAFile(), gpu: RenderDevice())))
        guard case .setupFailed(let reason) = thrown else {
            Issue.record("setupFailed でない: \(thrown)")
            return
        }
        #expect(!reason.contains("Error Domain="), Comment(rawValue: reason))
        #expect(!reason.contains("UserInfo"), Comment(rawValue: reason))
        #expect(reason == String(cString: strerror(ENOENT)), Comment(rawValue: reason))
    }

    @Test("1 行に削る経路でも、何が起きたかと理由の最初の行が残る")
    func theHeadlineKeepsTheReason() {
        let failure = RenderFailure.setupFailed(reason: "could not read assets/cat.png\ncheck the path")
        #expect(failure.headline == "setup() threw, so the sketch did not start: could not read assets/cat.png")
        #expect(startupFailureText(failure).contains("check the path"), "全文は起動の失敗の文面に残る")
    }

    // MARK: - 差込口 (反証 3)

    final class Opened: Inlet {
        var closes = 0
        func open() throws {}
        func supply() {}
        func close() { closes += 1 }
        var failure: String? { nil }
        var report: SourceReport? { nil }
    }

    struct OpenedPlugin: Plugin {
        let inlet: Opened
        func register(into registry: PluginRegistry) { registry.add(inlet: inlet) }
    }

    final class WithAnInlet: Sketch {
        nonisolated(unsafe) static var inlet = Opened()
        var settings = SketchSettings(width: 32, height: 32)
        var plugins: [any Plugin] { [OpenedPlugin(inlet: Self.inlet)] }
        init() {}
        func setup() throws { throw Custom() }
    }

    @Test("窓の経路は、setup() が投げたら、差込口を閉じてから終わる")
    func theApplicationClosesTheInletsBeforeExiting() throws {
        WithAnInlet.inlet = Opened()
        let inlet = WithAnInlet.inlet
        let application = try SketchApplication(sketch: WithAnInlet(), gpu: RenderDevice())
        var statuses: [Int32] = []
        var closesWhenExiting: [Int] = []
        application.exitProcess = {
            statuses.append($0)
            closesWhenExiting.append(inlet.closes)
        }
        application.didFinishLaunching()
        application.displayLinkFired()
        #expect(statuses == [1])
        #expect(closesWhenExiting == [1], "終わる前に差込口が閉じられていない: \(closesWhenExiting)")
    }
    // MARK: - 起動の失敗を見張りへ渡す (#3169)

    @Test("窓の経路は、setup() が投げたら、終わる前に理由の全文を見張りへ渡す")
    func theApplicationHandsTheReasonOverBeforeExiting() throws {
        let application = try SketchApplication(sketch: Missing(), gpu: RenderDevice())
        var order: [String] = []
        var notes: [String] = []
        application.noteStartFailure = {
            notes.append($0)
            order.append("note")
        }
        application.exitProcess = { _ in order.append("exit") }
        application.didFinishLaunching()
        application.displayLinkFired()
        #expect(order == ["note", "exit"], "理由を渡してから終わっていない: \(order)")
        let note = try #require(notes.first)
        #expect(note.hasPrefix("setup() threw, so the sketch did not start:"), "\(note)")
        #expect(note.count > "setup() threw, so the sketch did not start: ".count, "理由が空: \(note)")
    }

    /// `Sketch.main()` の catch は `exit(1)` で呼べないので、置く処理は 1 つの関数に括ってある。
    @Test("起動の失敗を言う関数は、標準エラーと同じ中身の全文を見張りへ渡す")
    func reportStartFailureHandsTheWholeFailureOver() {
        let failure = RenderFailure.setupFailed(reason: "could not read assets/cat.png\n  detail")
        var notes: [String] = []
        reportStartFailure(failure, note: { notes.append($0) })
        #expect(notes == ["\(failure)"])
        #expect(notes.first?.contains("detail") == true, "全文を渡していない: \(notes)")
    }

    /// 理由が改行で始まる子で、1 行目が名乗りだけになると、1 行に削る経路と見張りの頭の 1 行が理由を落とす。
    @Test("setup() が改行や空白で始まる理由を投げても、1 行目に理由の最初の行が入る")
    func aLeadingNewlineInTheReasonDoesNotEmptyTheFirstLine() {
        let failure = RenderFailure.setupFailed(reason: "\n  could not read assets/cat.png\n")
        let text = "\(failure)"
        #expect(
            text.split(separator: "\n", omittingEmptySubsequences: false).first
                == "setup() threw, so the sketch did not start: could not read assets/cat.png",
            "\(text)")
        #expect(failure.headline == "setup() threw, so the sketch did not start: could not read assets/cat.png")
        #expect(
            "\(RenderFailure.setupFailed(reason: " \n "))" == "setup() threw, so the sketch did not start",
            "空の理由で余計な : が残る")
    }

    // MARK: - 起動中の印を見張りへ渡す (#3222)

    /// 子は `Sketch.main()` の頭で印を置き (`markOwnStarting`)、最初の絵を出したら 1 度だけ消す。見張りは窓の無い見張りと倒れた子について、
    /// 印が残ったまま終わった子を「最初の絵の前に終わった」と読む。
    @Test("最初の絵を出したら、起動中の印を 1 度だけ消す")
    func theFirstFrameClearsTheStartingMark() throws {
        let application = try SketchApplication(sketch: Quiet(), gpu: RenderDevice())
        var events: [String] = []
        application.markFirstFrame = { events.append("first") }
        application.exitProcess = { _ in }
        application.didFinishLaunching()
        #expect(events.isEmpty, "最初の絵の前に印を消した: \(events)")
        application.displayLinkFired()
        application.displayLinkFired()
        application.displayLinkFired()
        #expect(events == ["first"], "印を 1 度だけ消していない: \(events)")
        application.willTerminate()
    }

    @Test("setup() が投げて最初の絵を出せなければ、起動中の印は消さずに終わる")
    func aFailedSetupLeavesTheStartingMark() throws {
        let application = try SketchApplication(sketch: Missing(), gpu: RenderDevice())
        var events: [String] = []
        application.markFirstFrame = { events.append("first") }
        application.noteStartFailure = { _ in }
        application.exitProcess = { _ in events.append("exit") }
        application.didFinishLaunching()
        application.displayLinkFired()
        #expect(events == ["exit"], "印を消した: \(events)")
    }

    // MARK: - 起動中の印の置き場 (WorkDirectory)

    private func makeBase() throws -> (base: URL, facet: URL) {
        let base = try TestScratch.directory("mokume-starting")
        return (base, WorkDirectory.facet(WorkDirectory.buildFacetName, under: base))
    }

    @Test("見張りに起こされた子が、区画 build が在るときだけ、自分の pid で起動中の印を置き、消せる")
    func theStartingMarkIsPlacedByAChildOfTheWatcherAndCleared() throws {
        let (base, facet) = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = WorkDirectory.startingURL(forProcess: 4242, under: facet)

        // 区画が無い場所には作らない (区画の有無は「効かせる」印になりうる)
        WorkDirectory.markStarting(forProcess: 4242, under: base, owner: "mokume watch")
        #expect(!FileManager.default.fileExists(atPath: facet.path), "区画を生やした")

        try FileManager.default.createDirectory(at: facet, withIntermediateDirectories: true)
        // 見張りに起こされていない子 (run・render・手で起こした子) は置かない
        WorkDirectory.markStarting(forProcess: 4242, under: base, owner: nil)
        #expect(!FileManager.default.fileExists(atPath: url.path), "見張りに起こされていない子が置いた")

        WorkDirectory.markStarting(forProcess: 4242, under: base, owner: "mokume watch")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(WorkDirectory.startingURL(forProcess: 4243, under: facet) != url, "pid が名前に入っていない")

        WorkDirectory.clearStarting(forProcess: 4242, under: base)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // 無くても落ちない
        WorkDirectory.clearStarting(forProcess: 4242, under: base)
    }
}
