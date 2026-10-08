// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import Testing

@testable import MokumeCore

/// 画面の読みの見本 ([#2020])。**ディスプレイが何枚でも、どう並んでいても、1 枚の機械で回る。**
///
/// [#2020]: https://github.com/mokume-metal/mokume/issues/2020
enum DisplayReadings {
    /// 手元の内蔵画面 (実測・#2020): 1800×1169 点・2 倍・切り欠き 38 点・使える範囲の上端 1130 点。
    /// 全画面の窓は 1800×1130 点で開いた。
    static let builtIn = Display.Reading(
        screenID: 1, name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1130),
        cameraHousing: 38, scale: 2)
    /// 内蔵画面の左に置いたプロジェクタ (1 倍)。
    static let leftProjector = Display.Reading(
        screenID: 7, name: "Projector",
        frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055),
        cameraHousing: 0, scale: 1)
    /// 右上に置いたモニタ (2 倍)。右のプロジェクタと左端が揃う。
    static let upperRightMonitor = Display.Reading(
        screenID: 5, name: "Studio Display",
        frame: CGRect(x: 1800, y: 1080, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1800, y: 1080, width: 2560, height: 1415),
        cameraHousing: 0, scale: 2)
    /// 右に置いたプロジェクタ (1 倍)。**左と同じ型番** — 名前では見分けられない。
    static let rightProjector = Display.Reading(
        screenID: 9, name: "Projector",
        frame: CGRect(x: 1800, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1800, y: 0, width: 1920, height: 1055),
        cameraHousing: 0, scale: 1)

    /// 4 枚が繋がった机。OS はメニューバーのある画面を先頭に、残りを繋いだ順に並べる。
    static let desk = [builtIn, rightProjector, upperRightMonitor, leftProjector]
}

/// 全画面と、出すディスプレイの選び方 ([#2020])。GPU も窓も要らない — 画面の読みから先は
/// 純粋な関数なので、読みを差し替えて確かめる (ADR-0041 決定 2 の基準 4)。
///
/// [#2020]: https://github.com/mokume-metal/mokume/issues/2020
@Suite("全画面とディスプレイの選び方")
struct FullScreenChoiceTests {
    private let desk = Display.list(from: DisplayReadings.desk)

    // MARK: - 番号の振り方

    /// **1 はメニューバーのある画面で、左端にあるとは限らない。** 2 から先は配置の左から、
    /// 左端が揃えば上から。
    @Test("1 はメニューバーのある画面、2 から先は配置の左から (左端が揃えば上から)")
    func numbersFollowTheArrangement() {
        #expect(desk.map(\.number) == [1, 2, 3, 4])
        #expect(desk.map(\.screenID) == [1, 7, 5, 9])
        #expect(
            desk.map(\.name) == [
                "Built-in Retina Display", "Projector", "Studio Display", "Projector",
            ])
    }

    /// **抜き差しで番号が変わらない** — 同じ顔ぶれ・同じ配置なら、OS が残りをどの順に並べても
    /// (繋いだ順が違っても) 同じ番号になる。
    @Test("繋いだ順が違っても、配置が同じなら同じ番号になる")
    func theOrderOfPluggingDoesNotMatter() {
        let others = [
            DisplayReadings.rightProjector, DisplayReadings.upperRightMonitor,
            DisplayReadings.leftProjector,
        ]
        for order in Self.permutations(others) {
            #expect(
                Display.list(from: [DisplayReadings.builtIn] + order) == desk,
                "繋いだ順 \(order.map(\.screenID))")
        }
    }

    /// **代償の側も固定する。** 間の 1 台が欠けると、後ろの番号が詰まる (説明文が名乗っている)。
    @Test("間の 1 台が欠けると、後ろの番号が 1 つずつ詰まる")
    func aMissingDisplayShiftsTheNumbersAfterIt() {
        let missing = Display.list(from: [
            DisplayReadings.builtIn, DisplayReadings.rightProjector,
            DisplayReadings.upperRightMonitor,
        ])
        #expect(missing.map(\.screenID) == [1, 5, 9])
        #expect(missing.map(\.number) == [1, 2, 3])
    }

    @Test("画面が 1 枚も無ければ、一覧は空")
    func noScreensMakeAnEmptyList() {
        #expect(Display.list(from: []).isEmpty)
    }

    // MARK: - 大きさ

    /// **描く 1 画素が画面の 1 画素に載る** — 点に画素密度を掛ける。切り欠きのある画面は、
    /// 全画面の窓がメニューバーの帯の下に置かれるので、使える範囲の上端まで (実測の 1130 点)。
    @Test("全画面の大きさは点 × 画素密度で、切り欠きのある画面はメニューバーの帯の下まで")
    func theSizeIsTheFullScreenInPixels() {
        let sizes = desk.map { [$0.width, $0.height] }
        #expect(sizes == [[3600, 2260], [1920, 1080], [5120, 2880], [1920, 1080]])
        // 切り欠きの無い画面は、使える範囲 (メニューバーと Dock の帯) に左右されない
        #expect(desk[1].height == 1080)
    }

    // MARK: - 選ぶ

    @Test("繋がっている番号なら、その 1 枚を選ぶ (1 と、いちばん後ろ)")
    func choosesAConnectedDisplay() throws {
        #expect(try Display.choose(1, from: desk).screenID == 1)
        #expect(try Display.choose(4, from: desk).screenID == 9)
    }

    /// **頼み方の誤りと、繋がっていないことを分ける** — 次にすることが違う。
    @Test("1 を割る番号は、番号の誤りとして断る", arguments: [0, -1, Int.min])
    func refusesANumberBelowOne(number: Int) {
        #expect(throws: RenderFailure.invalidDisplay(number)) {
            try Display.choose(number, from: desk)
        }
    }

    @Test("繋がっていない番号は、いまの一覧を添えて断る", arguments: [5, Int.max])
    func refusesADisplayThatIsNotConnected(number: Int) {
        #expect(throws: RenderFailure.displayNotConnected(number, connected: desk)) {
            try Display.choose(number, from: desk)
        }
    }

    @Test("画面が 1 枚も無ければ、1 も繋がっていないとして断る")
    func refusesEvenOneWithoutScreens() {
        #expect(throws: RenderFailure.displayNotConnected(1, connected: [])) {
            try Display.choose(1, from: [])
        }
    }

    /// 起動の失敗は全文が出る。**繋がっている一覧を並べ、無ければ無いと言う。**
    @Test("繋がっていない文面は、いまの一覧を番号と名前と大きさで並べる")
    func theMessageListsWhatIsConnected() {
        let text = RenderFailure.displayNotConnected(5, connected: desk).description
        #expect(text.hasPrefix("Display 5 is not connected"))
        #expect(text.contains("1: Built-in Retina Display (3600×2260)"))
        #expect(text.contains("4: Projector (1920×1080)"))
        let none = RenderFailure.displayNotConnected(1, connected: []).description
        #expect(none.contains("Connected now: none."))
    }

    // MARK: - 設定と組み立て

    @Test("fullScreen() は 1 を、fullScreen(n) は n を頼み、既定の設定は窓で開く")
    func theSettingsSpellingsAskForADisplay() {
        #expect(SketchSettings().fullScreenDisplay == nil)
        #expect(SketchSettings.fullScreen().fullScreenDisplay == 1)
        #expect(SketchSettings.fullScreen(2).fullScreenDisplay == 2)
        // 他の設定は既定のまま (代入して変える)
        var settings = SketchSettings.fullScreen(2)
        settings.fullScreenDisplay = nil
        #expect(settings == SketchSettings())
    }

    /// **窓で開くなら一覧を読まない** — 全画面を頼まないスケッチの起動は、ディスプレイの
    /// 顔ぶれに何も依らない。
    @Test("窓で開く設定は一覧を読まず、書いた大きさで描く")
    func aWindowedSketchDoesNotReadTheDisplays() throws {
        let stage = try SketchRuntime.stage(
            for: SketchSettings(width: 320, height: 180),
            displays: {
                Issue.record("窓で開くのに、ディスプレイの一覧を読んだ")
                return []
            })
        #expect(stage.width == 320)
        #expect(stage.height == 180)
        #expect(stage.display == nil)
    }

    @Test("全画面の設定は、選んだディスプレイの全画面の大きさで描く")
    func aFullScreenSketchDrawsAtTheDisplaysSize() throws {
        var settings = SketchSettings.fullScreen(3)
        // 全画面では読まない
        settings.width = 320
        settings.height = 180
        let stage = try SketchRuntime.stage(for: settings, displays: { desk })
        #expect(stage.width == 5120)
        #expect(stage.height == 2880)
        #expect(stage.display?.screenID == 5)
    }

    // MARK: - 全画面に入った後の突き合わせ

    @Test("全画面の中身が描く大きさと合えば何も言わず、違えば両方の大きさを言う")
    func aMismatchAfterEnteringFullScreenIsSaid() throws {
        #expect(
            WindowPlacement.fullScreenMismatch(
                content: NSSize(width: 1800, height: 1130), scale: 2, canvasWidth: 3600,
                canvasHeight: 2260) == nil)
        let said = try #require(
            WindowPlacement.fullScreenMismatch(
                content: NSSize(width: 1800, height: 1131), scale: 2, canvasWidth: 3600,
                canvasHeight: 2260))
        #expect(said.contains("3600×2262"))
        #expect(said.contains("3600×2260"))
    }

    private static func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index in
            var rest = items
            let head = rest.remove(at: index)
            return permutations(rest).map { [head] + $0 }
        }
    }
}

/// 小さな全画面の大きさを持つ 2 枚。**GPU に確保させる面を小さく保つ** (窓の枠の最小に掛からない程度に) — 見たいのは選び方と
/// 繋ぎ方で、大きさの規則は ``FullScreenChoiceTests`` が持つ。
@MainActor
enum SmallDisplays {
    static let first = Display(number: 1, name: "Main", width: 480, height: 270, screenID: 101)
    static let second = Display(number: 2, name: "Projector", width: 640, height: 360, screenID: 102)
    static let both = [first, second]
}

/// 全画面を頼むスケッチ。何も描かない。
final class FullScreenBlank: Sketch {
    var settings = SketchSettings.fullScreen()
    init() {}
    convenience init(display: Int, pixelDensity: Float = 1) {
        self.init()
        settings.fullScreenDisplay = display
        settings.pixelDensity = pixelDensity
    }
    func draw() {}
}

/// 組み立てが、選んだディスプレイの大きさで面を確保するか ([#2020])。GPU を要する。
///
/// [#2020]: https://github.com/mokume-metal/mokume/issues/2020
@Suite(
    "全画面の組み立て",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FullScreenAssemblyTests {
    /// 組み立ての入口は 2 つある (``SetupValueRangeTests`` と同じ)。どちらも同じに選ぶ。
    private func assemble(_ sketch: any Sketch, entry: Int) throws(RenderFailure) -> SketchRuntime {
        let gpu = try RenderDevice()
        switch entry {
        case 0:
            return try SketchRuntime(
                sketch: sketch, gpu: gpu, clock: nil, now: { 0 }, displays: { SmallDisplays.both })
        default:
            return try SketchRuntime(
                sketch: sketch, gpu: gpu, clock: nil, now: { 0 }, observer: nil,
                displays: { SmallDisplays.both })
        }
    }

    @Test("選んだディスプレイの全画面の大きさで描き、細かさはそのまま効く", arguments: [0, 1])
    func drawsAtTheChosenDisplay(entry: Int) throws {
        let runtime = try assemble(FullScreenBlank(display: 2, pixelDensity: 0.5), entry: entry)
        defer { runtime.closePlugins() }
        #expect(runtime.fullScreenDisplay == SmallDisplays.second)
        #expect(runtime.target.width == 640)
        #expect(runtime.target.height == 360)
        #expect(runtime.canvas.width == 640)
        #expect(runtime.canvas.pixelWidth == 320)
    }

    @Test("繋がっていない番号と 1 を割る番号は、どちらの入口の組み立ても断る", arguments: [0, 1])
    func refusesWhatCannotBeChosen(entry: Int) {
        #expect(throws: RenderFailure.displayNotConnected(3, connected: SmallDisplays.both)) {
            _ = try assemble(FullScreenBlank(display: 3), entry: entry)
        }
        #expect(throws: RenderFailure.invalidDisplay(0)) {
            _ = try assemble(FullScreenBlank(display: 0), entry: entry)
        }
    }
}

/// 全画面の窓 ([#2020])。**実際には全画面にしない** — 全画面にする口を差し替え、頼んだかを
/// 数える。既定のままだと、検査を走らせた機械の画面が全画面の操作スペースへ切り替わる。
/// 窓は 1 枚ずつ開いて閉じる (``SketchApplicationTests`` と同じ扱い)。
///
/// [#2020]: https://github.com/mokume-metal/mokume/issues/2020
@Suite(
    "全画面の窓",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct FullScreenWindowTests {
    /// 組む。終わりの行き先は、呼ばれたら赤を記録する口へ差し替える (``SketchApplicationTests``)。
    private func makeApplication(display: Int) throws -> SketchApplication {
        let application = try SketchApplication(
            sketch: FullScreenBlank(display: display), gpu: RenderDevice(), render: nil,
            displays: { SmallDisplays.both })
        application.onStopSignal = { Issue.record("検査は合図を送っていないのに、終わりを頼んだ") }
        return application
    }

    @Test("選んだディスプレイの画面に窓を立て、位置を覚えずに全画面を 1 度頼む")
    func opensOnTheChosenScreenAndAsksForFullScreen() throws {
        let screen = try #require(NSScreen.screens.first, "画面の無い実行環境")
        let application = try makeApplication(display: 2)
        defer { application.willTerminate() }
        var looked: [Display] = []
        application.screenForDisplay = {
            looked.append($0)
            return screen
        }
        var asked: [NSWindow] = []
        application.enterFullScreen = { asked.append($0) }
        var said: [String] = []
        application.announce = { said.append($0) }

        application.didFinishLaunching()

        let window = try #require(application.window)
        defer { window.close() }
        #expect(looked == [SmallDisplays.second])
        #expect(asked.count == 1)
        #expect(asked.first === window)
        #expect(window.screen == screen)
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(window.frameAutosaveName.isEmpty, "全画面の窓が位置を覚えている")
        #expect(said.isEmpty)
    }

    /// **全画面に入った後に、実物と描く大きさを突き合わせる。** 通知は手で送る — 実際に全画面に
    /// すると機械の画面が切り替わる。
    @Test("全画面に入った窓の中身が描く大きさと違えば、1 行言う")
    func saysWhenTheFullScreenDoesNotMatch() throws {
        let screen = try #require(NSScreen.screens.first, "画面の無い実行環境")
        let application = try makeApplication(display: 2)
        defer { application.willTerminate() }
        application.screenForDisplay = { _ in screen }
        application.enterFullScreen = { _ in }
        var said: [String] = []
        application.announce = { said.append($0) }
        application.didFinishLaunching()
        let window = try #require(application.window)
        defer { window.close() }

        // 窓の中身は描く大きさを画面の点へ直したもの — 合っているので何も言わない
        NotificationCenter.default.post(
            name: NSWindow.didEnterFullScreenNotification, object: window)
        #expect(said.isEmpty, "合っているのに言った: \(said)")

        window.setContentSize(
            NSSize(
                width: window.contentLayoutRect.width + 10, height: window.contentLayoutRect.height))
        NotificationCenter.default.post(
            name: NSWindow.didEnterFullScreenNotification, object: window)
        #expect(said.count == 1)
        #expect(said.first?.contains("640×360") == true)
    }

    /// 組み立ての後、窓を出すまでの間にディスプレイが外れた。**黙って全画面にしない。**
    @Test("窓を出す前にディスプレイが外れていたら、窓で開くことを言い、全画面を頼まない")
    func fallsBackToAWindowWhenTheDisplayWentAway() throws {
        let application = try makeApplication(display: 2)
        defer { application.willTerminate() }
        application.screenForDisplay = { _ in nil }
        var asked = 0
        application.enterFullScreen = { _ in asked += 1 }
        var said: [String] = []
        application.announce = { said.append($0) }

        application.didFinishLaunching()

        let window = try #require(application.window)
        defer { window.close() }
        #expect(asked == 0)
        #expect(said.count == 1)
        #expect(said.first?.contains("Display 2 (Projector) went away") == true)
        #expect(window.frameAutosaveName == WindowPlacement.autosaveName)
    }
}
