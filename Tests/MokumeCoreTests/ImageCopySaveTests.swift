// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// `Image.copy()` と `Image.save(_:)` (#2449)。GPU を要する。
@Suite(
    "絵の写しと保存",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ImageCopySaveTests {
    private let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    private let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)
    private let teal = LinearRGBA.linear(red: 0.1, green: 0.4, blue: 0.3)

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mokume-image-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func same(_ a: LinearRGBA, _ b: LinearRGBA, within tolerance: Float = 0) -> Bool {
        abs(a.red - b.red) <= tolerance && abs(a.green - b.green) <= tolerance
            && abs(a.blue - b.blue) <= tolerance && abs(a.alpha - b.alpha) <= tolerance
    }

    // MARK: - copy()

    @Test("写した後で片方を書き換えても、もう片方は変わらない (両方向)")
    func copyIsIndependent() throws {
        let canvas = try makeCanvas()
        let a = try canvas.createImage(4, 3)
        a.set(1, 1, teal)
        let b = a.copy()
        #expect(b !== a)
        #expect(b.width == 4 && b.height == 3)

        a.set(0, 0, red)
        #expect(same(b.get(0, 0), .transparent), "元への書き込みが写しに届いた")
        b.set(2, 2, blue)
        #expect(same(a.get(2, 2), .transparent), "写しへの書き込みが元に届いた")
        #expect(same(b.get(1, 1), a.get(1, 1)))
        a.fill(red)
        #expect(same(b.get(1, 1), a.get(1, 1)) == false, "元を塗りつぶしても写しは写した時点のまま")
        #expect(same(b.get(1, 1), teal, within: 0.001))
    }

    @Test("全画素が写した時点の値で、8 bit を経由しない (表示の範囲を超えた明るさも残る)")
    func copyKeepsEveryPixelInWorkingSpace() throws {
        let canvas = try makeCanvas()
        let a = try canvas.createImage(5, 4)
        for y in 0..<4 {
            for x in 0..<5 {
                a.set(x, y, .linear(red: Float(x) * 0.7, green: Float(y) * 0.3, blue: 0.123))
            }
        }
        a.set(2, 2, LinearRGBA(premultipliedRed: 0.1, green: 0.05, blue: 0, alpha: 0.5))
        let b = a.copy()
        for y in 0..<4 {
            for x in 0..<5 {
                #expect(same(b.get(x, y), a.get(x, y)), "(\(x), \(y))")
            }
        }
        // 2.8 は 8 bit の 255 を超える。8 bit を経由したなら 1.0 で止まる
        #expect(b.get(4, 0).red > 2.5)
    }

    @Test("大きな入力 (復号を遅らせるもの) とその後の書き換えも、論理的な値のまま写る")
    func copyOfALargeInputIncludesItsEdits() throws {
        let canvas = try makeCanvas()
        let side = 1024  // 100 万画素以上は、入力を値として抱える大きさ
        #expect(side * side >= Image.metalInputMinimumPixels)
        let a = try canvas.createImage(side, side)
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for index in 0..<(side * side) {
            bytes[index * 4] = UInt8(index % side % 256)
            bytes[index * 4 + 1] = UInt8(index / side % 256)
            bytes[index * 4 + 2] = 40
        }
        a.write(DisplayImage(width: side, height: side, bytes: bytes))
        a.set(10, 20, teal)
        let b = a.copy()
        #expect(same(b.get(10, 20), teal, within: 0.001), "書き換えが写らなかった")
        for (x, y) in [(0, 0), (255, 3), (1023, 1023), (300, 700)] {
            #expect(same(b.get(x, y), a.get(x, y)), "(\(x), \(y))")
        }
        a.set(300, 700, red)
        #expect(same(b.get(300, 700), red) == false)
    }

    // MARK: - save(_:)

    @Test("PNG を書き、読み戻すと 8 bit の丸めの内で元と一致する (透けた画素は透けたまま)")
    func saveRoundTrips() throws {
        try withTemporaryDirectory { directory in
            let canvas = try makeCanvas()
            let a = try canvas.createImage(4, 2)
            let half = LinearRGBA(premultipliedRed: 0.1, green: 0.05, blue: 0.0, alpha: 0.5)
            a.set(0, 0, teal)
            a.set(1, 0, half)
            a.set(2, 0, red)
            a.set(3, 0, .transparent)
            a.set(0, 1, .linear(red: 0.5, green: 0.5, blue: 0.5))
            // **途中のディレクトリは無ければ作る** (スケッチの save と同じ)
            let path = directory.appendingPathComponent("out/deep/x.png").path
            try a.save(path)
            #expect(FileManager.default.fileExists(atPath: path), "書き終えてから返らない")

            let back = try canvas.loadImage(path)
            #expect(back.width == 4 && back.height == 2)
            for (x, y) in [(0, 0), (1, 0), (2, 0), (3, 0), (0, 1)] {
                let expected = a.get(x, y)
                let actual = back.get(x, y)
                #expect(
                    same(actual, expected, within: 0.02),
                    "(\(x), \(y)) 元 \(expected) 読み戻し \(actual)")
            }
            #expect(abs(back.get(1, 0).alpha - 0.5) <= 1.0 / 255 + 0.001, "透けが失われた")
            #expect(back.get(3, 0).alpha == 0)
        }
    }

    @Test("スケッチの save(_:) と同じ出力の変換: 描いた絵と同じ PNG の画素になる")
    func saveMatchesTheCanvasOutput() throws {
        try withTemporaryDirectory { directory in
            let canvas = try makeCanvas()
            // 描き場所へ描いた絵を、Image へ写して save する経路と、描き場所を直接書く経路を比べる
            try canvas.target.fill(with: teal)
            let shown = try canvas.target.encodeForDisplay()
            let image = try canvas.createImage(16, 16)
            image.write(shown)
            let path = directory.appendingPathComponent("same.png").path
            try image.save(path)
            let direct = directory.appendingPathComponent("direct.png")
            try canvas.target.writePNG(to: direct)
            let saved = try ImageFile.decode(path)
            let expected = try ImageFile.decode(direct.path)
            #expect(saved.width == expected.width && saved.height == expected.height)
            for (a, b) in zip(saved.pixels, expected.pixels) {
                #expect(abs(Float(a.x) - Float(b.x)) <= 0.001 && abs(Float(a.y) - Float(b.y)) <= 0.001)
            }
        }
    }

    @Test("書けない行き先は、行き先を名乗る型のついた失敗で投げる")
    func unwritableDestinationThrows() throws {
        try withTemporaryDirectory { directory in
            let canvas = try makeCanvas()
            let a = try canvas.createImage(2, 2)
            a.fill(red)

            // 親がふつうのファイル (ディレクトリを作れない)
            let file = directory.appendingPathComponent("plain.txt")
            try Data("x".utf8).write(to: file)
            let beneathAFile = file.appendingPathComponent("x.png").path
            do {
                try a.save(beneathAFile)
                Issue.record("親がファイルの行き先へ書けてしまった")
            } catch let failure as ImageFailure {
                guard case .unwritable(let path, let reason) = failure else {
                    Issue.record("別の失敗: \(failure)")
                    return
                }
                #expect(path == beneathAFile)
                #expect(reason.isEmpty == false)
                #expect("\(failure)".contains(beneathAFile))
            } catch {
                Issue.record("ImageFailure ではない失敗: \(error)")
            }

            // 行き先がディレクトリ
            let folder = directory.appendingPathComponent("folder.png")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            #expect(throws: ImageFailure.self) { try a.save(folder.path) }
        }
    }
}
