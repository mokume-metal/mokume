// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeTestSupport
import Testing

@testable import MokumeCore

// `Image.cropped(x:y:width:height:)` と `Image.resized(width:height:)` ([#3711])。
//
// [#3711]: https://github.com/mokume-metal/mokume/issues/3711

/// 読み方の重み (GPU を要さない)。
@Suite("大きさを変えるときの重み")
struct ImageResamplingTests {
    private func sums(_ weights: [[(index: Int, weight: Float)]]) -> [Float] {
        weights.map { $0.reduce(0) { $0 + $1.weight } }
    }

    @Test("縮める向きは覆う長さの割合で混ぜる (2 → 1 は半々、3 → 2 は 2/3 と 1/3)")
    func shrinkingAveragesByCoverage() {
        let half = ImageResampling.weights(from: 2, to: 1)
        #expect(half.count == 1)
        #expect(half[0].map(\.index) == [0, 1] && half[0].map(\.weight) == [0.5, 0.5])

        let thirds = ImageResampling.weights(from: 3, to: 2)
        #expect(thirds[0].map(\.index) == [0, 1] && thirds[1].map(\.index) == [1, 2])
        #expect(abs(thirds[0][0].weight - 2.0 / 3) < 1e-6 && abs(thirds[0][1].weight - 1.0 / 3) < 1e-6)
        for sum in sums(ImageResampling.weights(from: 7, to: 3)) { #expect(abs(sum - 1) < 1e-6) }
    }

    @Test("広げる向きは中心どうしを直線で補い、端は端の画素で延ばす")
    func enlargingInterpolatesBetweenCentres() {
        // 2 → 4: 新しい中心は元の -0.25 (端へ寄せて 0)・0.25・0.75・1.25 (端へ寄せて 1)
        let weights = ImageResampling.weights(from: 2, to: 4)
        #expect(weights[0].map(\.index) == [0] && weights[3].map(\.index) == [1])
        #expect(weights[1].map(\.index) == [0, 1] && weights[1].map(\.weight) == [0.75, 0.25])
        #expect(weights[2].map(\.index) == [0, 1] && weights[2].map(\.weight) == [0.25, 0.75])
        for sum in sums(ImageResampling.weights(from: 3, to: 11)) { #expect(abs(sum - 1) < 1e-6) }
        // 1 画素からはどこも同じ 1 画素を読む
        #expect(ImageResampling.weights(from: 1, to: 5).allSatisfy { $0.map(\.index) == [0] })
    }

    @Test("同じ大きさは元の画素をそのまま読む")
    func theSameSizeReadsEachPixel() {
        let weights = ImageResampling.weights(from: 4, to: 4)
        #expect(weights.map { $0.map(\.index) } == [[0], [1], [2], [3]])
        #expect(weights.allSatisfy { $0.map(\.weight) == [1] })
    }
}

/// 切り出しと大きさの変更 (GPU を要する)。
@Suite(
    "絵の切り出しと大きさの変更",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ImageRegionTests {
    private let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    private let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)
    private let teal = LinearRGBA.linear(red: 0.1, green: 0.4, blue: 0.3)
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
    }

    private func same(_ a: LinearRGBA, _ b: LinearRGBA, within tolerance: Float = 0) -> Bool {
        abs(a.red - b.red) <= tolerance && abs(a.green - b.green) <= tolerance
            && abs(a.blue - b.blue) <= tolerance && abs(a.alpha - b.alpha) <= tolerance
    }

    /// 4x2 の絵。左の 2x2 が赤、右の 2x2 が青 (完了条件 1・2 の絵)。
    private func redAndBlue(_ canvas: Canvas) throws -> Image {
        let image = try canvas.createImage(4, 2)
        for y in 0..<2 {
            for x in 0..<4 { image.set(x, y, x < 2 ? red : blue) }
        }
        return image
    }

    private func every(_ image: Image, _ check: (Int, Int, LinearRGBA) -> Bool) -> Bool {
        (0..<image.height).allSatisfy { y in (0..<image.width).allSatisfy { x in check(x, y, image.get(x, y)) } }
    }

    // MARK: - cropped

    @Test("左上の 2x2 を切り出すと全画素が赤の 2x2 になり、元は変わらない")
    func croppingTheLeftHalf() throws {
        let canvas = try makeCanvas()
        let image = try redAndBlue(canvas)
        let corner = try image.cropped(x: 0, y: 0, width: 2, height: 2)
        #expect(corner !== image)
        #expect(corner.width == 2 && corner.height == 2)
        #expect(every(corner) { _, _, color in same(color, red) })
        #expect(image.width == 4 && image.height == 2)
        #expect(every(image) { x, _, color in same(color, x < 2 ? red : blue) }, "元が変わった")
    }

    @Test("絵をはみ出す範囲は透明になる (左が青、右が透明)")
    func croppingBeyondTheEdgeIsTransparent() throws {
        let canvas = try makeCanvas()
        let image = try redAndBlue(canvas)
        let edge = try image.cropped(x: 3, y: 0, width: 2, height: 1)
        #expect(edge.width == 2 && edge.height == 1)
        #expect(same(edge.get(0, 0), blue))
        #expect(same(edge.get(1, 0), .transparent))
        // 負の位置も、上と左へはみ出した分が透明
        let before = try image.cropped(x: -1, y: -1, width: 2, height: 2)
        #expect(same(before.get(0, 0), .transparent) && same(before.get(1, 0), .transparent))
        #expect(same(before.get(0, 1), .transparent) && same(before.get(1, 1), red))
    }

    @Test("絵とまったく重ならない範囲は、投げずに全体が透明の絵を返す (桁の溢れる位置も)")
    func croppingOutsideIsAllTransparent() throws {
        let canvas = try makeCanvas()
        let image = try redAndBlue(canvas)
        for (x, y) in [(10, 0), (0, -5), (Int.max, 0), (0, Int.max - 1), (Int.min, Int.min)] {
            let outside = try image.cropped(x: x, y: y, width: 3, height: 2)
            #expect(every(outside) { _, _, color in same(color, .transparent) }, "(\(x), \(y))")
        }
    }

    @Test("作業空間の値のまま写す (8 bit を経由しない)")
    func croppingKeepsWorkingValues() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(3, 1)
        let bright = LinearRGBA.linear(red: 2.5, green: 0.123, blue: 0.0)
        let half = LinearRGBA(premultipliedRed: 0.1, green: 0.05, blue: 0, alpha: 0.5)
        image.set(1, 0, bright)
        image.set(2, 0, half)
        let piece = try image.cropped(x: 1, y: 0, width: 2, height: 1)
        #expect(same(piece.get(0, 0), image.get(1, 0)))
        #expect(same(piece.get(1, 0), image.get(2, 0)))
        #expect(piece.get(0, 0).red > 2)
    }

    // MARK: - resized

    @Test("黒と白の 2x1 を 1x1 へ縮めると、光の量の平均 (線形で 0.5) になる")
    func shrinkingAveragesLight() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(2, 1)
        image.set(0, 0, black)
        image.set(1, 0, white)
        let small = try image.resized(width: 1, height: 1)
        #expect(small.width == 1 && small.height == 1)
        let color = small.get(0, 0)
        #expect(abs(color.red - 0.5) < 0.001 && abs(color.green - 0.5) < 0.001 && abs(color.blue - 0.5) < 0.001)
        #expect(abs(color.alpha - 1) < 0.001)
        // エンコードした値のまま平均すると 0.5 のエンコード (約 0.214 の光) になる。そうなっていない
        #expect(abs(color.red - 0.214) > 0.1)
    }

    @Test("黒と白の 2x1 を 4x1 へ広げると、中心どうしの間を直線で補う (0・0.25・0.75・1)")
    func enlargingInterpolates() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(2, 1)
        image.set(0, 0, black)
        image.set(1, 0, white)
        let wide = try image.resized(width: 4, height: 1)
        let reds = (0..<4).map { wide.get($0, 0).red }
        for (got, want) in zip(reds, [Float(0), 0.25, 0.75, 1]) {
            #expect(abs(got - want) < 0.001, "\(reds)")
        }
    }

    @Test("全面が同じ色の絵は、広げても縮めても縦横比を変えても全画素が同じ色のまま")
    func aFlatImageStaysFlat() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(2, 2)
        image.fill(teal)
        let expected = image.get(0, 0)
        for (width, height) in [(5, 7), (1, 1), (1, 3), (8, 1), (2, 2), (16, 16)] {
            let resized = try image.resized(width: width, height: height)
            #expect(resized.width == width && resized.height == height)
            #expect(every(resized) { _, _, color in same(color, expected) }, "\(width)x\(height)")
        }
    }

    @Test("透けた画素の色は縁へにじまない (乗算済みのまま混ぜる)")
    func transparencyDoesNotBleed() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(2, 1)
        image.set(0, 0, red)
        image.set(1, 0, .transparent)
        let color = try image.resized(width: 1, height: 1).get(0, 0)
        #expect(abs(color.red - 0.5) < 0.001 && abs(color.alpha - 0.5) < 0.001)
        #expect(color.green == 0 && color.blue == 0)
    }

    @Test("同じ大きさなら copy() と同じ画素で、元は変わらない")
    func theSameSizeIsACopy() throws {
        let canvas = try makeCanvas()
        let image = try redAndBlue(canvas)
        image.set(1, 1, teal)
        let original = image.copy()
        let resized = try image.resized(width: 4, height: 2)
        #expect(resized !== image)
        #expect(every(resized) { x, y, color in same(color, original.get(x, y)) })
        _ = try image.resized(width: 9, height: 1)
        #expect(every(image) { x, y, color in same(color, original.get(x, y)) }, "元が変わった")
    }

    // MARK: - 断る

    @Test("幅か高さが 1 を割るか上限を越えると unplaceable を投げ、1x1 へ丸めない")
    func unplaceableSizesAreRefused() throws {
        let canvas = try makeCanvas()
        let image = try redAndBlue(canvas)
        let over = RenderDevice.maxTextureSide + 1
        for (width, height) in [(0, 1), (1, 0), (-1, 2), (2, -3), (0, 0), (over, 1), (1, over)] {
            #expect(throws: ImageFailure.unplaceable(width: width, height: height)) {
                try image.cropped(x: 0, y: 0, width: width, height: height)
            }
            #expect(throws: ImageFailure.unplaceable(width: width, height: height)) {
                try image.resized(width: width, height: height)
            }
        }
        // 境目: 1x1 は受ける
        #expect(same(try image.cropped(x: 2, y: 0, width: 1, height: 1).get(0, 0), image.get(2, 0)))
        #expect(try image.resized(width: 1, height: 1).width == 1)
    }

    // MARK: - 写しの独立

    @Test("返した絵は、元へ後から書き込まれても変わらない (カメラの次の 1 枚と同じ書き込み)")
    func resultsAreIndependentOfLaterWrites() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(2, 2)
        image.write(DisplayImage(width: 2, height: 2, bytes: [UInt8](repeating: 255, count: 2 * 2 * 4)))
        let piece = try image.cropped(x: 0, y: 0, width: 1, height: 1)
        let small = try image.resized(width: 1, height: 1)
        let before = (piece.get(0, 0), small.get(0, 0))
        // カメラの `image` は、次の 1 枚を同じ絵へ書き込む
        image.write(DisplayImage(width: 2, height: 2, bytes: [UInt8](repeating: 0, count: 2 * 2 * 4)))
        #expect(same(image.get(0, 0), .transparent))
        #expect(same(piece.get(0, 0), before.0) && same(small.get(0, 0), before.1))
        #expect(piece.get(0, 0).alpha == 1)
    }

    @Test("大きな入力 (復号を遅らせるもの) からも、書き換えを含めた値で切り出す")
    func croppingALargeInput() throws {
        let canvas = try makeCanvas()
        let side = 1024
        #expect(side * side >= Image.metalInputMinimumPixels)
        let image = try canvas.createImage(side, side)
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for index in 0..<(side * side) {
            bytes[index * 4] = UInt8(index % side % 256)
            bytes[index * 4 + 1] = UInt8(index / side % 256)
            bytes[index * 4 + 2] = 40
        }
        image.write(DisplayImage(width: side, height: side, bytes: bytes))
        image.set(1000, 1001, teal)
        let piece = try image.cropped(x: 998, y: 1000, width: 4, height: 4)
        #expect(same(piece.get(2, 1), teal, within: 0.001), "書き換えが写らなかった")
        #expect(same(piece.get(0, 0), image.get(998, 1000)))
        #expect(same(piece.get(3, 3), image.get(1001, 1003)))
    }
}
