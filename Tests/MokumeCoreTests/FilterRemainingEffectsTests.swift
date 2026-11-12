// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// Processing の `filter()` の残りの 4 つ (#3716): `.posterize(levels:)`・`.erode`・`.dilate`・`.opaque`。
///
/// 期待は Processing の式 (`PImage.filter` の POSTERIZE・`erode()`・`dilate()`・OPAQUE) と手で数えた画素から作り、
/// 検査の対象と同じ口から作らない。
@Suite(
    "filter の残りの効果 (posterize・erode・dilate・opaque)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct FilterRemainingEffectsTests {
    private func makeCanvas(width: Int, height: Int) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    /// `rows` の色を 1 画素ずつ画面に置いて `effects` を `filter()` で掛け、表示の 8 ビットで読む。
    private func filtered(_ rows: [[LinearRGBA]], _ effects: [Effect]) throws -> DisplayImage {
        let canvas = try makeCanvas(width: rows[0].count, height: rows.count)
        try canvas.draw {
            for (y, row) in rows.enumerated() {
                for (x, color) in row.enumerated() { canvas.set(x, y, color) }
            }
            canvas.filter(effects)
        }
        return try canvas.target.encodeForDisplay()
    }

    /// 効果を掛けずに置いた 1 画素の読み。**表示の 8 ビットは Display P3 で書かれる**ので、sRGB の原色で書いた
    /// 色 (赤 `(1, 0, 0)` など) は (255, 0, 0) にならない。期待はこの読みと比べる。
    private func plain(_ color: LinearRGBA) throws -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        try filtered([[color]], [])[0, 0]
    }

    private func gray(_ value: Float, alpha: Float = 1) -> LinearRGBA {
        .display(red: value, green: value, blue: value, alpha: alpha)
    }

    private let black = LinearRGBA.display(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.display(red: 1, green: 1, blue: 1)
    private let red = LinearRGBA.display(red: 1, green: 0, blue: 0)
    private let green = LinearRGBA.display(red: 0, green: 1, blue: 0)

    // MARK: - posterize (完了条件 1)

    @Test("明るさ 30・60・90 の灰を 2 段にすると、黒・白・白。元の画像は変わらない")
    func posterizeTwoLevels() throws {
        let canvas = try makeCanvas(width: 4, height: 4)
        let source = try canvas.createImage(3, 1)
        let grays = [gray(0.3), gray(0.6), gray(0.9)]
        for (x, color) in grays.enumerated() { source.set(x, 0, color) }
        #expect(grays.map { brightness($0).rounded() } == [30, 60, 90], "入力の物差しが brightness でない")
        let before = (0..<3).map { source.get($0, 0) }

        let result = source.filtered([.posterize(levels: 2)])
        #expect(result.get(0, 0) == LinearRGBA.linear(red: 0, green: 0, blue: 0), "30 が黒でない")
        #expect(result.get(1, 0) == LinearRGBA.linear(red: 1, green: 1, blue: 1), "60 が白でない")
        #expect(result.get(2, 0) == LinearRGBA.linear(red: 1, green: 1, blue: 1), "90 が白でない")
        #expect((0..<3).map { source.get($0, 0) } == before, "元の画像が変わった")
    }

    /// Processing の式 (8 ビットの整数): `(((v * levels) >> 8) * 255) / (levels - 1)`。
    private static func processingPosterize(_ value: Int, _ levels: Int) -> Int {
        ((value * levels) >> 8) * 255 / (levels - 1)
    }

    @Test("8 ビットの灰は、0…255 の全部で Processing の POSTERIZE と同じ値になる", arguments: [2, 3, 4, 7, 16, 255, 256])
    func posterizeMatchesProcessingOnEveryGray(levels: Int) throws {
        let row = (0...255).map { gray(Float($0) / 255) }
        let image = try filtered([row], [.posterize(levels: levels)])
        var wrong: [String] = []
        for v in 0...255 {
            let expected = Self.processingPosterize(v, levels)
            let got = image[v, 0]
            if got != (UInt8(expected), UInt8(expected), UInt8(expected), 255) { wrong.append("\(v)→\(got.red) (期待 \(expected))") }
        }
        #expect(wrong.isEmpty, "levels \(levels) で違う灰: \(wrong.prefix(6))")
    }

    @Test("チャンネルごとに段に切り、半透明は戻した色で切ってアルファを動かさない。不透明度 0 はそのまま")
    func posterizeWorksPerChannelAndKeepsTheAlpha() throws {
        let mixed = LinearRGBA.display(red: 0.8, green: 0.3, blue: 0.55)
        let half = gray(0.6, alpha: 0.5)
        let image = try filtered([[mixed, half, LinearRGBA.display(red: 0, green: 0, blue: 0, alpha: 0)]], [.posterize(levels: 2)])
        #expect(image[0, 0] == (try plain(.display(red: 1, green: 0, blue: 1))), "\(image[0, 0])")
        #expect(image[1, 0].red == 255 && abs(Int(image[1, 0].alpha) - 128) <= 1, "\(image[1, 0])")
        #expect(image[2, 0] == (0, 0, 0, 0), "透明が塗られた")
    }

    @Test("2 未満の段数は効かない (0・1・負)。絵は 1 ビットも変わらない", arguments: [0, 1, -3, Int.min])
    func posterizeBelowTwoDoesNothing(levels: Int) throws {
        let row = [gray(0.3), gray(0.6), red, gray(0.6, alpha: 0.5)]
        let plain = try filtered([row], [])
        let image = try filtered([row], [.posterize(levels: levels)])
        #expect(image.bytes == plain.bytes)
    }

    // MARK: - erode・dilate (完了条件 2)

    private var centreLit: [[LinearRGBA]] {
        [[black, black, black], [black, white, black], [black, black, black]]
    }

    @Test("中央だけ白い 3×3 に dilate を掛けると、中央と上下左右の 4 画素が白になり、角は黒のまま")
    func dilateGrowsTheLightCentre() throws {
        let image = try filtered(centreLit, [.dilate])
        let lit = Set((0..<3).flatMap { y in (0..<3).compactMap { x in image[x, y].red == 255 ? "\(x),\(y)" : nil } })
        #expect(lit == ["1,0", "0,1", "1,1", "2,1", "1,2"])
        #expect(image[0, 0] == (0, 0, 0, 255) && image[2, 2] == (0, 0, 0, 255))
    }

    @Test("中央だけ白い 3×3 に erode を掛けると、中央が黒になる")
    func erodeRemovesTheLightCentre() throws {
        let image = try filtered(centreLit, [.erode])
        for y in 0..<3 {
            for x in 0..<3 { #expect(image[x, y] == (0, 0, 0, 255), "\(x),\(y)") }
        }
    }

    @Test("明るさは輝度の加重で比べ、画素を丸ごと選ぶ: dilate は赤を緑に、erode は緑を赤にする")
    func morphologyUsesTheProcessingLuma() throws {
        let dilated = try filtered([[red, green]], [.dilate])
        let (redRead, greenRead) = (try plain(red), try plain(green))
        #expect(dilated[0, 0] == greenRead, "dilate の赤: \(dilated[0, 0])")
        #expect(dilated[1, 0] == greenRead)
        let eroded = try filtered([[red, green]], [.erode])
        #expect(eroded[1, 0] == redRead, "erode の緑: \(eroded[1, 0])")
        #expect(eroded[0, 0] == redRead)
        // 成分ごとに最大を取ると黄 (255, 255, 0) になる — 丸ごと選んでいれば出ない
        let mixed = try filtered([[red, LinearRGBA.display(red: 0, green: 0.9, blue: 0)]], [.dilate])
        #expect(mixed[0, 0] == mixed[1, 0], "成分ごとに最大を取った: \(mixed[0, 0])")
        // 物差しが 3 成分の最大 (brightness) なら赤 (1) が暗い緑 (0.6) より明るいが、輝度の加重では緑
        // (0.6 × 151 > 77) が明るい
        let dimGreen = LinearRGBA.display(red: 0, green: 0.6, blue: 0)
        let dimRead = try plain(dimGreen)
        let grown = try filtered([[red, dimGreen]], [.dilate])
        #expect(grown[0, 0] == dimRead && grown[1, 0] == dimRead, "dilate: \(grown[0, 0])・\(grown[1, 0])")
        let shrunk = try filtered([[red, dimGreen]], [.erode])
        #expect(shrunk[0, 0] == redRead && shrunk[1, 0] == redRead, "erode: \(shrunk[0, 0])・\(shrunk[1, 0])")
    }

    @Test("半透明の画素も乗算を戻さずに比べる: 不透明度 0.3 の白は、不透明な 0.7 の灰より暗い")
    func semiTransparentPixelsCompareAsPremultiplied() throws {
        let faintWhite = LinearRGBA.display(red: 1, green: 1, blue: 1, alpha: 0.3)
        let grayRead = try plain(gray(0.7))
        let image = try filtered([[faintWhite, gray(0.7)]], [.dilate])
        #expect(image[0, 0] == grayRead && image[1, 0] == grayRead, "\(image[0, 0])・\(image[1, 0])")
    }

    @Test("乗算済みのまま比べるので、透明な画素は暗い側。白の隣の透明は dilate で白に、erode では白が透明になる")
    func transparentPixelsAreDark() throws {
        let clear = LinearRGBA.display(red: 0, green: 0, blue: 0, alpha: 0)
        let dilated = try filtered([[white, clear]], [.dilate])
        #expect(dilated[1, 0] == (255, 255, 255, 255), "\(dilated[1, 0])")
        let eroded = try filtered([[white, clear]], [.erode])
        #expect(eroded[0, 0] == (0, 0, 0, 0), "\(eroded[0, 0])")
    }

    // MARK: - opaque (完了条件 3)

    @Test("半透明の赤は不透明の同じ赤になり、不透明度 0 は黒の不透明になる")
    func opaqueKeepsTheColour() throws {
        let halfRed = LinearRGBA.display(red: 1, green: 0, blue: 0, alpha: 0.5)
        let clear = LinearRGBA.display(red: 0, green: 0, blue: 0, alpha: 0)
        let image = try filtered([[halfRed, clear, red]], [.opaque])
        let redRead = try plain(red)
        #expect(image[0, 0] == redRead, "\(image[0, 0])")
        #expect(image[1, 0] == (0, 0, 0, 255), "\(image[1, 0])")
        #expect(image[2, 0] == redRead)
    }

    // MARK: - 画面と画像で同じ (完了条件 4)

    @Test("filter() (画面) と Image.filtered() は同じ値を出す", arguments: 0..<4)
    func screenAndImageAgree(index: Int) throws {
        let effect: Effect = [.posterize(levels: 3), .erode, .dilate, .opaque][index]
        let colors: [[LinearRGBA]] = [
            [gray(0.2), red, gray(0.7, alpha: 0.4), white],
            [green, gray(0.45), LinearRGBA.display(red: 0.1, green: 0.6, blue: 0.9), black],
            [LinearRGBA.display(red: 0, green: 0, blue: 0, alpha: 0), white, gray(0.8), red],
        ]
        let canvas = try makeCanvas(width: 4, height: 3)
        let source = try canvas.createImage(4, 3)
        try canvas.draw {
            for (y, row) in colors.enumerated() {
                for (x, color) in row.enumerated() {
                    canvas.set(x, y, color)
                    source.set(x, y, color)
                }
            }
            canvas.filter([effect])
        }
        let result = source.filtered([effect])
        for y in 0..<3 {
            for x in 0..<4 {
                #expect(canvas.get(x, y) == result.get(x, y), "\(effect.name) の \(x),\(y)")
            }
        }
    }
}
