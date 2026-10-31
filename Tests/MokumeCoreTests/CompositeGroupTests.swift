// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 合成の単位 (``Canvas/withCompositeGroup(opacity:covering:_:)``・#3560)。GPU を要する。
///
/// 約束は 6 つ — 群の不透明度は 1 度だけ掛かる (重なりが濃くならない)・呼んだ順に重なる・入れ子は掛け合わさる・
/// 中間面は外接に絞る・単位を使わない絵は変わらない (台帳)・公開の口は足さない (`make api-list`)。
/// 後ろの 2 つは、ここではなく台帳と一覧の検査が見る。
@Suite(
    "合成の単位",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct CompositeGroupTests {
    private static let size = 64

    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)
    private let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
    private let green = LinearRGBA.linear(red: 0, green: 1, blue: 0)
    private let blue = LinearRGBA.linear(red: 0, green: 0, blue: 1)

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: Self.size, height: Self.size)
    }

    private func pixels(of canvas: Canvas) throws -> DisplayImage {
        try canvas.output.encodeForDisplay()
    }

    /// 面いっぱいの外接 (縁の余白は単位の側が足す)。
    private var wholeSurface: PlaneBox {
        var box = PlaneBox(SIMD2(0, 0))
        box.add(SIMD2(Float(Self.size), Float(Self.size)))
        return box
    }

    private func box(_ left: Float, _ top: Float, _ right: Float, _ bottom: Float) -> PlaneBox {
        var box = PlaneBox(SIMD2(left, top))
        box.add(SIMD2(right, bottom))
        return box
    }

    /// 重なる白い円を 2 つ (中心 (24, 32) と (40, 32)・直径 24)。重なりは x = 32 の辺り。
    private func twoCircles(on canvas: Canvas) {
        canvas.noStroke()
        canvas.ellipse(24, 32, 24, 24)
        canvas.ellipse(40, 32, 24, 24)
    }

    private var circlesBox: PlaneBox { box(12, 20, 52, 44) }

    // MARK: - 完了条件 1: 重なりが濃くならない

    @Test("透明地の重なる白い円 2 つを不透明度 0.5 の単位に描くと、重なりも単独の部分も alpha 128")
    func overlapIsAsFaintAsTheRest() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.withCompositeGroup(opacity: 0.5, covering: circlesBox) { group in
                group.fill(white)
                twoCircles(on: group)
            }
        }
        let image = try pixels(of: canvas)
        // 重なり (32, 32)・左の円だけ (18, 32)・右の円だけ (46, 32)
        for (x, y) in [(32, 32), (18, 32), (46, 32)] {
            let alpha = Int(image[x, y].alpha)
            #expect(abs(alpha - 128) <= 1, "(\(x), \(y)) alpha \(alpha)")
        }
        // 円の外は透明のまま
        #expect(image[4, 4].alpha == 0)
    }

    @Test("対照: 単位なしで不透明度 0.5 の色で描くと、重なりは alpha 191 になる")
    func withoutTheGroupTheOverlapIsDarker() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.fill(white, 128)
            twoCircles(on: canvas)
        }
        let image = try pixels(of: canvas)
        let overlap = Int(image[32, 32].alpha)
        let alone = Int(image[18, 32].alpha)
        #expect(abs(overlap - 191) <= 1, "overlap \(overlap)")
        #expect(abs(alone - 128) <= 1, "alone \(alone)")
    }

    // MARK: - 完了条件 2: 呼んだ順

    @Test("単位の前に描いたものは下、後に描いたものは上に重なる")
    func callOrderIsKept() throws {
        // 単位の中は、面いっぱいの青 (不透明度 0.5)。前の赤・後の緑は左右の半分ずつ
        func draw(_ canvas: Canvas, group makeGroup: Bool) {
            canvas.noStroke()
            canvas.fill(red)
            canvas.rect(0, 0, 32, 64)
            if makeGroup {
                canvas.withCompositeGroup(opacity: 0.5, covering: wholeSurface) { group in
                    group.noStroke()
                    group.fill(blue)
                    group.rect(0, 0, 64, 64)
                }
            } else {
                canvas.fill(blue, 128)
                canvas.rect(0, 0, 64, 64)
            }
            canvas.fill(green)
            canvas.rect(16, 16, 32, 32)
        }
        let grouped = try makeCanvas()
        try grouped.draw { draw(grouped, group: true) }
        let direct = try makeCanvas()
        try direct.draw { draw(direct, group: false) }

        let image = try pixels(of: grouped)
        let reference = try pixels(of: direct)
        // 下の赤の上に半分の青 (8, 8)・何も無い所に半分の青 (56, 56)・最後に描いた緑は覆われない (32, 32)
        for (x, y) in [(8, 8), (56, 56), (32, 32), (20, 20), (44, 44)] {
            let (a, b) = (image[x, y], reference[x, y])
            #expect(
                abs(Int(a.red) - Int(b.red)) <= 1 && abs(Int(a.green) - Int(b.green)) <= 1
                    && abs(Int(a.blue) - Int(b.blue)) <= 1 && abs(Int(a.alpha) - Int(b.alpha)) <= 1,
                "(\(x), \(y)) group \(a) direct \(b)")
        }
        // 後に描いた緑は、半分の青に覆われず純色のまま
        #expect(image[32, 32] == (0, 255, 0, 255))
        // 前に描いた赤は半分の青に覆われて、赤だけではない
        #expect(image[8, 8].blue > 100 && image[8, 8].red > 100)
    }

    // MARK: - 完了条件 3: 入れ子

    @Test("不透明度 0.5 の単位の中の 0.5 の単位に描いた不透明な白は alpha 64")
    func nestedGroupsMultiply() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.withCompositeGroup(opacity: 0.5, covering: wholeSurface) { outer in
                outer.withCompositeGroup(opacity: 0.5, covering: box(8, 8, 56, 56)) { inner in
                    inner.noStroke()
                    inner.fill(white)
                    inner.rect(16, 16, 32, 32)
                }
            }
        }
        let alpha = Int(try pixels(of: canvas)[32, 32].alpha)
        #expect(abs(alpha - 64) <= 1, "alpha \(alpha)")
    }

    @Test("入れ子の外側にだけ別の図形があっても、外側の不透明度は 1 度だけ掛かる")
    func outerShapesAreFadedOnce() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.withCompositeGroup(opacity: 0.5, covering: wholeSurface) { outer in
                outer.noStroke()
                outer.fill(white)
                outer.rect(0, 0, 32, 64)
                outer.withCompositeGroup(opacity: 0.5, covering: box(32, 0, 64, 64)) { inner in
                    inner.noStroke()
                    inner.fill(white)
                    inner.rect(32, 0, 32, 64)
                }
            }
        }
        let image = try pixels(of: canvas)
        #expect(abs(Int(image[16, 32].alpha) - 128) <= 1)
        #expect(abs(Int(image[48, 32].alpha) - 64) <= 1)
    }

    // MARK: - 完了条件 4: 中間面は外接に絞る

    @Test("中間面の大きさは、外接を変換で移して縁の余白を足し、整数へ丸めた箱")
    func intermediateSurfaceFollowsTheBounds() throws {
        let canvas = try makeCanvas()
        var sizes: [(Int, Int)] = []
        try canvas.draw {
            // 恒等: 10.2…30.4 × 12.7…20.1 → 余白 1 を足して floor / ceil で 9…32 × 11…22
            canvas.withCompositeGroup(opacity: 0.5, covering: box(10.2, 12.7, 30.4, 20.1)) { group in
                sizes.append((Int(group.width), Int(group.height)))
            }
            // 平行移動と拡大は箱を移す: (0,0)…(10,5) を 2 倍して (4, 6) へ → 4…24 × 6…16 → 余白で 3…25 × 5…17
            canvas.translate(4, 6)
            canvas.scale(2, 2)
            canvas.withCompositeGroup(opacity: 0.5, covering: box(0, 0, 10, 5)) { group in
                sizes.append((Int(group.width), Int(group.height)))
            }
        }
        #expect(sizes.count == 2)
        #expect(sizes[0] == (23, 11), "\(sizes[0])")
        #expect(sizes[1] == (22, 12), "\(sizes[1])")
    }

    @Test("単位 1 つにつき、中の本体は 1 回走り、中間面は 1 フレームだけ描く")
    func oneGroupIsOneBodyAndOneFrame() throws {
        let canvas = try makeCanvas()
        var bodies = 0
        var group: Canvas?
        try canvas.draw {
            canvas.withCompositeGroup(opacity: 0.5, covering: wholeSurface) {
                bodies += 1
                group = $0
                $0.noStroke()
                $0.fill(white)
                twoCircles(on: $0)
            }
        }
        #expect(bodies == 1)
        #expect(group?.framesDrawn == 1, "\(String(describing: group?.framesDrawn))")
    }

    @Test("面より大きい外接は、面の大きさに絞る")
    func boundsAreClippedToTheSurface() throws {
        let canvas = try makeCanvas()
        var size: (Int, Int)?
        try canvas.draw {
            canvas.withCompositeGroup(opacity: 0.5, covering: box(-1000, -1000, 5000, 5000)) { group in
                size = (Int(group.width), Int(group.height))
            }
        }
        #expect(size?.0 == Self.size && size?.1 == Self.size, "\(String(describing: size))")
    }

    @Test("面の外にしか描かない単位・見えない不透明度・数でない不透明度では、中を描かない")
    func nothingVisibleMeansNoBody() throws {
        let canvas = try makeCanvas()
        var calls = 0
        try canvas.draw {
            canvas.withCompositeGroup(opacity: 0.5, covering: box(100, 100, 200, 200)) { _ in calls += 1 }
            canvas.withCompositeGroup(opacity: 0.5, covering: box(-200, -200, -100, -100)) { _ in calls += 1 }
            canvas.withCompositeGroup(opacity: 0, covering: wholeSurface) { _ in calls += 1 }
            canvas.withCompositeGroup(opacity: -1, covering: wholeSurface) { _ in calls += 1 }
            canvas.withCompositeGroup(opacity: .nan, covering: wholeSurface) { _ in calls += 1 }
        }
        #expect(calls == 0)
    }

    @Test("視点を決めているときは単位にならず、中を呼ばずに偽を返す")
    func aCustomCameraIsNotGrouped() throws {
        let canvas = try makeCanvas()
        var calls = 0
        var results: [Bool] = []
        try canvas.draw {
            results.append(canvas.withCompositeGroup(opacity: 0.5, covering: wholeSurface) { _ in calls += 1 })
            canvas.camera(32, 32, 200, 32, 32, 0, 0, 1, 0)
            results.append(canvas.withCompositeGroup(opacity: 0.5, covering: wholeSurface) { _ in calls += 1 })
        }
        // 視点を決める前は単位になり、後は断る (視点はフレームを越えないので、次のフレームでは戻る)
        #expect(results == [true, false])
        #expect(calls == 1)
    }

    @Test("フレームの外で呼んでも、中は描かない")
    func outsideTheFrameNothingIsDrawn() throws {
        let canvas = try makeCanvas()
        var calls = 0
        canvas.withCompositeGroup(opacity: 0.5, covering: wholeSurface) { _ in calls += 1 }
        #expect(calls == 0)
    }

    // MARK: - 位置: 単位あり・なしで同じ画素

    @Test("不透明度 1 の単位は、変換の下でも、単位なしで描いたのと同じ画素になる (縁のぼけも出ない)")
    func anOpaqueGroupMatchesDrawingDirectly() throws {
        func draw(_ canvas: Canvas, group makeGroup: Bool) {
            canvas.translate(32, 30)
            canvas.rotate(0.6)
            // 変換の下の外接 (線の太さの余白は含める): 半径 11.5 の円・20×6 の矩形・太さ 3 の線。縁の余白 (1) だけで
            // アンチエイリアスの縁が収まる、きつい箱にしてある
            func shapes(_ target: Canvas) {
                target.noStroke()
                target.fill(white)
                target.ellipse(0, 0, 23, 23)
                target.fill(red)
                target.rect(-10, -3, 20, 6)
                target.stroke(blue)
                target.strokeWeight(3)
                target.line(-14, 8, 14, 8)
            }
            if makeGroup {
                canvas.withCompositeGroup(opacity: 1, covering: box(-14, -11.5, 14, 9.5)) { shapes($0) }
            } else {
                shapes(canvas)
            }
        }
        let grouped = try makeCanvas()
        try grouped.draw { draw(grouped, group: true) }
        let direct = try makeCanvas()
        try direct.draw { draw(direct, group: false) }

        let (a, b) = (try pixels(of: grouped), try pixels(of: direct))
        var worst = 0
        for (left, right) in zip(a.bytes, b.bytes) { worst = max(worst, abs(Int(left) - Int(right))) }
        #expect(worst <= 1, "differs by \(worst)")
    }

    @Test("単位を閉じても、置く側の変換は元に戻り、後に描くものの位置は変わらない")
    func theTransformIsRestored() throws {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.translate(10, 0)
            canvas.withCompositeGroup(opacity: 0.5, covering: box(0, 0, 4, 4)) { group in
                group.fill(white)
                group.rect(0, 0, 4, 4)
            }
            canvas.noStroke()
            canvas.fill(red)
            canvas.rect(0, 20, 4, 4)
        }
        let image = try pixels(of: canvas)
        #expect(image[12, 22] == (255, 0, 0, 255))
        #expect(image[2, 22].alpha == 0)
        // 単位の中身は、平行移動の先 (10…14) に半分の濃さで出る
        #expect(abs(Int(image[12, 2].alpha) - 128) <= 1)
        #expect(image[2, 2].alpha == 0)
    }
}
