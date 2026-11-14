// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeHost
import Testing

@testable import MokumeCore
@testable import MokumeMac

/// ウィンドウを出さない口も、組む前に画面の一覧とメニューバーの名乗りを差し込む (#3804)。
///
/// MokumeCore は OS の UI 部品を知らないので、差し込まないと `displays` が空になり、全画面を頼むスケッチが
/// 組めず、長く走っても名乗らない。口を空に戻してから `HeadlessRun` を組み、差し込まれたことを見る。
@Suite(
    "HeadlessRun が差し込む画面の一覧と名乗り",
    .enabled(if: RenderDevice.isAvailable, "組み立てに Metal の装置が要る"),
    .serialized)
@MainActor
struct HeadlessRunPlatformTests {
    @Test("HeadlessRun を組むと、設定を読む前に画面の一覧と名乗りの係が差し込まれる")
    func headlessRunInstallsThePlatformHooks() throws {
        let reader = Display.screenReader
        let presence = SketchRuntime.makePresence
        defer {
            Display.screenReader = reader
            SketchRuntime.makePresence = presence
        }
        Display.screenReader = { [] }
        SketchRuntime.makePresence = { _ in nil }

        let sketch = ReadsDisplays()
        let run = try HeadlessRun(sketch)
        _ = run
        #expect(sketch.seenInSettings == Display.list(from: Display.readings()))
        let runtime = try SketchRuntime(sketch: ReadsDisplays(), gpu: RenderDevice())
        defer { runtime.closePlugins() }
        #expect(SketchRuntime.makePresence(runtime) is SketchPresence)
    }

    /// 設定の中で画面の一覧を読むスケッチ。
    private final class ReadsDisplays: Sketch {
        init() {}
        var seenInSettings: [Display]?
        var settings: SketchSettings {
            seenInSettings = displays
            return SketchSettings(width: 16, height: 16)
        }
    }
}
