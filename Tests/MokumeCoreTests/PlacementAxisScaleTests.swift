// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// `Placement` の軸ごとの倍率 ([#2460] の D・完了条件 1〜3)。
///
/// 値としての組み立て (`transform`・`isUsable`) は GPU を要さない。絵が `push()` / `translate()` /
/// `scale()` を同じ順で書いたものと画素で一致することは、GPU のある実行環境で見る。
///
/// [#2460]: https://github.com/mokume-metal/mokume/issues/2460
@Suite("Placement の軸ごとの倍率 (値)")
struct PlacementAxisScaleValueTests {
    private func sameMatrix(_ a: simd_float4x4, _ b: simd_float4x4) -> Bool {
        simd_equal(a.columns.0, b.columns.0) && simd_equal(a.columns.1, b.columns.1)
            && simd_equal(a.columns.2, b.columns.2) && simd_equal(a.columns.3, b.columns.3)
    }

    @Test("既定の軸ごとの倍率は (1, 1, 1) で、一様の倍率のままの置き場所は行列が変わらない")
    func uniformPlacementsKeepTheirMatrix() {
        #expect(Placement().axisScale == Vector3(1, 1, 1))
        for scale: Float in [1, 2, -1.5, 0.25] {
            let placement = Placement(x: 3, y: 4, z: 5, scale: scale, rotation: Vector3(0.1, 0.2, 0.3))
            var expected = Transform.identity
            expected.translate(x: 3, y: 4, z: 5)
            expected.rotateX(by: 0.1)
            expected.rotateY(by: 0.2)
            expected.rotateZ(by: 0.3)
            if scale != 1 { expected.scale(x: scale, y: scale, z: scale) }
            #expect(sameMatrix(placement.transform.matrix, expected.matrix), "scale \(scale) の行列が変わった")
        }
    }

    @Test("Vector3 で渡した倍率は、軸ごとに大きさ → 回転 → 位置の順で掛かる")
    func axisScaleComposesInTheSameOrder() {
        let placement = Placement(x: 100, y: 200, scale: Vector3(1, 4, 1), rotation: Vector3(0, 0, 0.5))
        var expected = Transform.identity
        expected.translate(x: 100, y: 200, z: 0)
        expected.rotateZ(by: 0.5)
        expected.scale(x: 1, y: 4, z: 1)
        #expect(sameMatrix(placement.transform.matrix, expected.matrix))
        #expect(placement.scale == 1, "Vector3 で渡した倍率が一様の倍率にも入っている")
    }

    @Test("一様の倍率と軸ごとの倍率は掛け合わさる")
    func uniformAndAxisScaleMultiply() {
        var placement = Placement(scale: 2)
        placement.axisScale = Vector3(1, 4, 0.5)
        var expected = Transform.identity
        expected.scale(x: 2, y: 8, z: 1)
        #expect(sameMatrix(placement.transform.matrix, expected.matrix))
    }

    @Test("軸ごとの倍率のどれかが数でない・無限の置き場所は、置けない")
    func nonFiniteAxisScaleIsNotUsable() {
        #expect(Placement(scale: Vector3(1, 4, 1)).isUsable)
        for (name, scale) in [
            ("x が NaN", Vector3(Float.nan, 1, 1)), ("y が NaN", Vector3(1, Float.nan, 1)),
            ("z が NaN", Vector3(1, 1, Float.nan)), ("x が無限", Vector3(Float.infinity, 1, 1)),
            ("y が負の無限", Vector3(1, -Float.infinity, 1)), ("z が無限", Vector3(1, 1, Float.infinity)),
        ] {
            let placement = Placement(scale: scale)
            #expect(!placement.isUsable, "\(name)の置き場所が置ける扱いになっている")
            #expect(!placement.hasFiniteGeometry, "\(name)が位置・倍率・回転の有限の判定を通った")
        }
    }
}

/// 絵の検査。GPU を要する。
@Suite(
    "Placement の軸ごとの倍率 (絵)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct PlacementAxisScaleDrawingTests {
    private func makeCanvas(width: Int = 200, height: Int = 300) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    /// 成分のビットが 1 つでも違う画素の数。
    private func differingPixels(_ a: PixelBuffer, _ b: PixelBuffer) -> Int {
        guard a.width == b.width, a.height == b.height else { return max(a.width * a.height, 1) }
        var count = 0
        var index = 0
        while index < a.components.count {
            for offset in 0..<4
            where a.components[index + offset].bitPattern != b.components[index + offset].bitPattern {
                count += 1
                break
            }
            index += 4
        }
        return count
    }

    private func picture(
        width: Int = 200, height: Int = 300, lit: Bool = false, _ body: (Canvas) -> Void
    ) throws -> PixelBuffer {
        let canvas = try makeCanvas(width: width, height: height)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            if lit { canvas.lights() }
            canvas.noStroke()
            canvas.fill(.linear(red: 0.8, green: 0.6, blue: 0.4))
            body(canvas)
        }
        return try canvas.target.readPixels()
    }

    private func coveredPixels(_ buffer: PixelBuffer) -> Int {
        var count = 0
        var index = 0
        while index < buffer.components.count {
            if buffer.components[index] > 0 || buffer.components[index + 1] > 0 { count += 1 }
            index += 4
        }
        return count
    }

    @Test("Issue の例: scale: Vector3(1, 4, 1) で置いた box(20) は、translate と scale で置いた box(20) と画素で一致する")
    func boxMatchesPushTranslateScale() throws {
        let placed = try picture(lit: true) { canvas in
            let unit = canvas.createShape { canvas.box(20) }
            canvas.shape(unit, at: [Placement(x: 100, y: 200, scale: Vector3(1, 4, 1))])
        }
        let direct = try picture(lit: true) { canvas in
            canvas.push()
            canvas.translate(100, 200, 0)
            canvas.scale(1, 4, 1)
            canvas.box(20)
            canvas.pop()
        }
        let gap = differingPixels(placed, direct)
        #expect(gap == 0, "置いた箱が translate・scale で置いた箱と \(gap) 画素違う")
        // 検査の前提: 伸ばしていない箱とは違う絵で、何かが描かれている
        let plain = try picture(lit: true) { canvas in
            canvas.push()
            canvas.translate(100, 200, 0)
            canvas.box(20)
            canvas.pop()
        }
        #expect(coveredPixels(placed) > 0, "何も描かれていない (検査の前提)")
        #expect(differingPixels(placed, plain) > 0, "伸ばしていない箱と同じ絵 (倍率が効いていない)")
    }

    @Test("回して置いても、倍率は回す前の軸に掛かる (translate・rotate・scale の順と一致する)")
    func axisScaleBeforeRotationMatchesDirect() throws {
        let placed = try picture(lit: true) { canvas in
            let unit = canvas.createShape { canvas.box(20) }
            canvas.shape(
                unit,
                at: [
                    Placement(
                        x: 100, y: 150, scale: Vector3(1, 4, 2), rotation: Vector3(0.4, 0.3, 0.5))
                ])
        }
        let direct = try picture(lit: true) { canvas in
            canvas.push()
            canvas.translate(100, 150, 0)
            canvas.rotateX(0.4)
            canvas.rotateY(0.3)
            canvas.rotateZ(0.5)
            canvas.scale(1, 4, 2)
            canvas.box(20)
            canvas.pop()
        }
        let gap = differingPixels(placed, direct)
        #expect(gap == 0, "回して置いた箱が \(gap) 画素違う")
    }

    @Test("平面の形 (矩形と円) も、軸ごとの倍率で置いた絵が translate・rotate・scale で置いた絵と一致する")
    func flatFormsMatchDirect() throws {
        let makeShape: (Canvas) -> Shape = { canvas in
            canvas.createShape {
                canvas.noStroke()
                canvas.fill(.linear(red: 0.8, green: 0.6, blue: 0.4))
                canvas.rect(-10, -10, 20, 20)
                canvas.circle(0, 0, 14)
            }
        }
        let placements = [
            Placement(x: 60, y: 80, scale: Vector3(3, 1, 1)),
            Placement(x: 140, y: 80, scale: Vector3(1, 3, 1), rotation: Vector3(0, 0, 0.6)),
            Placement(x: 60, y: 200, scale: Vector3(-2, 1.5, 1)),
        ]
        let placed = try picture { canvas in
            canvas.shape(makeShape(canvas), at: placements)
        }
        let direct = try picture { canvas in
            let shape = makeShape(canvas)
            for placement in placements {
                canvas.push()
                canvas.translate(placement.x, placement.y, 0)
                canvas.rotateZ(placement.rotation.z)
                canvas.scale(placement.axisScale.x, placement.axisScale.y, placement.axisScale.z)
                canvas.shape(shape)
                canvas.pop()
            }
        }
        let gap = differingPixels(placed, direct)
        #expect(gap == 0, "まとめて置いた絵が 1 つずつ置いた絵と \(gap) 画素違う")
        #expect(coveredPixels(placed) > 0, "何も描かれていない (検査の前提)")
    }

    @Test("一様の倍率で書いた置き場所の絵は、軸ごとの倍率 (1, 1, 1) を足しても変わらない")
    func uniformPlacementPictureIsUnchanged() throws {
        let uniform = try picture(lit: true) { canvas in
            let unit = canvas.createShape { canvas.box(20) }
            canvas.shape(
                unit,
                at: [Placement(x: 100, y: 150, scale: 2, rotation: Vector3(0.4, 0.3, 0.5))])
        }
        let viaAxis = try picture(lit: true) { canvas in
            let unit = canvas.createShape { canvas.box(20) }
            canvas.shape(
                unit,
                at: [Placement(x: 100, y: 150, scale: Vector3(2, 2, 2), rotation: Vector3(0.4, 0.3, 0.5))])
        }
        let gap = differingPixels(uniform, viaAxis)
        #expect(gap == 0, "scale: 2 と scale: Vector3(2, 2, 2) が \(gap) 画素違う")
    }

    @Test("軸ごとの倍率が数でない置き場所は置かれず、ほかは置かれて、注意が 1 度出る")
    func nonFiniteAxisScaleIsSkippedAndWarned() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.fill(.linear(red: 0.8, green: 0.6, blue: 0.4))
            let unit = canvas.createShape { canvas.rect(-10, -10, 20, 20) }
            canvas.shape(
                unit,
                at: [
                    Placement(x: 50, y: 50, scale: Vector3(1, Float.nan, 1)),
                    Placement(x: 150, y: 50, scale: Vector3(1, 2, 1)),
                    Placement(x: 50, y: 150, scale: Vector3(Float.infinity, 1, 1)),
                ])
        }
        let buffer = try canvas.target.readPixels()
        func lit(_ x: Int, _ y: Int) -> Bool {
            let index = (y * buffer.width + x) * 4
            return buffer.components[index] > 0
        }
        #expect(!lit(50, 50), "NaN の倍率の置き場所が描かれた")
        #expect(lit(150, 50), "有限の置き場所が描かれていない")
        #expect(!lit(50, 150), "無限の倍率の置き場所が描かれた")
        #expect(canvas.warnings.hasWarned(.badPlacement), "置けない置き場所を知らせていない")
    }
}
