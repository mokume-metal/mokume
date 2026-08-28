// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 周囲からの光と映り込みの検査。GPU を要する。
///
/// 見るのは 4 つ — **周囲が絵に出るか**・**光と二重に数えていないか**・**向きが
/// 背景と映り込みで一致するか**・**他の設定を書き換えていないか**。どれも例外は
/// 出ず、絵が少し違うだけで壊れる ([ADR-0019] 決定 4)。
///
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
@Suite(
    "周囲からの光と映り込み",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SurroundingsTests {
    private let black = LinearRGBA.opaque(red: 0, green: 0, blue: 0)

    private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }

    /// 中央に球を 1 つ置く。周囲・光・材質だけを差し替えられる形にしてある。
    @discardableResult
    private func sphere(_ canvas: Canvas, _ scene: (Canvas) -> Void) throws -> PixelBuffer {
        try canvas.draw {
            canvas.background(black)
            canvas.noStroke()
            scene(canvas)
            canvas.fill(.opaque(red: 0.8, green: 0.8, blue: 0.82))
            canvas.push()
            canvas.translate(32, 32, 0)
            canvas.sphere(26)
            canvas.pop()
        }
        return try canvas.target.readPixels()
    }

    /// 球の上のほう / 下のほうの明るさ。
    private func topAndBottom(_ pixels: PixelBuffer) -> (top: LinearRGBA, bottom: LinearRGBA) {
        (pixels[32, 10], pixels[32, 54])
    }

    // MARK: - 周囲が絵に出る

    @Test("光を 1 つも置かなくても、周囲だけで面は明るくなる")
    func surroundingsAloneLightTheSurface() throws {
        // 置いたのに何も起きない設定を作らない。周囲は光と同じく面を明るくするもの
        let lit = try sphere(try makeCanvas()) { $0.surroundings(.sky) }
        let (top, bottom) = topAndBottom(lit)
        #expect(top.red > 0.05, "周囲だけでは明るくなっていない")
        // 上と下で色が違う = 向きに応じて周囲を読んでいる (平坦な塗りではない)
        #expect(abs(top.blue - bottom.blue) > 0.05)
    }

    @Test("周囲を切ると、金属は特徴のない塊に戻る")
    func metalWithoutSurroundingsIsFeatureless() throws {
        let metal: (Canvas) -> Void = {
            $0.ambientLight(.opaque(red: 0.25, green: 0.25, blue: 0.25))
            $0.metalness(1)
        }
        let withSurroundings = try sphere(try makeCanvas()) {
            metal($0)
            $0.surroundings(.sky)
        }
        let without = try sphere(try makeCanvas(), metal)

        let varied = topAndBottom(withSurroundings)
        let flat = topAndBottom(without)
        // 周囲があれば上 (空) と下 (地面) で違う色になる
        #expect(abs(varied.top.blue - varied.bottom.blue) > 0.08)
        // 切れば、底上げの光が一様に返るだけ = どこも同じ色
        #expect(abs(flat.top.blue - flat.bottom.blue) < 0.01)
        #expect(flat.top.red > 0.05, "映す先が無いのに真っ黒になっている")
    }

    // MARK: - 二重に数えない

    @Test("周囲と底上げの光を、二重に数えない")
    func surroundingsAndAmbientAreCountedOnce() throws {
        // **足し算が成り立つことで示す。** どちらか一方でも 2 回数えていれば破れる
        let ambient = LinearRGBA.opaque(red: 0.3, green: 0.3, blue: 0.35)
        let onlySurroundings = try sphere(try makeCanvas()) { $0.surroundings(.sky) }
        let onlyAmbient = try sphere(try makeCanvas()) { $0.ambientLight(ambient) }
        let both = try sphere(try makeCanvas()) {
            $0.surroundings(.sky)
            $0.ambientLight(ambient)
        }

        var worst: Float = 0
        var lit = 0
        for y in 0..<both.height {
            for x in 0..<both.width {
                let sum = SIMD3(
                    onlySurroundings[x, y].red + onlyAmbient[x, y].red,
                    onlySurroundings[x, y].green + onlyAmbient[x, y].green,
                    onlySurroundings[x, y].blue + onlyAmbient[x, y].blue)
                let actual = both[x, y]
                if sum.x > 0.02 { lit += 1 }
                worst = max(worst, abs(sum.x - actual.red))
                worst = max(worst, abs(sum.y - actual.green))
                worst = max(worst, abs(sum.z - actual.blue))
            }
        }
        #expect(lit > 500, "明るい画素が少なすぎて、足し算を確かめられていない")
        #expect(worst < 0.005, "足し算が成り立たない = どちらかを二重に数えている")
    }

    @Test("周囲から受け取る明るさは、周囲のいちばん明るい色を超えない")
    func theSurfaceCannotReturnMoreThanItReceives() throws {
        // **足し算が成り立つだけでは、倍率の間違いは捕まらない** (一様に 2 倍しても
        // 足し算は成り立つ)。受け取る量の上限で押さえる — 面が返せるのは、周囲の
        // いちばん明るい色に塗りを掛けたところまでである
        let pixels = try sphere(try makeCanvas()) { $0.surroundings(.sky) }
        let brightest = max(
            max(Surroundings.sky.top.blue, Surroundings.sky.horizon.blue),
            Surroundings.sky.bottom.blue)
        let fill: Float = 0.82
        var peak: Float = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width { peak = max(peak, pixels[x, y].blue) }
        }
        #expect(peak > brightest * fill / 2, "周囲をほとんど受け取っていない")
        #expect(peak <= brightest * fill + 0.01, "受け取る量が周囲より多い")
    }

    // MARK: - 向き

    @Test("背景の上下が、周囲の上下と一致する")
    func theBackdropIsOrientedLikeTheSurroundings() throws {
        let canvas = try makeCanvas()
        try canvas.draw { canvas.background(.sky) }
        let pixels = try canvas.target.readPixels()

        let top = pixels[32, 1]
        let middle = pixels[32, 32]
        let bottom = pixels[32, 62]
        // 地平 (真ん中) がいちばん明るく、上へ行くほど青く、下へ行くほど暗い
        #expect(middle.red > top.red, "地平が上より明るくない")
        #expect(middle.red > bottom.red, "地平が下より明るくない")
        #expect(top.blue - top.red > bottom.blue - bottom.red, "上ほど青くなっていない")
    }

    @Test("映り込みの上下が、背景の上下と一致する")
    func theReflectionIsOrientedLikeTheBackdrop() throws {
        // 背景と映り込みが別々の式から出ていると、ここで上下が食い違う
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(.sky)
            canvas.noStroke()
            canvas.surroundings(.sky)
            canvas.metalness(1)
            canvas.fill(.opaque(red: 0.9, green: 0.9, blue: 0.9))
            canvas.push()
            canvas.translate(32, 32, 0)
            canvas.sphere(26)
            canvas.pop()
        }
        let pixels = try canvas.target.readPixels()
        let sphere = topAndBottom(pixels)
        let backdrop = (top: pixels[2, 2], bottom: pixels[2, 62])

        // 球の上は空、下は地面。背景と同じ向きになっている
        #expect(sphere.top.blue - sphere.top.red > sphere.bottom.blue - sphere.bottom.red)
        #expect(backdrop.top.blue - backdrop.top.red > backdrop.bottom.blue - backdrop.bottom.red)
    }

    // MARK: - 他の設定を書き換えない

    @Test("周囲を置いても、他の設定は 1 つも変わらない")
    func placingSurroundingsChangesNothingElse() throws {
        // 「置いたら明るさの写し方も変える」といった親切を入れない。絵が変わった
        // 理由は、いつも呼び出した行から読めるようにする
        let canvas = try makeCanvas()
        canvas.exposure(1.4)
        canvas.toneMapping(.roll)
        try canvas.draw {
            canvas.ambientLight(.opaque(red: 0.2, green: 0.2, blue: 0.2))
            canvas.metalness(0.5)
            let lightsBefore = canvas.activeLights.count
            let materialBefore = canvas.currentMaterial

            canvas.surroundings(.sky)

            #expect(canvas.activeLights.count == lightsBefore)
            #expect(canvas.currentMaterial == materialBefore)
            #expect(canvas.target.brightness.exposure == 1.4)
            #expect(canvas.target.brightness.toneMapping == .roll)
        }
    }

    @Test("置くのと背景に描くのは別々に選べる")
    func placingAndDrawingAreSeparate() throws {
        // 背景にだけ出す (映り込みには効かない)
        let backdropOnly = try sphere(try makeCanvas()) {
            $0.background(.sky)
            $0.ambientLight(.opaque(red: 0.2, green: 0.2, blue: 0.2))
            $0.metalness(1)
        }
        let (top, bottom) = topAndBottom(backdropOnly)
        #expect(abs(top.blue - bottom.blue) < 0.01, "背景を描いただけで映り込んでいる")

        // 置くだけ (背景には出ない)
        let placedOnly = try sphere(try makeCanvas()) { $0.surroundings(.sky) }
        #expect(placedOnly[2, 2].blue < 0.01, "置いただけで背景に出ている")
    }

    // MARK: - 寿命と壊れた入力

    @Test("周囲はフレームを越えない")
    func surroundingsDoNotCrossFrames() throws {
        let canvas = try makeCanvas()
        _ = try sphere(canvas) { $0.surroundings(.sky) }
        let second = try sphere(canvas) { _ in }
        // 2 フレーム目は真っ黒 (光も周囲も無い面は塗り 1 色だが、背景が黒なので
        // 球は塗りのまま出る)。前のフレームの周囲が残っていれば上下に色が付く
        let (top, bottom) = topAndBottom(second)
        #expect(abs(top.blue - bottom.blue) < 0.001)
    }

    @Test("初期化のときに置いた周囲は、どのフレームにも属さないので無視される")
    func surroundingsOutsideAFrameAreIgnored() throws {
        let canvas = try makeCanvas()
        canvas.surroundings(.sky)
        #expect(canvas.activeSurroundings == nil)
    }

    @Test("数でない値・負の色では、周囲を変えない")
    func brokenSurroundingsAreIgnored() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.surroundings(.sky)
            canvas.surroundings(
                Surroundings(
                    top: .opaque(red: .nan, green: 0, blue: 0), horizon: .opaque(red: 0, green: 0, blue: 0),
                    bottom: .opaque(red: 0, green: 0, blue: 0)))
            canvas.surroundings(
                Surroundings(
                    top: .opaque(red: -1, green: 0, blue: 0), horizon: .opaque(red: 0, green: 0, blue: 0),
                    bottom: .opaque(red: 0, green: 0, blue: 0)))
            #expect(canvas.activeSurroundings == .sky)
        }
    }

    // MARK: - 強さ

    @Test("強さは色で表す — 掛けた分だけ明るくなる")
    func strengthIsExpressedAsColor() throws {
        // 光と同じ規範。強さを表す別の数を持たない
        let full = try sphere(try makeCanvas()) { $0.surroundings(.sky) }
        let half = try sphere(try makeCanvas()) { $0.surroundings(.sky.scaled(by: 0.5)) }
        let point = (x: 32, y: 10)
        #expect(abs(full[point.x, point.y].red / 2 - half[point.x, point.y].red) < 0.005)
        #expect(half[point.x, point.y].red > 0.01)
    }
}
