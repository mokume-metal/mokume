// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// `Image.readPixels()` (#3585)。絵の画素を一度に `PixelBuffer` で読む。GPU を要する。
///
/// 見るのは、`get(x, y)` と同じ値を並べること・左上原点の行優先であること・撮った時点の写しであること、
/// そして**復号を遅らせる大きな入力 (CPU 側に画素を展開していない状態)** も読めること。
@Suite(
    "絵の画素の一括読み出し",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ImageReadPixelsTests {
    private let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    private let teal = LinearRGBA.linear(red: 0.1, green: 0.4, blue: 0.3)

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
    }

    /// `components` の `(x, y)` の 4 成分を色にする。
    private func color(in buffer: PixelBuffer, _ x: Int, _ y: Int) -> LinearRGBA {
        let base = (y * buffer.width + x) * 4
        return LinearRGBA(
            premultipliedRed: Float(buffer.components[base]), green: Float(buffer.components[base + 1]),
            blue: Float(buffer.components[base + 2]), alpha: Float(buffer.components[base + 3]))
    }

    @Test("2x2 の絵を一括で読むと、全画素が get と一致し、先頭 4 成分は (0, 0) の色になる")
    func readsEveryPixelAsGetDoes() throws {
        let canvas = try makeCanvas()
        let picture = try canvas.createImage(2, 2)
        picture.set(0, 0, red)
        picture.set(1, 0, teal)
        picture.set(0, 1, LinearRGBA(premultipliedRed: 0.1, green: 0.05, blue: 0, alpha: 0.5))
        // 表示の範囲を超えた明るさも、作業空間のままで残る
        picture.set(1, 1, LinearRGBA(premultipliedRed: 2.5, green: 0, blue: 0, alpha: 1))

        let buffer = picture.readPixels()

        #expect(buffer.width == 2 && buffer.height == 2)
        #expect(buffer.components.count == 2 * 2 * 4)
        #expect(Array(buffer.components.prefix(4)) == [1, 0, 0, 1])
        for y in 0..<2 {
            for x in 0..<2 {
                #expect(color(in: buffer, x, y) == picture.get(x, y), "(\(x), \(y))")
                #expect(buffer[x, y] == picture.get(x, y), "(\(x), \(y)) の添字")
            }
        }
        #expect(buffer[1, 1].red == 2.5)
    }

    @Test("幅と高さが違う絵でも、行優先・左上原点で並ぶ (行と列を取り違えない)")
    func keepsRowMajorOrderOnANonSquarePicture() throws {
        let canvas = try makeCanvas()
        let picture = try canvas.createImage(3, 2)
        picture.set(2, 0, red)  // 1 行目の右端
        picture.set(0, 1, teal)  // 2 行目の左端

        let buffer = picture.readPixels()

        #expect(buffer.width == 3 && buffer.height == 2)
        #expect(Array(buffer.components[(2 * 4)..<(3 * 4)]) == [1, 0, 0, 1])
        #expect(color(in: buffer, 0, 1) == picture.get(0, 1))
    }

    @Test("1x1 の絵も読める")
    func readsASinglePixel() throws {
        let canvas = try makeCanvas()
        let picture = try canvas.createImage(1, 1)
        picture.set(0, 0, teal)
        let buffer = picture.readPixels()
        #expect(buffer.width == 1 && buffer.height == 1)
        #expect(color(in: buffer, 0, 0) == picture.get(0, 0))
    }

    @Test("撮った時点の写しで、読んだ後の書き換えは返した値に届かない")
    func isASnapshot() throws {
        let canvas = try makeCanvas()
        let picture = try canvas.createImage(2, 2)
        picture.set(0, 0, teal)
        let before = picture.readPixels()
        let taken = picture.get(0, 0)

        picture.set(0, 0, red)
        picture.fill(red)

        #expect(color(in: before, 0, 0) == taken)
        #expect(picture.readPixels() != before)
    }

    @Test("復号を遅らせる大きな入力と、その後の書き換えも読める (CPU 側に展開していない状態)")
    func readsALargeInputBeforeItIsUnpacked() throws {
        let canvas = try makeCanvas()
        let side = 1024  // 100 万画素以上は、入力を値として抱える大きさ
        #expect(side * side >= Image.metalInputMinimumPixels)
        let picture = try canvas.createImage(side, side)
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for index in 0..<(side * side) {
            bytes[index * 4] = UInt8(index % side % 256)
            bytes[index * 4 + 1] = UInt8(index / side % 256)
            bytes[index * 4 + 2] = 40
        }
        picture.write(DisplayImage(width: side, height: side, bytes: bytes))
        picture.set(10, 20, teal)

        // 読む前は展開していない。読み出しがそこを展開して読む
        #expect(picture.displayInput != nil)
        let buffer = picture.readPixels()

        // 展開せずに読むと成分が空で返る。添字で読む前に、並びの長さで先に落とす
        try #require(buffer.components.count == side * side * 4, "展開前の画素が読めなかった")
        #expect(buffer.width == side && buffer.height == side)
        #expect(color(in: buffer, 10, 20) == picture.get(10, 20), "書き換えが届かなかった")
        for (x, y) in [(0, 0), (255, 3), (1023, 1023), (300, 700)] {
            #expect(color(in: buffer, x, y) == picture.get(x, y), "(\(x), \(y))")
        }
        #expect(color(in: buffer, 300, 700) != color(in: buffer, 301, 700), "画素が均されている")
    }
}
