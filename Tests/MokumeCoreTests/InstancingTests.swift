// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 同じ形をたくさん置くときの検査。GPU を要する。
///
/// **絵だけでは、まとまっていなくても同じ絵が出る。** まとまっていることは
/// 描く回数で数え、まとまり方が絵を変えていないことは画素で見る ([ADR-0019] 決定 4)。
///
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
@Suite(
    "まとめ描き",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct InstancingTests {
    private func makeCanvas(width: Int = 96, height: Int = 96) throws -> Canvas {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }

    /// 置き場所を格子状に並べる。
    private func grid(_ count: Int) -> [Placement] {
        (0..<count).map { index in
            let column = Float(index % 6)
            let row = Float(index / 6)
            return Placement(
                x: 12 + column * 14, y: 12 + row * 14, z: 0,
                rotation: SIMD3(0.3, Float(index) * 0.2, 0))
        }
    }

    /// 光と塗りを揃えた場面で、渡した中身を描く。
    private func scene(_ canvas: Canvas, _ body: (Canvas) -> Void) throws -> DisplayImage {
        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            canvas.lights()
            canvas.noStroke()
            canvas.fill(.opaque(red: 0.8, green: 0.6, blue: 0.4))
            body(canvas)
        }
        return try canvas.target.encodeForDisplay()
    }

    // MARK: - 自動でまとまる

    @Test("同じ形を続けて置いても、描く回数は 1 回")
    func repeatedFormsCollapseIntoOneCall() throws {
        let canvas = try makeCanvas()
        _ = try scene(canvas) { canvas in
            for placement in grid(24) {
                canvas.push()
                canvas.translate(placement.x, placement.y, 0)
                canvas.box(9)
                canvas.pop()
            }
        }
        #expect(canvas.drawCallsInLastFrame == 1)
    }

    @Test("形が変わると列が分かれる")
    func changingTheFormOpensANewCall() throws {
        let canvas = try makeCanvas()
        _ = try scene(canvas) { canvas in
            canvas.box(10)
            canvas.box(10)
            canvas.sphere(8)
            canvas.box(10)
        }
        // 箱 2 つ → 球 → 箱 の 3 列
        #expect(canvas.drawCallsInLastFrame == 3)
    }

    @Test("まとまっても、1 つずつ置いたときと同じ絵になる")
    func batchingDoesNotChangeThePicture() throws {
        let together = try scene(try makeCanvas()) { canvas in
            for placement in grid(18) {
                canvas.push()
                canvas.translate(placement.x, placement.y, 0)
                canvas.box(9)
                canvas.pop()
            }
        }
        // 形を挟んで列を必ず分けさせる (置く場所は同じ)
        let apart = try scene(try makeCanvas()) { canvas in
            for placement in grid(18) {
                canvas.push()
                canvas.translate(placement.x, placement.y, 0)
                canvas.box(9)
                canvas.pop()
                canvas.sphere(0.0001)  // 列を分けるためだけの、見えない形
            }
        }
        #expect(together.bytes == apart.bytes)
    }

    @Test("塗りを変えても列は分かれず、置き場所ごとの色で出る")
    func fillTravelsWithEachPlacement() throws {
        // 塗りは**置き場所が持つ**ので、色を変えても列は分かれない。持たせ忘れると、
        // まとめた形が全部同じ色 (あるいは白) になる
        let canvas = try makeCanvas()
        let image = try scene(canvas) { canvas in
            canvas.fill(.opaque(red: 1, green: 0.15, blue: 0.15))
            canvas.push()
            canvas.translate(26, 48, 0)
            canvas.box(20)
            canvas.pop()
            canvas.fill(.opaque(red: 0.15, green: 0.3, blue: 1))
            canvas.push()
            canvas.translate(70, 48, 0)
            canvas.box(20)
            canvas.pop()
        }
        #expect(canvas.drawCallsInLastFrame == 1, "塗りを変えただけで列が分かれている")
        #expect(image[26, 48].red > image[26, 48].blue, "左が赤くない")
        #expect(image[70, 48].blue > image[70, 48].red, "右が青くない")
    }

    // MARK: - まとめきれない側を踏ませる

    @Test("1 列の上限を超えても、絵は変わらず描く回数だけが増える")
    func exceedingTheCapacityOnlyAddsCalls() throws {
        // **踏ませる手段が無い分岐は、検査できない分岐である。** 上限を下げて、
        // 普段は数万個置かないと通らない経路を必ず通す
        let full = try makeCanvas()
        let picture = try scene(full) { canvas in
            for placement in grid(12) {
                canvas.push()
                canvas.translate(placement.x, placement.y, 0)
                canvas.box(9)
                canvas.pop()
            }
        }
        #expect(full.drawCallsInLastFrame == 1)

        let limited = try makeCanvas()
        limited.instanceCapacity = 3
        let split = try scene(limited) { canvas in
            for placement in grid(12) {
                canvas.push()
                canvas.translate(placement.x, placement.y, 0)
                canvas.box(9)
                canvas.pop()
            }
        }
        #expect(limited.drawCallsInLastFrame == 4, "上限で列が分かれていない")
        #expect(picture.bytes == split.bytes, "まとめ方で絵が変わっている")
    }

    // MARK: - 明示的にまとめて渡す

    @Test("まとめて渡した絵が、1 つずつ置いた絵と一致する")
    func explicitPlacementsMatchTheLoop() throws {
        let places = grid(18)
        func form(_ canvas: Canvas) -> Shape { canvas.createShape { canvas.box(9) } }

        let canvas = try makeCanvas()
        let together = try scene(canvas) { canvas in
            canvas.shape(form(canvas), at: places)
        }
        #expect(canvas.drawCallsInLastFrame == 1, "まとめて渡したのに 1 回で描いていない")

        let apart = try scene(try makeCanvas()) { canvas in
            let shape = form(canvas)
            for placement in places {
                canvas.push()
                canvas.translate(placement.x, placement.y, placement.z)
                canvas.rotateX(placement.rotation.x)
                canvas.rotateY(placement.rotation.y)
                canvas.shape(shape)
                canvas.pop()
            }
        }
        #expect(together.bytes == apart.bytes)
    }

    @Test("置き場所ごとに色を変えられる")
    func eachPlacementCanCarryItsOwnColor() throws {
        let canvas = try makeCanvas()
        let image = try scene(canvas) { canvas in
            let shape = canvas.createShape { canvas.box(20) }
            canvas.shape(
                shape,
                at: [
                    Placement(x: 26, y: 48, fill: .opaque(red: 1, green: 0.2, blue: 0.2)),
                    Placement(x: 70, y: 48, fill: .opaque(red: 0.2, green: 0.4, blue: 1)),
                ])
        }
        #expect(canvas.drawCallsInLastFrame == 1)
        #expect(image[26, 48].red > image[26, 48].blue, "左が赤くない")
        #expect(image[70, 48].blue > image[70, 48].red, "右が青くない")
    }

    @Test("数でない置き場所は置かず、残りは置く")
    func brokenPlacementsAreSkipped() throws {
        let canvas = try makeCanvas()
        let image = try scene(canvas) { canvas in
            let shape = canvas.createShape { canvas.box(20) }
            canvas.shape(
                shape,
                at: [
                    Placement(x: .nan, y: 48), Placement(x: 48, y: 48),
                    Placement(x: 20, y: .infinity),
                ])
        }
        #expect(canvas.drawCallsInLastFrame == 1)
        #expect(image[48, 48].red > 0, "残りが置かれていない")
    }

    // MARK: - まとめた描画にも同じものが効く

    @Test("まとめた描画にも、影・周囲・材質が同じように効く")
    func batchedDrawingKeepsEverythingElse() throws {
        func picture(_ apply: (Canvas) -> Void) throws -> DisplayImage {
            let canvas = try makeCanvas()
            return try scene(canvas) { canvas in
                apply(canvas)
                for placement in grid(6) {
                    canvas.push()
                    canvas.translate(placement.x, placement.y + 20, 0)
                    canvas.box(11)
                    canvas.pop()
                }
            }
        }
        let plain = try picture { _ in }
        let metal = try picture { $0.metalness(1) }
        let around = try picture { $0.surroundings(.studio) }
        let shadowed = try picture {
            $0.shadows(true)
            $0.directionalLight(.opaque(red: 0.8, green: 0.8, blue: 0.8), -0.5, 0.7, -0.5)
        }

        #expect(metal.bytes != plain.bytes, "まとめた描画に材質が効いていない")
        #expect(around.bytes != plain.bytes, "まとめた描画に周囲が効いていない")
        #expect(shadowed.bytes != plain.bytes, "まとめた描画に影が効いていない")
    }
}
