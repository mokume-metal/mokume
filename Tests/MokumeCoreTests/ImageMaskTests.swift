// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics
import MokumeTestSupport
import Testing

@testable import MokumeCore

// `Image.mask(_:)` ([#3713])。マスクの明るさを `brightness(_:)` の物差しで読み、不透明度に掛ける。
//
// [#3713]: https://github.com/mokume-metal/mokume/issues/3713

/// マスクの 1 画素の読み方 (GPU を要さない)。
@Suite("マスクの明るさの読み方")
struct MaskLevelTests {
    @Test("brightness の物差しで読む: 白は 1、黒は 0、表示で中間の灰色は 0.5")
    func levelsFollowBrightness() {
        #expect(abs(Image.maskLevel(.display(red: 1, green: 1, blue: 1)) - 1) < 1e-4)
        #expect(Image.maskLevel(.display(red: 0, green: 0, blue: 0)) == 0)
        let gray = LinearRGBA.display(red: 0.5, green: 0.5, blue: 0.5)
        #expect(abs(Image.maskLevel(gray) - 0.5) < 0.001)
        // 表示で中間の灰色は、線形の成分では約 0.214 (線形の成分で読んではいない)
        #expect(abs(gray.red - 0.214) < 0.01)
        // 線形の 0.5 の灰色は、表示では中間より明るい
        #expect(Image.maskLevel(.linear(red: 0.5, green: 0.5, blue: 0.5)) > 0.7)
    }

    @Test("灰色でない色は最も大きい成分で読み、範囲の外は端へ寄せる")
    func levelsOfOtherColours() {
        #expect(abs(Image.maskLevel(.display(red: 1, green: 0, blue: 0)) - 1) < 1e-4, "青が 0 でも赤一色は 1")
        #expect(Image.maskLevel(.linear(red: 4, green: 4, blue: 4)) == 1, "表示を超えて明るい画素は 1")
        #expect(Image.maskLevel(.transparent) == 0)
        #expect(Image.maskLevel(.linear(red: .nan, green: 0, blue: 0)) == 0)
    }
}

/// マスクを掛ける (GPU を要する)。
@Suite(
    "絵のマスク",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ImageMaskTests {
    private let white = LinearRGBA.display(red: 1, green: 1, blue: 1)
    private let black = LinearRGBA.display(red: 0, green: 0, blue: 0)
    /// `brightness` が 50 の灰色 (線形の成分では約 0.214)。
    private let gray = LinearRGBA.display(red: 0.5, green: 0.5, blue: 0.5)

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
    }

    private func same(_ a: LinearRGBA, _ b: LinearRGBA, within tolerance: Float = 0) -> Bool {
        abs(a.red - b.red) <= tolerance && abs(a.green - b.green) <= tolerance
            && abs(a.blue - b.blue) <= tolerance && abs(a.alpha - b.alpha) <= tolerance
    }

    private func saying<T>(_ body: () throws -> T) rethrows -> (value: T, lines: [String]) {
        try Diagnostics.$digest.withValue(WarningDigest()) {
            let value = try body()
            return (value, Diagnostics.takeUnreported())
        }
    }

    @Test("黒いところは完全に透明に、白いところは元のままになり、マスクは変わらない")
    func blackClearsAndWhiteKeeps() throws {
        let canvas = try makeCanvas()
        let a = try canvas.createImage(2, 1)
        a.fill(white)
        let before = a.get(1, 0)
        let m = try canvas.createImage(2, 1)
        m.set(0, 0, black)
        m.set(1, 0, white)
        let maskBefore = (m.get(0, 0), m.get(1, 0))
        a.mask(m)
        #expect(same(a.get(0, 0), .transparent))
        #expect(same(a.get(1, 0), before))
        #expect(same(m.get(0, 0), maskBefore.0) && same(m.get(1, 0), maskBefore.1), "マスクが変わった")
        #expect(a.needsUpload, "書き換えが描くときに送られない")
    }

    @Test("半透明 (0.5) の画素に白を掛けても 0.5、brightness が 50 の灰色を掛けると 0.25 (色は保つ)")
    func opacityIsMultiplied() throws {
        let canvas = try makeCanvas()
        let half = LinearRGBA(premultipliedRed: 0.3, green: 0.1, blue: 0.05, alpha: 0.5)
        let a = try canvas.createImage(2, 1)
        a.set(0, 0, half)
        a.set(1, 0, half)
        let m = try canvas.createImage(2, 1)
        m.set(0, 0, white)
        m.set(1, 0, gray)
        a.mask(m)
        #expect(abs(a.get(0, 0).alpha - 0.5) < 0.001, "白で不透明度が変わった (置き換えている)")
        let quarter = a.get(1, 0)
        #expect(abs(quarter.alpha - 0.25) < 0.002, "\(quarter)")
        // 乗算を戻した色は元と同じ (0.3 / 0.5 = 0.6)
        #expect(abs(quarter.red / quarter.alpha - 0.6) < 0.01 && abs(quarter.green / quarter.alpha - 0.2) < 0.01)
    }

    @Test("大きさの違うマスクでは何も変えず、理由を 1 度だけ警告する")
    func aMaskOfAnotherSizeChangesNothing() throws {
        let canvas = try makeCanvas()
        let a = try canvas.createImage(2, 1)
        a.fill(white)
        let m = try canvas.createImage(3, 1)
        m.fill(black)
        let (_, lines) = saying {
            a.mask(m)
            a.mask(m)
        }
        #expect(same(a.get(0, 0), white, within: 0.001) && same(a.get(1, 0), white, within: 0.001))
        let said = lines.filter { $0.contains("mask()") }
        #expect(said.count == 1, "\(lines)")
        #expect(said.first?.contains("3x1") == true && said.first?.contains("2x1") == true, "\(said)")
    }

    @Test("自分自身を渡すと、書き換える前の明るさで読む")
    func maskingWithItself() throws {
        let canvas = try makeCanvas()
        let a = try canvas.createImage(1, 1)
        a.fill(gray)
        a.mask(a)
        #expect(abs(a.get(0, 0).alpha - 0.5) < 0.002)
    }

    @Test("カメラの画像と同じく、次の 1 枚が書き込まれるまで効き、書き込みで上書きされる")
    func aMaskLastsUntilTheNextWrite() throws {
        let canvas = try makeCanvas()
        let frame = DisplayImage(width: 2, height: 2, bytes: [UInt8](repeating: 255, count: 2 * 2 * 4))
        let picture = try canvas.createImage(2, 2)
        picture.write(frame)
        let m = try canvas.createImage(2, 2)
        m.fill(black)
        picture.mask(m)
        #expect(picture.get(1, 1).alpha == 0)
        // カメラは次の 1 枚を同じ絵へ書き込む
        picture.write(frame)
        #expect(abs(picture.get(1, 1).alpha - 1) < 0.001)
    }

    @Test("大きな入力 (復号を遅らせるもの) にも、書き換えを含めて掛かる")
    func maskingALargeInput() throws {
        let canvas = try makeCanvas()
        let side = 1024
        #expect(side * side >= Image.metalInputMinimumPixels)
        let picture = try canvas.createImage(side, side)
        picture.write(DisplayImage(width: side, height: side, bytes: [UInt8](repeating: 255, count: side * side * 4)))
        picture.set(3, 4, gray)
        let m = try canvas.createImage(side, side)
        m.fill(white)
        m.set(10, 10, black)
        picture.mask(m)
        #expect(picture.get(10, 10).alpha == 0)
        #expect(abs(picture.get(0, 0).alpha - 1) < 0.001)
        #expect(same(picture.get(3, 4), gray, within: 0.001), "書き換えが落ちた")
    }
}
