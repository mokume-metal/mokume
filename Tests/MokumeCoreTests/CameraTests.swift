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
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)
    // 目印の色は作業空間の原色 (`.linear`) で書く。この検査の主題は色の入口ではなく、
    // 純色のまま 255 / 0 に出るので期待値をそのまま書ける (入口は ColorSurfaceTests が見る — #911)
    private let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    private let green = LinearRGBA.linear(red: 0, green: 1, blue: 0)

    private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
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
            solid.noStroke()
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

    /// 裏返した平行投影の向き。**裏返さない向きの範囲**は ``ortho()`` と同じ (面 1 枚ぶん)。
    enum OrthoSwap: Sendable, CaseIterable {
        case topAndBottom
        case leftAndRight
    }

    @Test(
        "上端と下端 (左端と右端) を入れ替えても、光の当たった閉じた箱は裏返った絵になるだけ",
        arguments: OrthoSwap.allCases)
    func swappingTheRangeOnlyFlipsAClosedSolid(_ swap: OrthoSwap) throws {
        // ortho の説明の「絵が上下反転するだけ」は、閉じた形でも成り立たなければならない。
        // 投影が画面の縦横を裏返すと巻き方も裏返るので、表の巻き方を裏返さずに裏面を
        // 捨てると手前の面が捨てられ、光に背を向けた奥の面だけが写る (#1446)
        func picture(swapped: Bool) throws -> DisplayImage {
            let canvas = try makeCanvas(width: 96, height: 96)
            try canvas.draw {
                canvas.background(20)
                switch (swapped, swap) {
                case (false, _): canvas.ortho()
                case (true, .topAndBottom): canvas.ortho(-48, 48, -48, 48, 5, 600)
                case (true, .leftAndRight): canvas.ortho(48, -48, 48, -48, 5, 600)
                }
                canvas.noStroke()
                canvas.directionalLight(255, 255, 255, 0, 0, -1)
                canvas.fill(230, 60, 40)
                canvas.translate(52, 40, 0)
                canvas.rotateY(0.6)
                canvas.rotateX(0.5)
                canvas.box(40)
            }
            return try pixels(of: canvas)
        }

        let upright = try picture(swapped: false)
        let swapped = try picture(swapped: true)
        let difference = PictureDifference.between(
            swapped, upright, flip: swap == .topAndBottom ? .vertical : .horizontal)
        #expect(difference.shapePixels > 1000, "箱が写っていない (\(difference))")
        #expect(difference.fraction <= 0.02, "裏返した投影の箱が、裏返した絵と食い違う (\(difference))")
    }

    @Test("投影が画面の縦横を裏返すかは、縦横の倍率の符号で決まり、奥行きの向きは見ない")
    func whetherAProjectionFlipsTheScreen() {
        func flips(_ projection: Camera.Projection) -> Bool {
            Camera(
                eye: SIMD3(0, 0, 100), center: .zero, up: SIMD3(0, 1, 0), projection: projection
            ).flipsScreen
        }
        #expect(!flips(Camera.defaultPerspective(width: 64, height: 64)))
        #expect(!flips(Camera.defaultOrthographic(width: 64, height: 64)))
        #expect(flips(.orthographic(left: -32, right: 32, bottom: -32, top: 32, near: 5, far: 600)))
        #expect(flips(.orthographic(left: 32, right: -32, bottom: 32, top: -32, near: 5, far: 600)))
        #expect(!flips(.orthographic(left: 32, right: -32, bottom: -32, top: 32, near: 5, far: 600)))
        // 手前と奥を入れ替えると 4x4 の行列式は負になるが、画面の巻き方は変わらない
        #expect(!flips(.orthographic(left: -32, right: 32, bottom: 32, top: -32, near: 600, far: 5)))
        #expect(flips(.perspective(fieldOfView: 1, aspect: -1, near: 5, far: 600)))
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
            canvas.noStroke()
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
            canvas.perspective(2 * atan(Float(64) / 300), 1, 30, 3000)
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
            canvas.camera(Float.nan, 32, 100, 32, 32, 0, 0, 1, 0)
            seen.append(canvas.currentCamera)
            // 潰れた投影
            canvas.ortho(0, 0, 1, -1, 1, 100)
            canvas.perspective(0, 1, 1, 100)
            canvas.perspective(1, 1, 100, 1)
            seen.append(canvas.currentCamera)
        }

        #expect(seen.allSatisfy { $0 == canvas.defaultCamera })
    }

    /// `perspective` / `ortho` が断る投影 (#1495)。`setCamera` もこれを断らなければならない。
    enum RefusedProjection: Sendable, CaseIterable {
        /// 横 ÷ 縦の比が負 (画面の左右を裏返す)。
        case negativeAspect
        /// 画角が π。
        case fieldOfViewOfPi
        /// 手前と奥の面が同じ距離。
        case nearAtFar
        /// 数でない値。
        case notANumber
        /// 平行投影の左端と右端が同じ。
        case orthoLeftEqualsRight
        /// 平行投影の手前と奥の面が同じ距離。
        case orthoNearEqualsFar

        var projection: Camera.Projection {
            switch self {
            case .negativeAspect: .perspective(fieldOfView: 1, aspect: -1, near: 5, far: 600)
            case .fieldOfViewOfPi: .perspective(fieldOfView: Float.pi, aspect: 1, near: 5, far: 600)
            case .nearAtFar: .perspective(fieldOfView: 1, aspect: 1, near: 100, far: 100)
            case .notANumber: .perspective(fieldOfView: Float.nan, aspect: 1, near: 5, far: 600)
            case .orthoLeftEqualsRight:
                .orthographic(left: 32, right: 32, bottom: 32, top: -32, near: 5, far: 600)
            case .orthoNearEqualsFar:
                .orthographic(left: -32, right: 32, bottom: 32, top: -32, near: 100, far: 100)
            }
        }
    }

    @Test(
        "perspective / ortho が断る投影は setCamera でも断り、視点も投影も呼ぶ前のまま続ける",
        arguments: RefusedProjection.allCases)
    func setCameraRefusesWhatPerspectiveAndOrthoRefuse(_ refused: RefusedProjection) throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.camera(70, 10, 90, 32, 32, 0, 0, 1, 0)
            let before = canvas.currentCamera
            // 視点も変えた値を渡す。視点だけが当たって投影が残る半端な当たり方も見分けるため
            var camera = before
            camera.eye = SIMD3(10, 50, 120)
            camera.projection = refused.projection
            canvas.setCamera(camera)
            #expect(canvas.currentCamera == before)
        }
        #expect(
            canvas.warnings.message(for: .badCamera)
                == "setCamera(): the projection is one that perspective() and ortho() refuse (the "
                + "range being captured is collapsed, or a value is out of range or not a number), so "
                + "the camera was left as it was")
    }

    @Test(
        "setCamera が断る投影は、perspective / ortho で渡しても断られる",
        arguments: RefusedProjection.allCases)
    func perspectiveAndOrthoRefuseTheSameProjections(_ refused: RefusedProjection) throws {
        // 上の検査の前提 (「perspective / ortho が断る」) が、並べた値について本当に成り立つか
        let canvas = try makeCanvas()
        try canvas.draw {
            let before = canvas.currentCamera
            switch refused.projection {
            case let .perspective(fieldOfView, aspect, near, far):
                canvas.perspective(fieldOfView, aspect, near, far)
            case let .orthographic(left, right, bottom, top, near, far):
                canvas.ortho(left, right, bottom, top, near, far)
            }
            #expect(canvas.currentCamera == before)
        }
        #expect(canvas.warnings.hasWarned(.badCamera))
    }

    /// `perspective` / `ortho` が受ける投影。`setCamera` でも受けて、注意を出さない。
    enum TakenProjection: Sendable, CaseIterable {
        case defaultPerspective
        case defaultOrthographic
        /// `perspective(1.6, width / height, 26, 2600)` に当たる透視。
        case widePerspective
        /// 上下を入れ替えた `ortho(-32, 32, -32, 32, 5, 600)` に当たる平行。
        case flippedOrthographic

        func projection(width: Float, height: Float) -> Camera.Projection {
            switch self {
            case .defaultPerspective: Camera.defaultPerspective(width: width, height: height)
            case .defaultOrthographic: Camera.defaultOrthographic(width: width, height: height)
            case .widePerspective:
                .perspective(fieldOfView: 1.6, aspect: width / height, near: 26, far: 2600)
            case .flippedOrthographic:
                .orthographic(left: -32, right: 32, bottom: -32, top: 32, near: 5, far: 600)
            }
        }
    }

    @Test(
        "perspective / ortho が受ける投影は setCamera でも受け、注意も出ない",
        arguments: TakenProjection.allCases)
    func setCameraTakesWhatPerspectiveAndOrthoTake(_ taken: TakenProjection) throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            // どの値とも違う投影から始める。断っても投影が変わらずに済む既定から始めると、
            // 受けたか断ったかが currentCamera に出ない
            canvas.perspective(1, 2, 5, 600)
            var camera = canvas.currentCamera
            camera.eye = SIMD3(10, 50, 120)
            camera.projection = taken.projection(width: 64, height: 64)
            canvas.setCamera(camera)
            #expect(canvas.currentCamera == camera)
        }
        #expect(canvas.warnings.message(for: .badCamera) == nil)
    }
}
