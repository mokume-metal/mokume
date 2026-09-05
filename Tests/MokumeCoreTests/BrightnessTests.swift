// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 明るさを画面へ写す段の検査。GPU を要する。
///
/// 見るのは 3 つ — **どこに効くか**・**いつまで残るか**・**画面と書き出しが
/// 一致するか**。3 つ目は経路が 2 本ある (GPU の断片と Swift) ことから来る危険で、
/// 片方だけ直すと絵が静かに食い違う。
@Suite(
    "明るさを画面へ写す段",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct BrightnessTests {
    /// 半精度の刻みで割った差。刻みは明るさに比例するので、比で見る。
    private func difference(_ expected: Float, _ actual: Float) -> Float {
        abs(expected - actual) / max(abs(expected), 1)
    }

    private func makeCanvas(width: Int = 32, height: Int = 32) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    /// 一様な灰色 1 枚を描く。
    private func flat(_ canvas: Canvas, _ value: Float = 0.25) throws {
        try canvas.draw {
            canvas.background(.linear(red: value, green: value, blue: value))
        }
    }

    // MARK: - 曲線そのもの

    @Test("切り取りは、範囲の内側を 1 ビットも変えない")
    func clippingLeavesTheRangeAlone() {
        let brightness = Brightness.default
        for value in [Float(0), 0.001, 0.25, 0.5, 0.8, 0.999, 1] {
            #expect(brightness.map(SIMD3(repeating: value)) == SIMD3(repeating: value))
        }
    }

    @Test("寄せる形でも、折れ始める明るさまでは変えない")
    func rollingLeavesDarkValuesAlone() {
        let brightness = Brightness(exposure: 1, toneMapping: .roll)
        for value in [Float(0), 0.25, 0.5, Brightness.knee] {
            #expect(brightness.map(SIMD3(repeating: value)) == SIMD3(repeating: value))
        }
    }

    @Test("寄せる形は、範囲を超えた明るさを範囲の中へ収める")
    func rollingBringsBrightValuesIntoRange() {
        let brightness = Brightness(exposure: 1, toneMapping: .roll)
        for value in [Float(1.2), 2, 8, 100] {
            let mapped = brightness.map(SIMD3(repeating: value)).x
            // どれだけ明るくても範囲を超えない (十分明るいところは 1 へ漸近する)
            #expect(mapped <= 1)
            #expect(mapped > Brightness.knee)
        }
        // 少しだけ超えた明るさは、まだ 1 に達していない (頭打ちになっていない)
        #expect(brightness.map(SIMD3(repeating: 1.2)).x < 1)
        // 明るいほうが明るいまま (順序が入れ替わらない)
        #expect(brightness.map(SIMD3(repeating: 4)).x > brightness.map(SIMD3(repeating: 2)).x)
    }

    @Test("寄せる形は色みを変えない")
    func rollingKeepsTheHue() {
        // 成分ごとに曲げると、明るい成分だけが先に頭打ちになって色が転ぶ
        let brightness = Brightness(exposure: 1, toneMapping: .roll)
        let mapped = brightness.map(SIMD3(2, 1, 0.5))
        #expect(abs(mapped.x / mapped.y - 2) < 0.001)
        #expect(abs(mapped.y / mapped.z - 2) < 0.001)
    }

    /// 数でない成分の扱いが、**どの成分かで変わらない**こと (#440)。
    ///
    /// 丸めは 3 成分に共通の倍率を掛けるので、有限でない成分が 1 つあれば倍率が
    /// 意味を失う。いちばん明るい成分を先に取ってから有限かを見る形にすると、
    /// `max` が数でない値を引数の位置で落とすため、赤が数でなければ丸まらず、
    /// 青が数でなければ丸まる、という非対称になる。**絵としては「少し暗い」だけ**
    /// なので、突き合わせない限り気付けない。
    @Test("数でない成分があるときは、どの成分が壊れていても丸めない")
    func nonFiniteComponentsNeverRoll() {
        let brightness = Brightness(exposure: 1, toneMapping: .roll)
        for broken in 0..<3 {
            for value in [Float.nan, .infinity, -.infinity] {
                // 丸めが効く明るさ (折れ目より上) を残したまま、成分を 1 つ壊す
                var color = SIMD3<Float>(repeating: 2)
                color[broken] = value
                let mapped = brightness.map(color)
                for other in 0..<3 where other != broken {
                    #expect(
                        mapped[other] == 2,
                        "成分 \(broken) が \(value) のとき、成分 \(other) が丸められた")
                }
            }
        }
    }

    @Test("露出は掛け算で、1 は何も変えない")
    func exposureIsAMultiplier() {
        #expect(Brightness(exposure: 1).map(SIMD3(0.3, 0.2, 0.1)) == SIMD3(0.3, 0.2, 0.1))
        let doubled = Brightness(exposure: 2).map(SIMD3(0.3, 0.2, 0.1))
        #expect(doubled == SIMD3(0.6, 0.4, 0.2))
    }

    // MARK: - どこに効くか

    @Test("露出は書き出す絵に効く")
    func exposureShowsInTheWrittenPicture() throws {
        let plain = try makeCanvas()
        try flat(plain)
        let lifted = try makeCanvas()
        lifted.exposure(2)
        try flat(lifted)

        let before = try plain.target.encodeForDisplay()[4, 4].red
        let after = try lifted.target.encodeForDisplay()[4, 4].red
        #expect(after > before)
    }

    @Test("露出は、読み出した画素には効かない")
    func exposureDoesNotTouchTheWorkingSpace() throws {
        // 読み出す画素は**写す前の作業空間**そのもの。ここに露出が掛かると、
        // 描いた色と読んだ色が食い違い、画素をいじる経路が壊れる
        let canvas = try makeCanvas()
        canvas.exposure(3)
        try flat(canvas, 0.25)
        let pixels = try canvas.target.readPixels()
        #expect(abs(pixels[4, 4].red - 0.25) < 0.001)
    }

    @Test("露出はフレームを越える")
    func exposureCrossesFrames() throws {
        // 画面の性質なので、材質や光と違って書き換えるまで残る
        let canvas = try makeCanvas()
        canvas.exposure(2)
        try flat(canvas)
        let first = try canvas.target.encodeForDisplay()[4, 4].red
        try flat(canvas)
        let second = try canvas.target.encodeForDisplay()[4, 4].red
        #expect(first == second)

        let plain = try makeCanvas()
        try flat(plain)
        #expect(second > (try plain.target.encodeForDisplay()[4, 4].red))
    }

    @Test("数でない値・負の値では、露出を変えない")
    func brokenExposureIsIgnored() throws {
        let canvas = try makeCanvas()
        canvas.exposure(2)
        canvas.exposure(.nan)
        canvas.exposure(-1)
        canvas.exposure(.infinity)
        #expect(canvas.target.brightness.exposure == 2)
    }

    // MARK: - 画面と書き出しの一致

    @Test("画面へ出す経路と、書き出す経路が同じ明るさを出す", arguments: ToneMapping.allCases)
    func screenAndFileAgree(_ mode: ToneMapping) throws {
        // 曲線は Swift 側 (``Brightness``) と断片の 2 か所に書かれている。片方だけ
        // 直すと、画面と書き出した絵が静かに食い違う — その食い違いをここで捕まえる
        let gpu = try RenderDevice()
        let source = try RenderTarget(gpu: gpu, width: 32, height: 32)
        let canvas = try Canvas(target: source, gpu: gpu)
        canvas.exposure(1.7)
        canvas.toneMapping(mode)
        try canvas.draw {
            canvas.background(.linear(red: 0.1, green: 0.2, blue: 0.3))
            canvas.noStroke()
            // 範囲を超えた明るさを含める (ここでしか丸め方の違いが出ない)
            canvas.fill(.linear(red: 2.5, green: 1.2, blue: 0.4))
            canvas.rect(4, 4, 10, 24)
            canvas.fill(.linear(red: 0.6, green: 0.6, blue: 0.6))
            canvas.rect(18, 4, 10, 24)
        }

        let destination = try RenderTarget(gpu: gpu, width: 32, height: 32)
        let presenter = try FramePresenter(gpu: gpu, pixelFormat: RenderTarget.pixelFormat)
        try presenter.draw(source, into: destination.texture)

        let working = try source.readPixels()
        let onScreen = try destination.readPixels()
        let brightness = source.brightness
        var worst: Float = 0
        for y in 0..<working.height {
            for x in 0..<working.width {
                let color = working[x, y]
                let straight =
                    color.alpha > 0
                    ? SIMD3(color.red, color.green, color.blue) / color.alpha : SIMD3<Float>.zero
                let expected = brightness.map(straight) * color.alpha
                let actual = onScreen[x, y]
                // **明るいところほど半精度の刻みが粗い**ので、差は明るさで割って見る。
                // 絶対値で見ると、暗いところの食い違いを見逃す幅まで許すことになる
                worst = max(worst, difference(expected.x, actual.red))
                worst = max(worst, difference(expected.y, actual.green))
                worst = max(worst, difference(expected.z, actual.blue))
            }
        }
        #expect(worst < 0.002, "画面と書き出しで明るさが食い違っている (相対 \(worst))")
    }
}
