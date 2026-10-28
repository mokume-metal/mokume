// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// `SketchSettings.size(_:_:frameRate:title:)` ([#3361])。型の名前を繰り返さずに窓の大きさを書く
/// 静的ファクトリで、`SketchSettings(width:height:frameRate:title:)` と同じ値を返す。
///
/// [#3361]: https://github.com/mokume-metal/mokume/issues/3361
@Suite("SketchSettings.size(_:_:frameRate:title:)")
struct SketchSettingsSizeTests {
    /// `var settings: SketchSettings { .size(…) }` と書いたスケッチ。
    private final class Sized: Sketch {
        var settings: SketchSettings { .size(800, 600) }
        init() {}
        func draw() {}
    }

    private final class Configured: Sketch {
        var settings: SketchSettings { .size(640, 360, frameRate: 30, title: "Waves") }
        init() {}
        func draw() {}
    }

    @Test("size(w, h) は SketchSettings(width:height:) と同じ設定で、他の設定は既定のまま")
    func sizeMatchesTheInitializer() {
        let settings = SketchSettings.size(800, 600)
        #expect(settings == SketchSettings(width: 800, height: 600))
        // 既定が init と食い違えば、ここが先に割れる
        #expect(settings.frameRate == 60)
        #expect(settings.title == "mokume")
        #expect(settings != SketchSettings())  // 既定の大きさ (960x540) とは違う
    }

    @Test("frameRate と title を渡せる")
    func frameRateAndTitleCanBeGiven() {
        let settings = SketchSettings.size(640, 360, frameRate: 30, title: "Waves")
        #expect(settings == SketchSettings(width: 640, height: 360, frameRate: 30, title: "Waves"))
        #expect(settings.frameRate == 30)
        #expect(settings.title == "Waves")
        // 片方だけでも渡せ、渡さないほうは既定のまま
        #expect(SketchSettings.size(10, 20, frameRate: 24).title == "mokume")
        #expect(SketchSettings.size(10, 20, title: "t").frameRate == 60)
    }

    @Test("size は窓で開く設定で、fullScreen() は変わらない")
    func fullScreenIsUntouched() {
        #expect(SketchSettings.size(800, 600).fullScreenDisplay == nil)
        #expect(SketchSettings.fullScreen().fullScreenDisplay == 1)
        #expect(SketchSettings.fullScreen(2).fullScreenDisplay == 2)
        var expected = SketchSettings()
        expected.fullScreenDisplay = 1
        #expect(SketchSettings.fullScreen() == expected)
    }

    @Test("settings に .size(800, 600) と書いたスケッチは、その大きさで起動を組み立てる")
    func aSketchCanDeclareItsSizeWithTheFactory() throws {
        let sized = try SketchRuntime.stage(for: Sized().settings, displays: { [] })
        #expect(sized.width == 800)
        #expect(sized.height == 600)
        let configured = Configured().settings
        #expect(configured.frameRate == 30)
        #expect(configured.title == "Waves")
    }
}
