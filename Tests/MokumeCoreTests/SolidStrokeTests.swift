// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Testing

@testable import MokumeCore

/// 組み込みの立体と読み込んだモデルに引く線の検査 (#850)。GPU を要する。
///
/// 線は塗りと同じく**スタイル**で、次元によって作用が変わらない ([ADR-0020] 決定 3・
/// [ADR-0021] 決定 5)。見るのは「置いたら出る」「置かなければ出ない」「太さが画面の
/// 画素で測られる」の 3 つで、線の形そのもの (どの辺を引くか) は `SolidMeshTests` が
/// 数え上げで見る。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
/// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
@Suite(
    "立体の線",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SolidStrokeTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    private let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)

    private func makeCanvas(width: Int = 200, height: Int = 200) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    private func pixels(of canvas: Canvas) throws -> DisplayImage {
        try canvas.target.encodeForDisplay()
    }

    /// 背景 (黒) でない画素の数。
    private func litCount(_ image: DisplayImage) -> Int {
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let sample = image[x, y]
                if sample.red > 0 || sample.green > 0 || sample.blue > 0 { count += 1 }
            }
        }
        return count
    }

    /// 形を 1 つ、真ん中に回して置いた絵。
    private func draw(
        _ place: (Canvas) -> Void, fill: Bool, stroke: Bool, weight: Float = 6
    ) throws -> DisplayImage {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            if fill { canvas.fill(red) } else { canvas.noFill() }
            if stroke { canvas.stroke(blue) } else { canvas.noStroke() }
            canvas.strokeWeight(weight)
            canvas.push()
            canvas.translate(100, 100, 0)
            canvas.rotateX(0.5)
            canvas.rotateY(0.7)
            place(canvas)
            canvas.pop()
        }
        return try pixels(of: canvas)
    }

    /// `place()` を通る 6 つの形。**形ごとに分岐を持たない**ことを、全部に同じ検査を
    /// 掛けて見る (ADR-0021 決定 5)。
    nonisolated static let shapes: [(name: String, place: @MainActor (Canvas) -> Void)] = [
        ("box", { $0.box(80) }),
        ("sphere", { $0.sphere(50) }),
        ("plane", { $0.plane(90, 70) }),
        ("cylinder", { $0.cylinder(40, 90) }),
        ("cone", { $0.cone(45, 90) }),
        ("torus", { $0.torus(50, 16) }),
    ]

    // MARK: - 置いたら出る

    @Test("塗りに線を重ねた箱は、線を止めた箱と違う絵になる")
    func strokeChangesTheBox() throws {
        // Issue の症状は「置いても置かなくても同じハッシュ」だった。その逆を見る
        let stroked = try draw({ $0.box(120) }, fill: true, stroke: true)
        let plain = try draw({ $0.box(120) }, fill: true, stroke: false)
        #expect(SHA256.hash(data: stroked.bytes) != SHA256.hash(data: plain.bytes))
        // 違いは線の色で現れる (塗りは赤・線は青)
        var blueOnly = 0
        for y in 0..<stroked.height {
            for x in 0..<stroked.width where stroked[x, y].blue > 200 && stroked[x, y].red < 40 {
                blueOnly += 1
            }
        }
        #expect(blueOnly > 0, "線の色の画素が無い")
    }

    @Test("塗りを止めて線だけにした球は、線だけの絵になる")
    func strokeOnlySphere() throws {
        let image = try draw({ $0.sphere(50) }, fill: false, stroke: true)
        #expect(litCount(image) > 0, "線だけの球が何も出していない")
        // 塗りの色は 1 画素も出ない
        for y in 0..<image.height {
            for x in 0..<image.width { #expect(image[x, y].red == 0) }
        }
    }

    @Test("線は 6 つの形すべてに効く", arguments: 0..<6)
    func strokeWorksForEveryShape(_ index: Int) throws {
        let shape = Self.shapes[index]
        let strokeOnly = try draw(shape.place, fill: false, stroke: true)
        #expect(litCount(strokeOnly) > 0, "\(shape.name) の線が出ない")

        let stroked = try draw(shape.place, fill: true, stroke: true)
        let plain = try draw(shape.place, fill: true, stroke: false)
        #expect(stroked.bytes != plain.bytes, "\(shape.name) の線が塗りに重ならない")
    }

    @Test("読み込んだモデルにも線が効く")
    func strokeWorksForModels() throws {
        let canvas = try makeCanvas()
        let model = try canvas.loadModel(ModelFixture.pyramid)
        func picture(fill: Bool, stroke: Bool) throws -> DisplayImage {
            try canvas.draw {
                canvas.background(black)
                if fill { canvas.fill(red) } else { canvas.noFill() }
                if stroke { canvas.stroke(blue) } else { canvas.noStroke() }
                canvas.strokeWeight(6)
                canvas.push()
                canvas.translate(100, 100, 0)
                canvas.rotateX(0.4)
                canvas.model(model)
                canvas.pop()
            }
            return try pixels(of: canvas)
        }
        #expect(litCount(try picture(fill: false, stroke: true)) > 0, "線だけのモデルが何も出していない")
        #expect(try picture(fill: true, stroke: true).bytes != picture(fill: true, stroke: false).bytes)
    }

    @Test("保持した形の中で置いた立体にも線が効き、記録の外のスタイルは変わらない")
    func strokeWorksInsideRetainedShapes() throws {
        func picture(stroke: Bool) throws -> (image: DisplayImage, strokeAfter: Bool) {
            let canvas = try makeCanvas()
            var strokeAfter = false
            try canvas.draw {
                canvas.background(black)
                canvas.noStroke()
                let crate = canvas.createShape {
                    canvas.fill(red)
                    if stroke { canvas.stroke(blue) }
                    canvas.strokeWeight(4)
                    canvas.box(80)
                }
                strokeAfter = canvas.hasStroke
                canvas.push()
                canvas.translate(100, 100, 0)
                canvas.shape(crate)
                canvas.pop()
            }
            return (try pixels(of: canvas), strokeAfter)
        }
        let stroked = try picture(stroke: true)
        let plain = try picture(stroke: false)
        #expect(stroked.image.bytes != plain.image.bytes, "保持した箱に線が載っていない")
        // 記録の中で書いた stroke() は、記録の外の noStroke() を上書きしない
        #expect(stroked.strokeAfter == false)
    }

    // MARK: - 置かなければ出ない

    @Test("塗りも線も止めた形は何も出さない")
    func neitherFillNorStrokeDrawsNothing() throws {
        for shape in Self.shapes {
            #expect(litCount(try draw(shape.place, fill: false, stroke: false)) == 0, "\(shape.name)")
        }
    }

    @Test("太さ 0 の線は何も出さない")
    func zeroWeightDrawsNothing() throws {
        for shape in Self.shapes {
            let image = try draw(shape.place, fill: false, stroke: true, weight: 0)
            #expect(litCount(image) == 0, "\(shape.name)")
        }
    }

    // MARK: - 太さ

    @Test("線の太さは画面の画素で測られ、奥に置いても細らない")
    func weightIsMeasuredInScreenPixels() throws {
        /// 正面を向いた面の上の縁を、真ん中の列で縦に横切ったときの線の厚み。
        func thickness(depth: Float) throws -> Int {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                canvas.noFill()
                canvas.stroke(blue)
                canvas.strokeWeight(8)
                canvas.push()
                canvas.translate(100, 100, depth)
                canvas.plane(120, 120)
                canvas.pop()
            }
            let image = try pixels(of: canvas)
            // 上半分だけを数える (下の縁は数えない)
            var count = 0
            for y in 0..<(image.height / 2) where image[100, y].blue > 128 { count += 1 }
            return count
        }
        let near = try thickness(depth: 0)
        let far = try thickness(depth: -400)
        #expect(near == 8, "手前の線が 8 画素ではない (\(near))")
        #expect(far == near, "奥の線の厚みが変わった (手前 \(near) / 奥 \(far))")
    }

    // MARK: - 奥行き

    @Test("塗った面の縁の線は、面に食われて途切れない")
    func strokeIsNotEatenByItsOwnFill() throws {
        // 帯は視線に正対するので、傾いた面の縁では帯の内側の半分が面と同じ奥行きの
        // あたりに載る。取り合いに負けると線が細り、細い線なら点線になる (#850 で
        // 箱の稜が点線になって現れた)。**面の縁は裏に隠れる稜線を持たない**ので、
        // 塗っても塗らなくても、線の画素は同じだけ出るはずである
        func strokePixels(filled: Bool) throws -> Int {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                if filled { canvas.fill(red) } else { canvas.noFill() }
                canvas.stroke(blue)
                canvas.strokeWeight(2)
                // 中心から外し、傾けて置く。視線が面の縁に斜めに当たる
                canvas.push()
                canvas.translate(60, 70, 0)
                canvas.rotateX(0.6)
                canvas.rotateY(-0.5)
                canvas.plane(80, 60)
                canvas.pop()
            }
            let image = try pixels(of: canvas)
            var count = 0
            for y in 0..<image.height {
                for x in 0..<image.width where image[x, y].blue > 128 { count += 1 }
            }
            return count
        }
        let bare = try strokePixels(filled: false)
        let overFill = try strokePixels(filled: true)
        #expect(bare > 0)
        #expect(overFill == bare, "塗りに重ねた線が食われている (塗らない \(bare) / 塗る \(overFill))")
    }

    @Test("塗った形の裏側の稜線は、手前の面に隠れる")
    func hiddenEdgesStayHidden() throws {
        // 正面を向いた箱。奥の面の縁は手前の面の真後ろ (画面では同じ場所より内側) に
        // 来るので、塗った箱では見えず、塗らない箱では見える
        func centerStroke(fill: Bool) throws -> Int {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(black)
                if fill { canvas.fill(red) } else { canvas.noFill() }
                canvas.stroke(blue)
                canvas.strokeWeight(4)
                canvas.push()
                canvas.translate(100, 100, 0)
                canvas.box(100)
                canvas.pop()
            }
            let image = try pixels(of: canvas)
            // 透視で奥の面は小さく映るので、その縁は手前の縁より内側にある。
            // 手前の縁から十分に内側の帯だけを数える
            var count = 0
            for y in 60..<140 {
                for x in 60..<140 where image[x, y].blue > 128 { count += 1 }
            }
            return count
        }
        #expect(try centerStroke(fill: false) > 0, "塗らない箱で奥の稜線が見えていない")
        #expect(try centerStroke(fill: true) == 0, "塗った箱の奥の稜線が透けている")
    }
}
