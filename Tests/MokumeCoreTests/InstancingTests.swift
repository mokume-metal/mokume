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
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
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
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.lights()
            canvas.noStroke()
            canvas.fill(.linear(red: 0.8, green: 0.6, blue: 0.4))
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
            canvas.fill(.linear(red: 1, green: 0.15, blue: 0.15))
            canvas.push()
            canvas.translate(26, 48, 0)
            canvas.box(20)
            canvas.pop()
            canvas.fill(.linear(red: 0.15, green: 0.3, blue: 1))
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

    @Test("まとめて渡した置き場所が上限を跨いでも、絵は変わらず描く回数だけが増える")
    func explicitPlacementsSplitAtTheCapacity() throws {
        // **まとめて渡す経路にも、上限を跨ぐ分岐がある** ([#894])。1 つずつ置く経路とは
        // 別の場所に書かれているので、別に踏ませないと通らない
        //
        // [#894]: https://github.com/mokume-metal/mokume/issues/894
        let places = grid(12)
        func form(_ canvas: Canvas) -> Shape { canvas.createShape { canvas.box(9) } }

        let full = try makeCanvas()
        let together = try scene(full) { canvas in canvas.shape(form(canvas), at: places) }
        #expect(full.drawCallsInLastFrame == 1)

        let limited = try makeCanvas()
        limited.instanceCapacity = 3
        let split = try scene(limited) { canvas in canvas.shape(form(canvas), at: places) }
        #expect(limited.drawCallsInLastFrame == 4, "上限で列が分かれていない")
        #expect(together.bytes == split.bytes, "まとめ方で絵が変わっている")
    }

    @Test("置き場所ごとに色を変えられる")
    func eachPlacementCanCarryItsOwnColor() throws {
        let canvas = try makeCanvas()
        let image = try scene(canvas) { canvas in
            let shape = canvas.createShape { canvas.box(20) }
            canvas.shape(
                shape,
                at: [
                    Placement(x: 26, y: 48, fill: .linear(red: 1, green: 0.2, blue: 0.2)),
                    Placement(x: 70, y: 48, fill: .linear(red: 0.2, green: 0.4, blue: 1)),
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
            $0.directionalLight(.linear(red: 0.8, green: 0.8, blue: 0.8), -0.5, 0.7, -0.5)
        }

        #expect(metal.bytes != plain.bytes, "まとめた描画に材質が効いていない")
        #expect(around.bytes != plain.bytes, "まとめた描画に周囲が効いていない")
        #expect(shadowed.bytes != plain.bytes, "まとめた描画に影が効いていない")
    }

    // MARK: - 区間が 2 つ以上の形をまとめて置く (#2305)
    //
    // 平面と距離関数の区間は奥行きで前後が決まらないので、重なる置き場所の前後は積んだ順で決まる。
    // まとめて置いても、1 つずつ置いたときと同じく**置き場所の順**に重なること (`Placement` の
    // 「1 ビットも変わらない」) を、作業空間の画素の成分のビットで見る。

    /// 黒地に `body` を描いて、作業空間の画素を読む。
    private func flatPicture(_ canvas: Canvas, _ body: (Canvas) -> Void) throws -> PixelBuffer {
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            body(canvas)
        }
        return try canvas.target.readPixels()
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

    /// 形を `placements` へまとめて置いた絵と、同じ置き場所へ 1 つずつ置いた絵 (どちらも新しい面)。
    /// 描く回数も返す。`check` は組み立てた形の前提 (区間の数) を見る。
    private func togetherAndOneByOne(
        size: Int = 200, _ make: (Canvas) -> Shape, at placements: [Placement],
        check: (Shape) -> Void = { _ in }
    ) throws -> (together: PixelBuffer, oneByOne: PixelBuffer, togetherCalls: Int, oneByOneCalls: Int) {
        let both = try makeCanvas(width: size, height: size)
        let together = try flatPicture(both) { canvas in
            let shape = make(canvas)
            check(shape)
            canvas.shape(shape, at: placements)
        }
        let apart = try makeCanvas(width: size, height: size)
        let oneByOne = try flatPicture(apart) { canvas in
            let shape = make(canvas)
            for placement in placements { canvas.shape(shape, at: [placement]) }
        }
        return (together, oneByOne, both.drawCallsInLastFrame, apart.drawCallsInLastFrame)
    }

    /// 起票の再現の形: 赤い `rect` (距離関数の区間) の上に青い `triangle` (平面の区間)。
    private func squareAndTriangle(_ canvas: Canvas) -> Shape {
        canvas.createShape {
            canvas.noStroke()
            canvas.fill(255, 0, 0)
            canvas.rect(0, 0, 40, 40)
            canvas.fill(0, 0, 255)
            canvas.triangle(0, 0, 40, 0, 0, 40)
        }
    }

    @Test("区間が 2 つの形を重なる置き場所へまとめて置いても、1 つずつ置いた絵と同じ前後で重なる")
    func overlappingPlacementsKeepTheirOrderAcrossRegions() throws {
        // P1 = (120, 100) と P2 = (100, 100) は重なる。(130, 125) は P1 からは (10, 25) で矩形と三角形の
        // 両方の内側、P2 からは (30, 25) で矩形の内側・三角形の外側。1 つずつ置けば最後に塗る矩形@P2 の
        // 赤が出る。区間の順に積むと三角形@P1 の青が上に出る (起票時は 400 画素違った)
        let placements = [Placement(x: 120, y: 100), Placement(x: 100, y: 100)]
        let result = try togetherAndOneByOne(squareAndTriangle, at: placements) { shape in
            #expect(shape.drawCallCount == 2, "前提: 矩形と三角形が別の区間になっていない")
        }
        #expect(differingPixels(result.together, result.oneByOne) == 0, "まとめて置いた絵が 1 つずつと違う")
        let pixel = result.together[130, 125]
        #expect(pixel.red > 0.5 && pixel.blue < 0.1, "後に置いた矩形の赤が上に出ていない (\(pixel))")
    }

    @Test("置き場所ごとの半透明の色でも、区間の途中で混ぜ方を変えた形でも、1 つずつ置いた絵と同じ")
    func translucentAndBlendedRegionsKeepThePlacementOrder() throws {
        // 半透明の色を掛けると混ざる順が絵に出る (起票時は 590 画素違った)
        let tinted = try togetherAndOneByOne(
            squareAndTriangle,
            at: [
                Placement(x: 120, y: 100, fill: LinearRGBA(premultipliedRed: 0.5, green: 0.25, blue: 0, alpha: 0.5)),
                Placement(x: 100, y: 100, fill: LinearRGBA(premultipliedRed: 0, green: 0.25, blue: 0.5, alpha: 0.5)),
            ])
        #expect(differingPixels(tinted.together, tinted.oneByOne) == 0, "半透明の色で置いた絵が 1 つずつと違う")

        // 平面の区間が 2 つ (普通に混ぜる三角形と、足し合わせる三角形)。足す区間を後回しにすると、
        // 後の置き場所の不透明な三角形が前の置き場所の足した色を覆わなくなる (起票時は 800 画素違った)
        let added = try togetherAndOneByOne(
            { canvas in
                canvas.createShape {
                    canvas.noStroke()
                    canvas.fill(255, 0, 0)
                    canvas.triangle(0, 0, 40, 0, 0, 40)
                    canvas.blendMode(.add)
                    canvas.fill(0, 0, 255)
                    canvas.triangle(0, 0, 40, 0, 0, 40)
                }
            },
            at: [Placement(x: 120, y: 100), Placement(x: 100, y: 100)]
        ) { shape in
            #expect(shape.drawCallCount == 2, "前提: 混ぜ方の違う 2 つの区間になっていない")
        }
        #expect(differingPixels(added.together, added.oneByOne) == 0, "混ぜ方を変えた形の絵が 1 つずつと違う")
    }

    @Test("立体と平面の区間が混ざった形も、まとめて置いた絵が 1 つずつ置いた絵と同じ")
    func mixedSolidAndFlatRegionsKeepThePlacementOrder() throws {
        // P2 の箱は P1 の矩形と重なる (箱は原点を中心に ±15、矩形は原点から 40)。平面の区間は奥行きで
        // 箱と前後を決めないので、1 つずつ置けば後に置いた箱が前の矩形の上に出る
        let result = try togetherAndOneByOne(
            { canvas in
                canvas.createShape {
                    canvas.noStroke()
                    canvas.fill(0, 255, 0)
                    canvas.box(30)
                    canvas.fill(255, 0, 0)
                    canvas.rect(0, 0, 40, 40)
                }
            },
            at: [Placement(x: 100, y: 100), Placement(x: 130, y: 120)]
        ) { shape in
            #expect(shape.drawCallCount == 2, "前提: 箱と矩形が別の区間になっていない")
        }
        #expect(differingPixels(result.together, result.oneByOne) == 0, "立体の混ざった形の絵が 1 つずつと違う")
    }

    @Test("区間が複数の平面・距離関数の形は、置き場所ごとに区間の数だけ描く (1 つずつ置いたときと同じ回数)")
    func flatRegionsDrawOncePerRegionAndPlacement() throws {
        // **速さの代償を数で名乗る** (#2305 の決定 B)。前後を置き場所の順に守るため、区間が 2 つ以上で
        // 平面・距離関数の区間を含む形は、置き場所ごとに区間を一巡して積む。平面と距離関数は列の種類が
        // 違うので、切り替わるたびに列が閉じる。重ならない置き場所でも同じ数え方である
        let placements = [Placement(x: 10, y: 10), Placement(x: 60, y: 10), Placement(x: 110, y: 10)]
        let result = try togetherAndOneByOne(squareAndTriangle, at: placements)
        #expect(result.togetherCalls == 2 * placements.count, "区間数 × 置き場所数で描いていない")
        #expect(result.togetherCalls == result.oneByOneCalls, "1 つずつ置いたときと描く回数が違う")
        #expect(differingPixels(result.together, result.oneByOne) == 0)
    }

    @Test("区間が 1 つの平面の形と、立体だけの形は、まとめて置いても描く回数が増えない")
    func singleRegionAndSolidOnlyShapesStayCollapsed() throws {
        let placements = [Placement(x: 120, y: 100), Placement(x: 100, y: 100), Placement(x: 80, y: 90)]
        // 区間が 1 つ (三角形 2 つ・同じ塗り)。置き場所が重なっても前後は置き場所の順のまま
        let flat = try togetherAndOneByOne(
            { canvas in
                canvas.createShape {
                    canvas.noStroke()
                    canvas.fill(255, 0, 0)
                    canvas.triangle(0, 0, 40, 0, 0, 40)
                    canvas.fill(0, 0, 255)
                    canvas.triangle(40, 0, 40, 40, 0, 40)
                }
            },
            at: placements
        ) { shape in
            #expect(shape.drawCallCount == 1, "前提: 三角形 2 つが 1 つの区間になっていない")
        }
        #expect(flat.togetherCalls == 1, "区間が 1 つの平面の形をまとめて置いて、1 回で描いていない")
        #expect(differingPixels(flat.together, flat.oneByOne) == 0)

        // 立体だけで区間が 2 つ (混ぜ方の変わり目)。奥行きが前後を決めるので、区間ごとに置き場所の
        // 並び全体を 1 度で積む今の速さのまま
        let solids = try togetherAndOneByOne(
            { canvas in
                canvas.createShape {
                    canvas.noStroke()
                    canvas.fill(0, 255, 0)
                    canvas.box(20)
                    canvas.blendMode(.add)
                    canvas.fill(0, 0, 255)
                    canvas.sphere(12)
                }
            },
            at: placements
        ) { shape in
            #expect(shape.drawCallCount == 2, "前提: 箱と球が混ぜ方の違う 2 つの区間になっていない")
        }
        #expect(solids.togetherCalls == 2, "立体だけの形をまとめて置いて、区間ごとに 1 回で描いていない")
    }
}
