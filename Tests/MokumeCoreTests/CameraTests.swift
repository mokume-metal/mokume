// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// どこから見るかを決めたときに何が起きるかの検査。GPU を要する。
///
/// 見るのは**書き出した絵の画素**である。視点も投影も、破れても例外は出ず絵が少し
/// 変わるだけなので ([ADR-0021] の「破れたとき」)、絵に出る形で確かめる。
///
/// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
@Suite(
    "視点と投影",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct CameraTests {
    private let black = LinearRGBA.opaque(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.opaque(red: 1, green: 1, blue: 1)
    private let red = LinearRGBA.display(red: 1, green: 0, blue: 0)
    private let green = LinearRGBA.display(red: 0, green: 1, blue: 0)

    private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }

    private func pixels(of canvas: Canvas) throws -> DisplayImage {
        try canvas.target.encodeForDisplay()
    }

    /// 塗られた画素の重心と数。**位置が絵に出ているか**を数で言うための物差し。
    private func centroid(of image: DisplayImage) -> (x: Float, y: Float, count: Int)? {
        var sumX: Float = 0
        var sumY: Float = 0
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width where image[x, y].red > 40 {
                sumX += Float(x)
                sumY += Float(y)
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return (sumX / Float(count), sumY / Float(count), count)
    }

    // MARK: - 既定どうしが噛み合う

    @Test("平行投影を単独で呼んでも、奥行き 0 の面は矩形とぴったり重なる")
    func defaultOrthographicKeepsFlatAlignment() throws {
        // ADR-0021 決定 1 の要件が、透視投影だけでなく平行投影の既定でも成り立つ。
        // 既定を「よくある固定値」で決めると、ここが最初に崩れる
        let solid = try makeCanvas()
        try solid.draw {
            solid.background(black)
            solid.ortho()
            solid.fill(red)
            solid.push()
            solid.translate(32, 32, 0)
            solid.plane(30, 20)
            solid.pop()
        }

        let flat = try makeCanvas()
        try flat.draw {
            flat.background(black)
            flat.fill(red)
            flat.noStroke()
            flat.rect(32 - 15, 32 - 10, 30, 20)
        }

        #expect(try pixels(of: solid).bytes == pixels(of: flat).bytes)
    }

    @Test("平行投影を単独で呼んでも、奥に置いたものが切れない")
    func defaultOrthographicKeepsDistantSolidsVisible() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.ortho()
            canvas.fill(red)
            canvas.push()
            // 面の高さの 5 倍ほど奥へ置く
            canvas.translate(32, 32, -320)
            canvas.plane(30, 20)
            canvas.pop()
        }

        #expect(try pixels(of: canvas)[32, 32].red > 200)
    }

    @Test("平行投影では、奥へ動かしても大きさが変わらない")
    func orthographicKeepsSizeAcrossDepth() throws {
        func area(depth: Float, ortho: Bool) throws -> Int {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                if ortho { canvas.ortho() }
                canvas.fill(red)
                canvas.push()
                canvas.translate(32, 32, depth)
                canvas.plane(24, 24)
                canvas.pop()
            }
            return centroid(of: try pixels(of: canvas))?.count ?? 0
        }

        #expect(try area(depth: 0, ortho: true) == area(depth: -200, ortho: true))
        // 透視投影のほうは、同じ操作で小さくなる (比較の対照)
        #expect(try area(depth: 0, ortho: false) > area(depth: -200, ortho: false))
    }

    // MARK: - 引数の向きが絵に出る

    @Test("平行投影の範囲を下へずらすと、被写体は画面の上へ動く")
    func orthographicWindowDirectionShowsInThePicture() throws {
        func centroidY(shift: Float) throws -> Float {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                // 既定と同じ範囲を、縦に shift だけずらす
                canvas.ortho(-32, 32, 32 + shift, -32 + shift, 5, 600)
                canvas.fill(red)
                canvas.push()
                canvas.translate(32, 32, 0)
                canvas.plane(20, 20)
                canvas.pop()
            }
            return try #require(centroid(of: pixels(of: canvas))?.y)
        }

        // 窓を画面の下側 (+y) へずらす = 被写体は窓の中で上に来る
        #expect(try centroidY(shift: 12) < centroidY(shift: 0) - 8)
        #expect(try centroidY(shift: -12) > centroidY(shift: 0) + 8)
    }

    @Test("平行投影の範囲を右へずらすと、被写体は画面の左へ動く")
    func orthographicWindowHorizontalDirectionShowsInThePicture() throws {
        func centroidX(shift: Float) throws -> Float {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.ortho(-32 + shift, 32 + shift, 32, -32, 5, 600)
                canvas.fill(red)
                canvas.push()
                canvas.translate(32, 32, 0)
                canvas.plane(20, 20)
                canvas.pop()
            }
            return try #require(centroid(of: pixels(of: canvas))?.x)
        }

        #expect(try centroidX(shift: 12) < centroidX(shift: 0) - 8)
    }

    @Test("上端と下端を入れ替えると、絵は上下が逆になる")
    func swappingTopAndBottomFlipsThePicture() throws {
        // ADR-0021 決定 1 の「画面の側を正とする」が守られているかは、**入れ替えた絵と
        // 見分けが付くか**でしか言えない。取り違えても警告は出ず、絵が反転するだけ
        func centroidY(swapped: Bool) throws -> Float {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                if swapped {
                    canvas.ortho(-32, 32, -32, 32, 5, 600)
                } else {
                    canvas.ortho(-32, 32, 32, -32, 5, 600)
                }
                canvas.fill(red)
                canvas.push()
                // 画面の上寄りに置く
                canvas.translate(32, 18, 0)
                canvas.plane(16, 16)
                canvas.pop()
            }
            return try #require(centroid(of: pixels(of: canvas))?.y)
        }

        let upright = try centroidY(swapped: false)
        let flipped = try centroidY(swapped: true)
        // 正しい向きでは上寄り、入れ替えると下寄りへ回る (中央を挟んで対称)
        #expect(upright < 32)
        #expect(flipped > 32)
        #expect(abs((upright - 32) + (flipped - 32)) < 1.5)
    }

    // MARK: - フレームの中で変える

    @Test("視点を変えると、変えたあとに置いたものだけが新しい視点で描かれる")
    func changingTheCameraOnlyAffectsWhatComesAfter() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)

            // 既定の視点で、左上に赤を置く → 画面の (20, 20)
            canvas.fill(red)
            canvas.push()
            canvas.translate(20, 20, 0)
            canvas.plane(14, 14)
            canvas.pop()

            // 視点を右へ 24 動かす
            canvas.camera(
                32 + 24, 32, Camera.fittingDistance(height: 64),
                32 + 24, 32, 0,
                0, 1, 0)
            // 世界では右下だが、視点が追いかけたぶん画面では (20, 44) に来る
            canvas.fill(green)
            canvas.push()
            canvas.translate(20 + 24, 44, 0)
            canvas.plane(14, 14)
            canvas.pop()
        }

        let image = try pixels(of: canvas)
        func span(row: Int, isMatch: (UInt8, UInt8) -> Bool) -> (first: Int, last: Int)? {
            let hits = (0..<image.width).filter { isMatch(image[$0, row].red, image[$0, row].green) }
            guard let first = hits.first, let last = hits.last else { return nil }
            return (first, last)
        }
        let redSpan = try #require(span(row: 20) { $0 > 150 && $1 < 100 })
        let greenSpan = try #require(span(row: 44) { $1 > 150 && $0 < 100 })

        // どちらも画面の x = 20 付近。**変える前に置いた赤は動いていない**
        #expect(abs(Float(redSpan.first + redSpan.last) / 2 - 20) < 1.5)
        #expect(abs(Float(greenSpan.first + greenSpan.last) / 2 - 20) < 1.5)
        // 視点が効いていなければ緑は x = 44 付近に出る。そこには何も無い
        #expect(image[44, 44].green < 100)
    }

    @Test("投影を変えると、変えたあとに置いたものだけが新しい投影で描かれる")
    func changingTheProjectionOnlyAffectsWhatComesAfter() throws {
        let canvas = try makeCanvas(width: 128, height: 64)
        try canvas.draw {
            canvas.background(black)
            // 透視投影のまま、奥に赤を置く (小さく写る)
            canvas.fill(red)
            canvas.push()
            canvas.translate(32, 32, -200)
            canvas.plane(20, 20)
            canvas.pop()

            // 平行投影へ切り替えて、同じ奥行きに緑を置く (縮まない)
            canvas.ortho()
            canvas.fill(green)
            canvas.push()
            canvas.translate(96, 32, -200)
            canvas.plane(20, 20)
            canvas.pop()
        }

        let image = try pixels(of: canvas)
        var redCount = 0
        var greenCount = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let pixel = image[x, y]
                if pixel.red > 150 && pixel.green < 100 { redCount += 1 }
                if pixel.green > 150 && pixel.red < 100 { greenCount += 1 }
            }
        }
        #expect(redCount > 0)
        // 平行投影のほうは縮まないので、はっきり大きい
        #expect(greenCount > redCount * 2)
    }

    // MARK: - 値として持つ

    @Test("視点を値で保存して当て直すと、同じ絵になる")
    func aSavedCameraReproducesThePicture() throws {
        func picture(_ apply: (Canvas) -> Void) throws -> [UInt8] {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.lights()
                apply(canvas)
                canvas.fill(white)
                canvas.push()
                canvas.translate(32, 32, 0)
                canvas.box(24)
                canvas.pop()
            }
            return try pixels(of: canvas).bytes
        }

        var saved: Camera?
        let direct = try picture { canvas in
            canvas.camera(70, 10, 90, 32, 32, 0, 0, 1, 0)
            saved = canvas.currentCamera
        }
        let restored = try picture { canvas in
            canvas.setCamera(saved!)
        }

        #expect(direct == restored)
        // 既定と違う絵になっていること (保存が意味を持つ場面であること) も見る
        #expect(try direct != picture { _ in })
    }

    @Test("視点を書いても、投影は書き換わらない")
    func settingTheEyeKeepsTheProjection() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.ortho()
            canvas.camera(70, 10, 90, 32, 32, 0, 0, 1, 0)
            #expect(canvas.currentCamera.projection == Camera.defaultOrthographic(width: 64, height: 64))
            #expect(canvas.currentCamera.eye == SIMD3<Float>(70, 10, 90))
        }
    }

    // MARK: - 寿命

    @Test("視点はフレームを越えない")
    func theCameraDoesNotSurviveTheFrame() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.camera(70, 10, 90, 32, 32, 0, 0, 1, 0)
        }
        #expect(canvas.currentCamera == canvas.defaultCamera)

        try canvas.draw {
            canvas.background(black)
            canvas.fill(red)
            canvas.push()
            canvas.translate(32, 32, 0)
            canvas.plane(30, 20)
            canvas.pop()
        }

        let flat = try makeCanvas()
        try flat.draw {
            flat.background(black)
            flat.fill(red)
            flat.noStroke()
            flat.rect(32 - 15, 32 - 10, 30, 20)
        }
        #expect(try pixels(of: canvas).bytes == pixels(of: flat).bytes)
    }

    @Test("フレームの外で書いた視点は無視される")
    func aCameraWrittenOutsideAFrameIsIgnored() throws {
        let canvas = try makeCanvas()
        // 初期化のときに書いた視点はどのフレームにも属さない (警告して無視する)
        canvas.camera(70, 10, 90, 32, 32, 0, 0, 1, 0)
        canvas.ortho()
        #expect(canvas.currentCamera == canvas.defaultCamera)
    }

    // MARK: - 線の太さ

    @Test("視点を変えても、線の太さは画面の画素で保たれる")
    func strokeWidthStaysInScreenPixelsAcrossCameras() throws {
        // 太さの式が既定の視点に固定されていると、視点を動かした瞬間に太さが狂う
        func width(of apply: (Canvas) -> Void) throws -> Int {
            let canvas = try makeCanvas(width: 128, height: 128)
            try canvas.draw {
                canvas.background(black)
                apply(canvas)
                canvas.stroke(red)
                canvas.strokeWeight(9)
                canvas.beginShape(.lines)
                canvas.vertex(64, 30, 0)
                canvas.vertex(64, 98, 0)
                canvas.endShape()
            }
            let image = try pixels(of: canvas)
            return (0..<image.width).count { image[$0, 64].red > 100 }
        }

        let byDefault = try width { _ in }
        // 視点を少し引いて、画角を狭めて元の見え方へ戻す
        let moved = try width { canvas in
            canvas.camera(64, 64, 300, 64, 64, 0, 0, 1, 0)
            canvas.perspective(2 * atan(64 / 300), 1, 30, 3000)
        }
        let orthographic = try width { $0.ortho() }

        #expect(byDefault >= 8 && byDefault <= 10)
        #expect(abs(moved - byDefault) <= 1)
        #expect(abs(orthographic - byDefault) <= 1)
    }

    // MARK: - 壊れた入力

    @Test("成り立たない視点を書いても落ちず、絵も変わらない")
    func brokenCamerasAreIgnored() throws {
        let canvas = try makeCanvas()
        var seen: [Camera] = []
        try canvas.draw {
            canvas.background(black)
            // 見る位置と見ている先が同じ
            canvas.camera(32, 32, 0, 32, 32, 0, 0, 1, 0)
            seen.append(canvas.currentCamera)
            // 上方向がゼロ
            canvas.camera(32, 32, 100, 32, 32, 0, 0, 0, 0)
            seen.append(canvas.currentCamera)
            // 上方向が視線と重なる
            canvas.camera(32, 32, 100, 32, 32, 0, 0, 0, 1)
            seen.append(canvas.currentCamera)
            // 数でない値
            canvas.camera(.nan, 32, 100, 32, 32, 0, 0, 1, 0)
            seen.append(canvas.currentCamera)
            // 潰れた投影
            canvas.ortho(0, 0, 1, -1, 1, 100)
            canvas.perspective(0, 1, 1, 100)
            canvas.perspective(1, 1, 100, 1)
            seen.append(canvas.currentCamera)
        }

        #expect(seen.allSatisfy { $0 == canvas.defaultCamera })
    }
}
