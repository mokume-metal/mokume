// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import MokumeCore
import MokumeMac
import Testing

@testable import MokumeUI

/// `SketchView` はスケッチの実体を作る前に、外枠の部品 (画面の一覧・メニューバーの名乗り) を差し込む (#3804)。
///
/// スケッチの `init` が画面の一覧を読んでも、差し込む前の空ではなく、差し込んだ読み手の一覧が見える。差し込む
/// 読み手は印の付いた 1 枚の画面に差し替える — 画面の無い実行環境でも、差し込む前 (空) と見分けられる。
@Suite("SketchView がスケッチを作る順")
@MainActor
struct SketchHostTests {
    @Test("スケッチの init より前に差し込む")
    func installsBeforeMakingTheSketch() {
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
        let marked = Display.Reading(
            screenID: 42, name: "Marked", frame: CGRect(x: 0, y: 0, width: 100, height: 50),
            visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 50), cameraHousing: 0, scale: 2)
        MacPlatform.screenReadings = { [marked] }

        let host = SketchHost(make: { ReadsDisplaysInInit() })
        let sketch = host.sketch as? ReadsDisplaysInInit
        #expect(sketch?.seenInInit?.map(\.name) == ["Marked"], "スケッチの init が読んだ後に差し込んだ")
    }

    /// `init` の中で画面の一覧を読むスケッチ。
    private final class ReadsDisplaysInInit: Sketch {
        let settings = SketchSettings(width: 16, height: 16)
        var seenInInit: [Display]?
        init() { seenInInit = displays }
    }
}
