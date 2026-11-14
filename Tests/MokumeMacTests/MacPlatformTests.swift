// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore
@testable import MokumeMac

/// MokumeCore が OS の UI 部品に頼る 2 つの口 (画面の一覧・メニューバーの名乗り) へ、外枠が macOS の部品を差し込む
/// (``MacPlatform/install()``・#3804)。
///
/// 口は大域の 1 つずつなので、検査は差し込む前の値を控えて戻す。ランタイムを組む入口が差し込むことは、
/// 入口ごとの検査 (`SketchApplicationTests`・`HeadlessRunTests`) ではなくここで、口を空に戻してから組んで見る。
///
/// **差し込む読み手は印の付いた 1 枚の画面に差し替える** (``MacPlatform/screenReadings``)。`NSScreen` を読む
/// 読み手のままだと、画面の無い実行環境では差し込む前 (空) と後 (空) が見分けられず、順の検査が空振りする。
@Suite(
    "外枠が差し込む画面の一覧とメニューバーの名乗り",
    .enabled(if: RenderDevice.isAvailable, "名乗りの係を確かめるのにランタイムを組む (Metal の装置が要る)"))
@MainActor
struct MacPlatformTests {
    /// 2 つの口を空に戻し、差し込む読み手を印の付いた画面に差し替えて `body` を走らせ、終わったら元に戻す。
    private func withEmptyHooks(_ body: () throws -> Void) rethrows {
        let reader = Display.screenReader
        let presence = SketchRuntime.makePresence
        let readings = MacPlatform.screenReadings
        defer {
            Display.screenReader = reader
            SketchRuntime.makePresence = presence
            MacPlatform.screenReadings = readings
        }
        Display.screenReader = { [] }
        SketchRuntime.makePresence = { _ in nil }
        MacPlatform.screenReadings = { [Self.marked] }
        try body()
    }

    /// 1 枚の画面の読み。差し込んだ読み手が呼ばれたことを、この名前で見分ける。
    private static let marked = Display.Reading(
        screenID: 42, name: "Marked", frame: CGRect(x: 0, y: 0, width: 100, height: 50),
        visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 50), cameraHousing: 0, scale: 2)

    /// 差し込まれた読み手で読んだ一覧。
    private static var markedList: [Display] { Display.list(from: [marked]) }

    @Test("差し込む前は、画面の一覧は空で、名乗りの係を作らない")
    func emptyBeforeInstall() throws {
        try withEmptyHooks {
            #expect(Display.connected.isEmpty)
            let runtime = try SketchRuntime(sketch: Plain(), gpu: RenderDevice())
            defer { runtime.closePlugins() }
            #expect(SketchRuntime.makePresence(runtime) == nil)
            #expect(!runtime.isPresenceAnnounced)
        }
    }

    @Test("差し込んだ読み手から一覧を組む (番号・全画面の大きさは Core の組み方のまま)")
    func connectedReadsTheInstalledReader() {
        withEmptyHooks {
            Display.screenReader = { [Self.marked] }
            #expect(Display.connected.map(\.name) == ["Marked"])
            #expect(Display.connected.first?.width == 200)
            #expect(Display.connected.first?.number == 1)
        }
    }

    @Test("install() は、画面の読み手と、メニューバーの名乗りの係を差し込む")
    func installPlugsBothHooks() throws {
        try withEmptyHooks {
            MacPlatform.install()
            #expect(Display.connected == Self.markedList)
            let runtime = try SketchRuntime(sketch: Plain(), gpu: RenderDevice())
            defer { runtime.closePlugins() }
            #expect(SketchRuntime.makePresence(runtime) is SketchPresence)
        }
    }

    @Test("既定の読み手は NSScreen を読む")
    func defaultReaderReadsTheScreens() {
        #expect(MacPlatform.screenReadings() == Display.readings())
    }

    @Test("ウィンドウの経路 (SketchApplication) は、設定を読む前に差し込む")
    func sketchApplicationInstallsBeforeReadingSettings() throws {
        try withEmptyHooks {
            let sketch = ReadsDisplays()
            _ = try SketchApplication(sketch: sketch, gpu: RenderDevice(), render: nil)
            #expect(sketch.seenInSettings == Self.markedList, "設定を読んだ後に差し込んだ")
        }
    }

    @Test("Sketch.main() の組み立ては、スケッチの init より前に差し込む")
    func mainInstallsBeforeMakingTheSketch() throws {
        try withEmptyHooks {
            ReadsDisplaysInInit.seenInInit = nil
            _ = try ReadsDisplaysInInit.makeApplication()
            #expect(ReadsDisplaysInInit.seenInInit == Self.markedList, "スケッチの init が読んだ後に差し込んだ")
        }
    }

    private final class Plain: Sketch {
        init() {}
        let settings = SketchSettings(width: 16, height: 16)
    }

    /// `init` の中で画面の一覧を読むスケッチ。``Sketch/main()`` が実体を作るので、読んだ一覧は型に控える。
    private final class ReadsDisplaysInInit: Sketch {
        nonisolated(unsafe) static var seenInInit: [Display]?
        init() { Self.seenInInit = displays }
        let settings = SketchSettings(width: 16, height: 16)
    }

    /// 設定の中で画面の一覧を読むスケッチ。**最初の読みだけを控える** — 組み立ては設定を何度か読むので、
    /// 最後の読みを見ると、最初の読みの後に差し込んでも通ってしまう。
    private final class ReadsDisplays: Sketch {
        init() {}
        var seenInSettings: [Display]?
        var settings: SketchSettings {
            if seenInSettings == nil { seenInSettings = displays }
            return SketchSettings(width: 16, height: 16)
        }
    }
}
