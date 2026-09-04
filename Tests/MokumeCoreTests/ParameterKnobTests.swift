// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import CryptoKit
import Foundation
import Testing

@testable import MokumeCore
@testable import mokume

/// 宣言からつまみを決める規則。
///
/// **窓を立てずに検められる形にしてある** ([ADR-0030](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md) 決定 8)。
/// 対応を SwiftUI の中に埋めると、規則が正しいかどうかは画面を見るまで分からなくなる。
@Suite("型ごとのつまみ")
struct KnobKindTests {
    private func kind(_ value: ParamValue, range: ParamRange? = nil, choices: [String]? = nil)
        -> KnobKind
    {
        KnobKind.forDeclaration(
            ParamDeclaration(name: "x", value: value, range: range, choices: choices))
    }

    @Test("数はスライダー。整数は刻みつき")
    func numbersBecomeSliders() {
        let range = ParamRange(0...10)
        #expect(kind(.float(1), range: range) == .slider(range))
        #expect(kind(.int(1), range: range) == .steppedSlider(range))
    }

    /// **範囲を書かなかった数値には、つまみを出さない** (ADR-0030 決定 8)。値から範囲を
    /// 推すと、引いている最中に範囲そのものが動いてつまみが指の下から逃げる。
    @Test("範囲を書かなかった数値には、つまみを出さない")
    func numbersWithoutRangeGetNoKnob() {
        #expect(kind(.float(1)) == .none(.rangeNotDeclared))
        #expect(kind(.int(1)) == .none(.rangeNotDeclared))
        #expect(kind(.vector2(SIMD2(1, 2))) == .none(.rangeNotDeclared))
        #expect(kind(.vector3(SIMD3(1, 2, 3))) == .none(.rangeNotDeclared))
    }

    @Test("真偽はトグル、色は色の選択")
    func flagsAndColors() {
        #expect(kind(.bool(true)) == .toggle)
        #expect(kind(.color(.transparent)) == .color)
    }

    @Test("組は成分ごとのスライダー")
    func vectorsBecomeComponentSliders() {
        let range = ParamRange(-1...1)
        #expect(kind(.vector2(SIMD2(0, 0)), range: range) == .components(count: 2, range: range))
        #expect(kind(.vector3(SIMD3(0, 0, 0)), range: range) == .components(count: 3, range: range))
    }

    @Test("文字は候補から選ぶ。候補が無ければつまみを出さない")
    func stringsNeedChoices() {
        #expect(kind(.string("a"), choices: ["a", "b"]) == .choice(["a", "b"]))
        #expect(kind(.string("a")) == .none(.choicesNotDeclared))
        #expect(kind(.string("a"), choices: []) == .none(.choicesNotDeclared))
    }

    /// つまみが出ない値を並びから消すと、**書いたのに効かない**のか**出していないだけ**なのか
    /// が窓からは区別できない。理由は次に何を書けばよいかまで言う。
    @Test("つまみを出さない理由は、次に何を書けばよいかまで言う")
    func reasonsSayWhatToWrite() {
        #expect(KnobKind.Reason.rangeNotDeclared.note.contains("範囲"))
        #expect(KnobKind.Reason.choicesNotDeclared.note.contains("候補"))
    }
}

/// つまみの脇に出る値の表記。
@Suite("つまみの脇の数字")
struct KnobTextTests {
    @Test("実数は小数 2 桁で、桁が伸び縮みしない")
    func floatsKeepTheirWidth() {
        #expect(KnobText.value(of: .float(1)) == "1.00")
        #expect(KnobText.value(of: .float(1.005)) == "1.00" || KnobText.value(of: .float(1.005)) == "1.01")
        #expect(KnobText.value(of: .int(7)) == "7")
    }

    @Test("色は 16 進で出る")
    func colorsShowAsHex() {
        #expect(KnobText.value(of: .color(.linear(red: 1, green: 0, blue: 0))) == "#FF0000")
    }

    @Test("組は成分を並べる")
    func vectorsShowComponents() {
        #expect(KnobText.value(of: .vector2(SIMD2(1, 2))) == "1.00, 2.00")
    }
}

/// つまみの面が、値を勝手に書き換えないこと。
///
/// **窓が値を持つと、触っていないフレームでも「変わった」と言い続ける。** 窓は正典を
/// 読み、動かしたときだけ正典を書く — その性質は、面を何度組み直しても通知が 1 件も
/// 出ないことで見える。
@Suite("つまみは触らなければ黙っている")
@MainActor
struct KnobQuietTests {
    final class Knobbed: Sketch {
        @Param(0...200) var radius: Double = 80
        @Param var filled: Bool = true
        @Param(choices: ["circle", "square"]) var shape: String = "circle"
    }

    /// 変更が来たかどうかだけを持つ箱。
    private final class Notice {
        var changed = false
    }

    /// 宣言した値のどれかが変わったら印を立てる。
    private func watch(_ sketch: Knobbed, _ notice: Notice) {
        withObservationTracking {
            for box in ParamCatalog.indexed(from: sketch) { _ = box.box.declaration }
        } onChange: { [notice] in
            MainActor.assumeIsolated { notice.changed = true }
        }
    }

    @Test("面を何度組み直しても、値は 1 度も変わらない")
    func layingOutTheKnobsNeverWrites() {
        let sketch = Knobbed()
        let notice = Notice()
        watch(sketch, notice)

        let panel = KnobOverlay.makeIfNeeded(for: sketch)
        #expect(panel != nil)
        // **組み直すたびに本体が引き直る。** 窓が値を持っていれば、ここで書き戻しが起きる
        for _ in 0..<10 {
            _ = panel?.fittingSize
            panel?.layoutSubtreeIfNeeded()
        }

        #expect(notice.changed == false)
        #expect(sketch.radius == 80)
    }

    /// 逆側 — **書けば必ず印が立つ**ことを見ておく。これが無いと、上の検査は
    /// 「通知の仕組みが動いていない」だけでも緑になる。
    @Test("値を書き換えれば印が立つ")
    func writingDoesNotify() {
        let sketch = Knobbed()
        let notice = Notice()
        watch(sketch, notice)

        sketch.radius = 100

        #expect(notice.changed == true)
    }

    @Test("宣言が 1 つも無ければ、面を作らない")
    func noDeclarationsMeansNoPanel() {
        final class Plain: Sketch {}
        #expect(KnobOverlay.makeIfNeeded(for: Plain()) == nil)
    }
}

/// つまみの面の置き方。
///
/// **宣言の数は作品が決める** ので、面は窓より高くなりうる。はみ出したまま置くと下の
/// つまみへ手が届かないので、収まるところまで詰めて中で巻き取る。
@Suite("つまみの面の置き方")
@MainActor
struct KnobOverlayLayoutTests {
    final class Many: Sketch {
        @Param(0...1) var a: Double = 0
        @Param(0...1) var b: Double = 0
        @Param(0...1) var c: Double = 0
        @Param(0...1) var d: Double = 0
        @Param(0...1) var e: Double = 0
        @Param(0...1) var f: Double = 0
    }

    private func place(inHostOfHeight height: CGFloat) throws -> (KnobOverlay, NSView) {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: height))
        let panel = try #require(KnobOverlay.makeIfNeeded(for: Many()))
        panel.attach(to: host)
        return (panel, host)
    }

    @Test("窓に収まる丈なら、中身のままの高さで左上に置く")
    func fitsAsIsWhenTheWindowIsTall() throws {
        let (panel, host) = try place(inHostOfHeight: 2_000)
        #expect(panel.frame.minX == KnobOverlay.inset)
        #expect(panel.frame.maxY == host.bounds.height - KnobOverlay.inset)
        #expect(panel.frame.height > 100)
    }

    /// 詰めても**上端は動かない**。上を動かすと、窓を縮めるたびにつまみの並びが上下する。
    @Test("窓に収まらなければ丈を詰める。上端は動かさない")
    func shrinksToFitButKeepsTheTop() throws {
        let tall = try place(inHostOfHeight: 2_000).0.frame.height
        let (panel, host) = try place(inHostOfHeight: 200)
        #expect(panel.frame.height < tall)
        #expect(panel.frame.height <= host.bounds.height - 2 * KnobOverlay.inset)
        #expect(panel.frame.maxY == host.bounds.height - KnobOverlay.inset)
    }

    @Test("窓の大きさが変われば置き直す")
    func repositionsWhenTheWindowResizes() throws {
        let (panel, host) = try place(inHostOfHeight: 2_000)
        host.setFrameSize(NSSize(width: 400, height: 200))
        #expect(panel.frame.maxY == host.bounds.height - KnobOverlay.inset)
        #expect(panel.frame.height <= host.bounds.height - 2 * KnobOverlay.inset)
    }
}

/// **つまみの面が絵に混ざらないこと** ([ADR-0030](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md) 決定 1)。
///
/// 目で見ると「パネルが出ている絵」と「出ていない絵」は区別が付いてしまうので、
/// **ここは目より機械が強い** — 同じフレームを、つまみを重ねた窓と重ねない窓で描き、
/// 出力段を通した 8 bit の画素の sha256 が一致することを見る
/// ([ADR-0019](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md) 決定 3 の量子化点・
/// [ADR-0025](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md) 水準 3)。
///
/// **つまみが実際に画素を持って描かれたことも同じ検査で確かめる。** 描かれていない面と
/// 比べても何も示せない — 「出していない絵」を 2 枚並べただけになる。
@Suite(
    "つまみの面は絵に混ざらない",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct KnobOverlayRenderingTests {
    final class Knobbed: Sketch {
        var settings = SketchSettings(width: 64, height: 64, frameRate: 60)
        @Param(0...64) var radius: Double = 24
        @Param var filled: Bool = true
        @Param(choices: ["circle", "square"]) var shape: String = "circle"

        init() {}
        func draw() {
            background(.display(red: 0.1, green: 0.2, blue: 0.3))
            fill(.display(red: 0.9, green: 0.7, blue: 0.2))
            circle(32, 32, Float(radius))
        }
    }

    /// 1 フレーム描いた結果の指紋と、つまみが持っていた画素の数。
    private struct Take {
        let digest: String
        let knobPixels: Int
    }

    /// 窓を組み立てて 1 フレーム描く。`showingKnobs` だけが 2 つの経路の違いである。
    private func render(showingKnobs: Bool) throws -> Take {
        let sketch = Knobbed()
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: .frameIndex(frameRate: 60))
        let size = NSSize(width: 200, height: 200)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let surface = SketchSurface(
            frame: NSRect(origin: .zero, size: size), device: runtime.target.gpu.device,
            input: runtime.input, canvasSize: (64, 64))
        surface.wantsLayer = true
        window.contentView = surface

        var knobPixels = 0
        if showingKnobs {
            // 数字も一緒に出す。**窓に出す表示は、どれも描画の出力に入らない**
            // (#517 の全体に効く条件 1) — 数字が焼き付くと、撮り直すたびに違う絵になる
            let panel = try #require(
                KnobOverlay.makeIfNeeded(for: sketch) {
                    FrameNumbers(frameCount: 7, time: 0.25, frameRate: 59.9, frameTimeMs: 16.7)
                })
            panel.attach(to: surface)
            window.layoutIfNeeded()
            knobPixels = Self.drawnPixels(of: panel)
        }

        try runtime.advance()
        let image = try runtime.target.encodeForDisplay()
        return Take(
            digest: SHA256.hash(data: Data(image.bytes)).map { String(format: "%02x", $0) }.joined(),
            knobPixels: knobPixels)
    }

    /// 面を実際に描かせ、透明でない画素を数える。
    private static func drawnPixels(of view: NSView) -> Int {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.bitmapData else { return 0 }
        let samples = rep.samplesPerPixel
        let count = rep.pixelsWide * rep.pixelsHigh
        var drawn = 0
        for pixel in 0..<count where data[pixel * samples + (samples - 1)] > 0 { drawn += 1 }
        return drawn
    }

    @Test("つまみを出しても、書き出した絵は 1 ビットも変わらない")
    func knobsDoNotReachTheOutput() throws {
        let without = try render(showingKnobs: false)
        let with = try render(showingKnobs: true)

        // 面がただ透明だったのなら、一致は何も意味しない
        #expect(with.knobPixels > 0, "つまみの面が 1 画素も描かれていない")
        #expect(with.digest == without.digest)
    }

    /// この検査自身が退行を捕まえられることの確認 — **絵が変われば指紋は動く**。
    /// 動かなければ、上の一致は「どんな絵でも同じ指紋が出る」だけかもしれない。
    @Test("絵が変われば指紋は動く")
    func theFingerprintMovesWhenThePictureDoes() throws {
        let base = try render(showingKnobs: false)
        let sketch = Knobbed()
        sketch.radius = 8
        let runtime = try SketchRuntime(
            sketch: sketch, gpu: try RenderDevice(), clock: .frameIndex(frameRate: 60))
        try runtime.advance()
        let image = try runtime.target.encodeForDisplay()
        let moved = SHA256.hash(data: Data(image.bytes)).map { String(format: "%02x", $0) }.joined()

        #expect(moved != base.digest)
    }
}
