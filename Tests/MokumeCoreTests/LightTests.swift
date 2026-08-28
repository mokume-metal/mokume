// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 光を当てたときに何が起きるかの検査。GPU を要する。
///
/// 光の API は「単位」「向き」「個数」で黙って壊れる — どれも例外を出さず、絵が
/// 少し暗い・少し違う向きになるだけである。だから**画素の意味**で確かめる。
@Suite(
    "光",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct LightTests {
    private let black = LinearRGBA.opaque(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.opaque(red: 1, green: 1, blue: 1)
    private let grey = LinearRGBA.opaque(red: 0.5, green: 0.5, blue: 0.5)

    private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }

    private func pixels(of canvas: Canvas) throws -> DisplayImage {
        try canvas.target.encodeForDisplay()
    }

    /// 中央に球を 1 つ置く絵。光の当て方だけを差し替えられる形にしてある。
    private func sphereScene(_ canvas: Canvas, light: (Canvas) -> Void) throws {
        try canvas.draw {
            canvas.background(black)
            light(canvas)
            canvas.fill(white)
            canvas.push()
            canvas.translate(32, 32, 0)
            canvas.sphere(22)
            canvas.pop()
        }
    }

    // MARK: - 向き

    @Test("上から差す光で、上を向いた面が明るくなる")
    func lightFromAboveBrightensUpwardFaces() throws {
        let canvas = try makeCanvas()
        // 縦軸は下向きなので、上から差す光が進む向きは +y
        try sphereScene(canvas) { $0.directionalLight(white, 0, 1, 0) }

        let image = try pixels(of: canvas)
        let above = Int(image[32, 18].red)
        let below = Int(image[32, 46].red)
        #expect(above > below + 40)
    }

    @Test("下から差す光では、逆に下側が明るくなる")
    func lightFromBelowBrightensDownwardFaces() throws {
        let canvas = try makeCanvas()
        try sphereScene(canvas) { $0.directionalLight(white, 0, -1, 0) }

        let image = try pixels(of: canvas)
        #expect(Int(image[32, 46].red) > Int(image[32, 18].red) + 40)
    }

    @Test("光の向きを決める引数が、絵に向きとして現れる")
    func lightDirectionShowsInThePicture() throws {
        // 反転して見分けが付かない絵は、引数の意味を写していない。
        // 「触っていない絵の退行」ではなく「その絵が何を写しているか」の検査である
        let canvas = try makeCanvas()
        try sphereScene(canvas) { $0.directionalLight(white, -0.5, 0.8, -0.3) }
        let image = try pixels(of: canvas)

        #expect(differingFraction(image, flip: .vertical) > 0.05)
        #expect(differingFraction(image, flip: .horizontal) > 0.05)
    }

    // MARK: - 単位

    @Test("光を 1 つも置かなければ、立体は塗り 1 色のまま")
    func noLightsMeansFlatFill() throws {
        let canvas = try makeCanvas()
        try sphereScene(canvas) { _ in }

        let image = try pixels(of: canvas)
        #expect(image[32, 18] == (255, 255, 255, 255))
        #expect(image[32, 46] == (255, 255, 255, 255))
    }

    @Test("底上げの光だけを置くと、面はその色の分だけ明るくなる")
    func ambientLightScalesTheSurfaceColor() throws {
        let canvas = try makeCanvas()
        try sphereScene(canvas) { $0.ambientLight(grey) }

        // 白い面 × 0.5 の光 = 線形で 0.5。表示のエンコードを通るので 128 ではない
        let value = try pixels(of: canvas)[32, 32].red
        #expect(value > 150 && value < 210)
    }

    @Test("1 を超える色の光は、白い面を白へ飽和させる")
    func lightBrighterThanWhiteSaturates() throws {
        let canvas = try makeCanvas()
        try sphereScene(canvas) { $0.ambientLight(.opaque(red: 4, green: 4, blue: 4)) }

        #expect(try pixels(of: canvas)[32, 32] == (255, 255, 255, 255))
    }

    // MARK: - 変換

    @Test("変換の中で置いた光は、その変換に従う")
    func lightFollowsTheTransform() throws {
        // 回した中で「上から」置いた光は、回った先の向きから差す
        let canvas = try makeCanvas()
        try sphereScene(canvas) { canvas in
            canvas.push()
            canvas.rotateZ(.pi)  // 上下が入れ替わる
            canvas.directionalLight(self.white, 0, 1, 0)
            canvas.pop()
        }

        let image = try pixels(of: canvas)
        #expect(Int(image[32, 46].red) > Int(image[32, 18].red) + 40)
    }

    // MARK: - 個数

    @Test("たくさん置いても、全部の光が効く")
    func everyLightCounts() throws {
        // 上限を持たないので、置いた数だけ明るくなる。黙って捨てられる光は無い
        let dim = LinearRGBA.opaque(red: 0.05, green: 0.05, blue: 0.05)

        let few = try makeCanvas()
        try sphereScene(few) { canvas in
            for _ in 0..<2 { canvas.ambientLight(dim) }
        }

        let many = try makeCanvas()
        try sphereScene(many) { canvas in
            for _ in 0..<32 { canvas.ambientLight(dim) }
        }

        #expect(try Int(pixels(of: many)[32, 32].red) > (try Int(pixels(of: few)[32, 32].red)) + 40)
    }

    @Test("光は、置いたあとの立体にだけ効く")
    func lightAppliesToWhatComesAfter() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            canvas.push()
            canvas.translate(18, 32, 0)
            canvas.sphere(12)
            canvas.pop()

            canvas.ambientLight(grey)
            canvas.push()
            canvas.translate(46, 32, 0)
            canvas.sphere(12)
            canvas.pop()
        }

        let image = try pixels(of: canvas)
        // 先に置いたほうは光を受けていない = 塗りのまま
        #expect(image[18, 32] == (255, 255, 255, 255))
        #expect(image[46, 32].red < 255)
    }

    @Test("光を取り除くと、以降の立体は塗り 1 色へ戻る")
    func noLightsRestoresFlatFill() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.ambientLight(grey)
            canvas.fill(white)
            canvas.push()
            canvas.translate(18, 32, 0)
            canvas.sphere(12)
            canvas.pop()

            canvas.noLights()
            canvas.push()
            canvas.translate(46, 32, 0)
            canvas.sphere(12)
            canvas.pop()
        }

        let image = try pixels(of: canvas)
        #expect(image[18, 32].red < 255)
        #expect(image[46, 32] == (255, 255, 255, 255))
    }

    // MARK: - 寿命

    @Test("光はフレームを越えない")
    func lightsDoNotSurviveTheFrame() throws {
        let canvas = try makeCanvas()
        try sphereScene(canvas) { $0.ambientLight(self.grey) }
        // 2 フレーム目は光を置かない。越えていれば暗いまま出る
        try sphereScene(canvas) { _ in }

        #expect(try pixels(of: canvas)[32, 32] == (255, 255, 255, 255))
    }

    @Test("フレームの外で置いた光は無視される")
    func lightsOutsideAFrameAreIgnored() throws {
        let canvas = try makeCanvas()
        // 初期化のときに置いた光はどのフレームにも属さない (警告して無視する)
        canvas.ambientLight(grey)
        try sphereScene(canvas) { _ in }

        #expect(try pixels(of: canvas)[32, 32] == (255, 255, 255, 255))
    }

    // MARK: - 広がり

    @Test("広がりを持つ光は、外側には当たらない")
    func spotLightStopsAtItsCone() throws {
        let canvas = try makeCanvas(width: 96, height: 64)
        try canvas.draw {
            canvas.background(black)
            canvas.fill(white)
            // 左側の真上から、狭い広がりで下向きに当てる
            canvas.spotLight(.opaque(red: 3, green: 3, blue: 3), 24, -40, 0, 0, 1, 0, angle: 0.5)
            canvas.push()
            canvas.translate(24, 32, 0)
            canvas.sphere(14)
            canvas.pop()
            canvas.push()
            canvas.translate(72, 32, 0)
            canvas.sphere(14)
            canvas.pop()
        }

        let image = try pixels(of: canvas)
        #expect(image[24, 22].red > 60)
        #expect(image[72, 22].red < 20)
    }

    // MARK: - 道具

    private enum Flip { case vertical, horizontal }

    /// 絵を反転して重ね、**どれだけの画素が違うか**を返す。
    private func differingFraction(_ image: DisplayImage, flip: Flip) -> Double {
        var differing = 0
        var counted = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let mirrored =
                    switch flip {
                    case .vertical: image[x, image.height - 1 - y]
                    case .horizontal: image[image.width - 1 - x, y]
                    }
                let here = image[x, y]
                counted += 1
                if abs(Int(here.red) - Int(mirrored.red)) > 8 { differing += 1 }
            }
        }
        return counted == 0 ? 0 : Double(differing) / Double(counted)
    }
}
