// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import CryptoKit
import Foundation
import SwiftUI
import Testing

@testable import MokumeCore
@testable import MokumeMac
@testable import mokume

// つまみの UI (面・色を選ぶ欄) の検査。宣言からつまみを決める規則と脇の数字は Core にあるので、
// その検査は MokumeCoreTests の ParameterKnobTests.swift にある (#3804)。

/// 色を選ぶ欄と作業空間のあいだの変換。
///
/// **ウィンドウを立てずに検められる。** `ColorPicker` に載せる `Color` を組むのも、選ばれた
/// `Color` を作業空間へ戻すのも純関数なので、画面を出さずに往復を見られる。
@Suite("色を選ぶ欄との往復")
struct KnobColorTests {
    /// 選ぶ欄に載った色を、表示空間の 4 成分として読み直す。
    private func picked(_ value: LinearRGBA) -> (
        red: Float, green: Float, blue: Float, alpha: Float
    ) {
        let shown = NSColor(KnobColor.display(of: value)).usingColorSpace(.displayP3)!
        return (
            Float(shown.redComponent), Float(shown.greenComponent), Float(shown.blueComponent),
            Float(shown.alphaComponent)
        )
    }

    @Test("薄い色でも、選ぶ欄に出る色みは変わらない")
    func alphaDoesNotDarkenTheSwatch() {
        // 作業空間の成分はアルファ乗算済み (ADR-0011 決定 4)。**乗算を戻さずに符号化
        // すると、透明な色ほど暗い色が欄に出る** — 濃さを直すたびに色みが動くので、
        // 選んでいる最中には「そういうもの」に見えてしまう
        let opaque = picked(color(255, 204, 0))
        let faint = picked(color(255, 204, 0, 64))

        #expect(abs(opaque.red - faint.red) < 0.01)
        #expect(abs(opaque.green - faint.green) < 0.01)
        #expect(abs(opaque.blue - faint.blue) < 0.01)
        // 変わってよいのは濃さだけ
        #expect(abs(faint.alpha - 64.0 / 255.0) < 0.01)
    }

    @Test("欄に出して選び直しても、色は同じところへ戻る")
    func theRoundTripKeepsTheColor() {
        for original in [color(255, 204, 0), color(255, 204, 0, 128), color(0, 0, 0), color(128)] {
            let returned = KnobColor.working(of: KnobColor.display(of: original))
            #expect(abs(returned.red - original.red) < 0.01)
            #expect(abs(returned.green - original.green) < 0.01)
            #expect(abs(returned.blue - original.blue) < 0.01)
            #expect(abs(returned.alpha - original.alpha) < 0.01)
        }
    }

    @Test("まっさらな透明は、色みを持たないまま出る")
    func fullyTransparentStaysTransparent() {
        // 乗算を戻す割り算は、アルファ 0 では成り立たない。**割ってはいけない側**を
        // 落とすと 0 除算で色みが暴れる
        let clear = picked(.transparent)
        #expect(clear.alpha == 0)
        #expect(clear.red == 0)
        #expect(clear.green == 0)
        #expect(clear.blue == 0)
    }
}

/// つまみの面が、値を勝手に書き換えないこと。
///
/// **ウィンドウが値を持つと、触っていないフレームでも「変わった」と言い続ける。** ウィンドウは正典を
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

        let panel = KnobOverlay.makeIfNeeded(for: ParamRegistry(of: sketch))
        #expect(panel != nil)
        // **組み直すたびに本体が引き直る。** ウィンドウが値を持っていれば、ここで書き戻しが起きる
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
        #expect(KnobOverlay.makeIfNeeded(for: ParamRegistry(of: Plain())) == nil)
    }
}

/// つまみの面の置き方。
///
/// **宣言の数は作品が決める** ので、面はウィンドウより高くなりうる。はみ出したまま置くと下の
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
        let panel = try #require(KnobOverlay.makeIfNeeded(for: ParamRegistry(of: Many())))
        panel.attach(to: host)
        return (panel, host)
    }

    @Test("ウィンドウに収まる丈なら、中身のままの高さで左上に置く")
    func fitsAsIsWhenTheWindowIsTall() throws {
        let (panel, host) = try place(inHostOfHeight: 2_000)
        #expect(panel.frame.minX == KnobOverlay.inset)
        #expect(panel.frame.maxY == host.bounds.height - KnobOverlay.inset)
        #expect(panel.frame.height > 100)
    }

    /// 詰めても**上端は動かない**。上を動かすと、ウィンドウを縮めるたびにつまみの並びが上下する。
    @Test("ウィンドウに収まらなければ丈を詰める。上端は動かさない")
    func shrinksToFitButKeepsTheTop() throws {
        let tall = try place(inHostOfHeight: 2_000).0.frame.height
        let (panel, host) = try place(inHostOfHeight: 200)
        #expect(panel.frame.height < tall)
        #expect(panel.frame.height <= host.bounds.height - 2 * KnobOverlay.inset)
        #expect(panel.frame.maxY == host.bounds.height - KnobOverlay.inset)
    }

    /// **後から来た警告で欄が伸びたら、枠も伸びる** ([#3087](https://github.com/mokume-metal/mokume/issues/3087))。
    /// 枠の丈は置いたときに 1 度測るだけなので、測り直さないと欄はウィンドウの下に切れて見えない。上端は動かさない。
    @Test("警告が後から来て欄が伸びたら、丈を測り直す。無くなれば元に戻り、上端は動かさない")
    func growsWhenTheWarningsArriveLater() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 2_000))
        let panel = KnobOverlay(boxes: [], numbers: { nil })
        panel.attach(to: host)
        let bare = panel.frame.height
        let top = host.bounds.height - KnobOverlay.inset

        panel.show(warnings: WarningSummary(count: 1, last: "short"))
        let one = panel.frame.height
        #expect(one > bare, "欄が伸びたのに枠が伸びていない: \(bare) → \(one)")
        #expect(panel.frame.maxY == top)

        // 3 行に折り返す長さ (上限の 3 行まで伸びる)
        panel.show(warnings: WarningSummary(count: 9, last: String(repeating: "wide words ", count: 12)))
        let many = panel.frame.height
        #expect(many > one, "行が増えたのに枠が伸びていない: \(one) → \(many)")
        #expect(panel.frame.maxY == top)

        panel.show(warnings: nil)
        #expect(panel.frame.height == bare, "欄が消えたのに枠が縮んでいない")
    }

    @Test("ウィンドウの大きさが変われば置き直す")
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
/// **ここは目より機械が強い** — 同じフレームを、つまみを重ねたウィンドウと重ねないウィンドウで描き、
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

    /// ウィンドウを組み立てて 1 フレーム描く。`showingKnobs` だけが 2 つの経路の違いである。
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
            // 数字も一緒に出す。**ウィンドウに出す表示は、どれも描画の出力に入らない**
            // (#517 の全体に効く条件 1) — 数字が焼き付くと、撮り直すたびに違う絵になる
            let panel = try #require(
                KnobOverlay.makeIfNeeded(for: ParamRegistry(of: sketch)) {
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
