// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 保持した形の立体の線が、**置いた後の位置と視点で**帯になるかの検査 (#1547)。GPU を要する。
///
/// 立体の線の帯は視点に合わせて組む (向き・画面の画素で測る幅・目の側への寄せ)。記録した
/// ときの視点で組んだ帯を頂点に焼くと、回す・奥へ置く・拡大する・ずらすのどれでも、
/// その場で描いた線と食い違う。見るのは「保持した形を置いた絵が、同じ置き方でその場で
/// 描いた絵と同じになる」ことで、数え方は Issue の完了条件のとおりにする。
@Suite(
    "保持した形の立体の線",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct RetainedSolidStrokeTests {
    private let size = 160

    /// 保持した形を置いた絵と、同じものをその場で描いた絵。
    ///
    /// `setup` は記録の外で両方に効かせる設定 (光など)、`content` は記録する中身、
    /// `placement` は置き方 (変換) である。
    private func pair(
        setup: (Canvas) -> Void = { _ in },
        content: @escaping (Canvas) -> Void,
        placement: @escaping (Canvas) -> Void
    ) throws -> (retained: PixelBuffer, immediate: PixelBuffer) {
        func picture(retained: Bool) throws -> PixelBuffer {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: size, height: size)
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                setup(canvas)
                let held = retained ? canvas.createShape { content(canvas) } : nil
                canvas.push()
                placement(canvas)
                if let held { canvas.shape(held) } else { content(canvas) }
                canvas.pop()
            }
            return try canvas.target.readPixels()
        }
        return (try picture(retained: true), try picture(retained: false))
    }

    /// どれかの成分の差が 0.02 を超える画素の数。
    private func differingPixels(_ a: PixelBuffer, _ b: PixelBuffer) -> Int {
        var count = 0
        for y in 0..<a.height {
            for x in 0..<a.width {
                let (p, q) = (a[x, y], b[x, y])
                let diff = [p.red - q.red, p.green - q.green, p.blue - q.blue, p.alpha - q.alpha]
                if diff.contains(where: { abs($0) > 0.02 }) { count += 1 }
            }
        }
        return count
    }

    /// 線だけ・白・太さ `weight` で `draw` を描く中身。
    private func strokeOnly(weight: Float, _ draw: @escaping (Canvas) -> Void) -> (Canvas) -> Void {
        { canvas in
            canvas.noFill()
            canvas.stroke(.linear(red: 1, green: 1, blue: 1))
            canvas.strokeWeight(weight)
            draw(canvas)
        }
    }

    // MARK: - 回して置く

    @Test("回して置いた箱の輪郭は、その場で描いた箱と同じ絵になる")
    func rotatedBoxOutlineMatchesImmediate() throws {
        let (retained, immediate) = try pair(
            content: strokeOnly(weight: 6) { $0.box(60) },
            placement: { canvas in
                canvas.translate(80, 80, 0)
                canvas.rotateY(1.2)
            })
        let differing = differingPixels(retained, immediate)
        #expect(differing <= 30, "保持とその場で \(differing) 画素違う (起票時 3361)")
        // 行 80 の右の縦の稜線を横切る。光る列の数が線の太さにあたる
        let lit = (100..<135).filter { retained[$0, 80].red > 0.3 }.count
        #expect(abs(lit - 12) <= 1, "保持した箱の稜線が \(lit) 列 (起票時 1・その場で 12)")
    }

    @Test("回して置いた円柱の輪郭は、その場で描いた円柱と同じ絵になる")
    func rotatedCylinderOutlineMatchesImmediate() throws {
        let (retained, immediate) = try pair(
            content: strokeOnly(weight: 4) { $0.cylinder(30, 60) },
            placement: { canvas in
                canvas.translate(80, 80, 0)
                canvas.rotateX(1.3)
            })
        let differing = differingPixels(retained, immediate)
        #expect(differing <= 30, "保持とその場で \(differing) 画素違う (起票時 2244)")
    }

    // MARK: - 置き方によらない太さと位置

    /// 縦の線 1 本を置く 8 通りと、線の中ほどの行。
    nonisolated static let placements: [(name: String, row: Int, place: @MainActor (Canvas) -> Void)] = [
        ("translate(80, 80, 0)", 80, { $0.translate(80, 80, 0) }),
        ("translate(60, 70, 0)", 70, { $0.translate(60, 70, 0) }),
        ("rotateY(0.6)", 80, { $0.translate(80, 80, 0); $0.rotateY(0.6) }),
        ("rotateY(1.4)", 80, { $0.translate(80, 80, 0); $0.rotateY(1.4) }),
        ("translate(80, 80, -150)", 80, { $0.translate(80, 80, -150) }),
        ("translate(80, 80, 60)", 80, { $0.translate(80, 80, 60) }),
        ("scale(2, 2, 2)", 80, { $0.translate(80, 80, 0); $0.scale(2, 2, 2) }),
        ("scale(0.5, 0.5, 0.5)", 80, { $0.translate(80, 80, 0); $0.scale(0.5, 0.5, 0.5) }),
    ]

    @Test("縦の線 1 本は、どう置いても太さ 6 の画素で、その場で描いた位置に出る", arguments: 0..<8)
    func lineKeepsItsWeightAndPositionWhereverPlaced(_ index: Int) throws {
        let placement = Self.placements[index]
        let (retained, immediate) = try pair(
            content: strokeOnly(weight: 6) { canvas in
                canvas.beginShape(.lines)
                canvas.vertex(0, -30, 0)
                canvas.vertex(0, 30, 0)
                canvas.endShape()
            },
            placement: placement.place)

        /// 行を横切る赤の和 (画面での太さ) と、赤で重みを付けた x (画素の中心で数える)。
        func across(_ image: PixelBuffer) -> (sum: Float, center: Float) {
            var sum: Float = 0
            var moment: Float = 0
            for x in 0..<image.width {
                let red = image[x, placement.row].red
                sum += red
                moment += red * (Float(x) + 0.5)
            }
            return (sum, sum > 0 ? moment / sum : .nan)
        }
        let held = across(retained)
        let here = across(immediate)
        #expect(
            abs(held.sum - 6) <= 0.5,
            "\(placement.name): 保持した線の太さが \(held.sum) (その場で \(here.sum))")
        #expect(
            abs(held.center - here.center) <= 0.5,
            "\(placement.name): 保持した線の重心が \(held.center)、その場で \(here.center)")
    }

    @Test("出っ張らせる端の正方形も、置いた先の線の向きで組み直される")
    func projectedCapsFollowThePlacedLine() throws {
        // 端の正方形は画面に写した線の向きに沿う (#1535)。記録したときの向きのまま焼くと、
        // 回して置いた先で線と端の向きがずれる
        let (retained, immediate) = try pair(
            content: strokeOnly(weight: 16) { canvas in
                canvas.strokeCap(.project)
                canvas.beginShape(.lines)
                canvas.vertex(-40, -40, 0)
                canvas.vertex(40, 40, 0)
                canvas.endShape()
            },
            placement: { canvas in
                canvas.translate(80, 80, 0)
                canvas.rotateY(0.9)
                canvas.rotateZ(0.5)
            })
        let differing = differingPixels(retained, immediate)
        #expect(differing <= 30, "保持とその場で \(differing) 画素違う")
    }

    // MARK: - 置き直す経路

    @Test("鏡映して置いた箱の輪郭も、その場で描いた箱と同じ絵になる")
    func mirroredBoxOutlineMatchesImmediate() throws {
        // 鏡映すると三角形の巻き方ごと頂点の並びを裏返して積む。組み直した位置も同じ
        // 並べ替えを通さないと、帯の角が入れ替わって絵が崩れる
        let (retained, immediate) = try pair(
            content: strokeOnly(weight: 6) { $0.box(60) },
            placement: { canvas in
                canvas.translate(80, 80, 0)
                canvas.scale(-1, 1, 1)
                canvas.rotateY(1.2)
            })
        let differing = differingPixels(retained, immediate)
        #expect(differing <= 30, "保持とその場で \(differing) 画素違う")
    }

    @Test("鏡映して置いた線も、帯のどの角も元の点の座標を名乗る")
    func mirroredStrokeKeepsItsShapePositions() throws {
        // 帯の角は、元になった線の端の座標 (形自身の座標) を断片へ渡す。鏡映して置くと
        // 三角形ごとに 2 点目と 3 点目を入れ替えて積むので、組み直した位置を同じように
        // 並べ替えないと、位置と座標が別の角を指し、座標で塗った色が帯の途中で崩れる
        let painting = """
            float4 paint(Fragment in, Values values) {
                return float4(fract(in.shapePosition / 80.0 + 0.5), 1.0);
            }
            """
        let (retained, immediate) = try pair(
            content: { canvas in
                do {
                    canvas.shader(try canvas.makeShader(painting))
                } catch {
                    Issue.record("座標で塗る断片を組めない: \(error)")
                }
                canvas.noFill()
                canvas.stroke(.linear(red: 1, green: 1, blue: 1))
                canvas.strokeWeight(10)
                canvas.beginShape(.lines)
                canvas.vertex(0, -40, -10)
                canvas.vertex(0, 40, 10)
                canvas.endShape()
            },
            placement: { canvas in
                canvas.translate(80, 80, 0)
                canvas.scale(-1, 1, 1)
                canvas.rotateY(0.6)
            })
        let differing = differingPixels(retained, immediate)
        #expect(differing <= 30, "保持とその場で \(differing) 画素違う")
    }

    @Test("記録の中で置き直した形の線も、外側の形を置いた先で組み直される")
    func nestedRetainedStrokeMatchesImmediate() throws {
        // 内側の形を、記録の中で鏡映して回して置く。線の部品は外側の記録へ渡り、
        // 外側の形を置いたときに組み直される
        func inner(_ canvas: Canvas) {
            canvas.scale(-1, 1, 1)
            canvas.rotateX(0.4)
        }
        func picture(retained: Bool) throws -> PixelBuffer {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: size, height: size)
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                let draw = strokeOnly(weight: 6) { $0.box(60) }
                let outer: Shape? =
                    retained
                    ? canvas.createShape {
                        let crate = canvas.createShape { draw(canvas) }
                        inner(canvas)
                        canvas.shape(crate)
                    } : nil
                canvas.push()
                canvas.translate(80, 80, 0)
                canvas.rotateY(1.2)
                if let outer {
                    canvas.shape(outer)
                } else {
                    inner(canvas)
                    draw(canvas)
                }
                canvas.pop()
            }
            return try canvas.target.readPixels()
        }
        let differing = differingPixels(try picture(retained: true), try picture(retained: false))
        #expect(differing <= 30, "保持とその場で \(differing) 画素違う")
    }

    @Test("組にした形の線も、それぞれの部品の位置で組み直される")
    func groupedStrokesMatchImmediate() throws {
        // 2 つ目の形の部品は、繋いだ並びの中で 1 つ目の頂点の数だけずれる
        let line: (Canvas) -> Void = { canvas in
            canvas.beginShape(.lines)
            canvas.vertex(-40, 40, -20)
            canvas.vertex(40, 40, 20)
            canvas.endShape()
        }
        func picture(retained: Bool) throws -> PixelBuffer {
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: size, height: size)
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                let box = strokeOnly(weight: 6) { $0.box(50) }
                let bar = strokeOnly(weight: 4, line)
                let group: Shape? =
                    retained
                    ? canvas.createShape { box(canvas) } + canvas.createShape { bar(canvas) } : nil
                canvas.push()
                canvas.translate(80, 80, 0)
                canvas.rotateY(1.2)
                if let group {
                    canvas.shape(group)
                } else {
                    box(canvas)
                    bar(canvas)
                }
                canvas.pop()
            }
            return try canvas.target.readPixels()
        }
        let differing = differingPixels(try picture(retained: true), try picture(retained: false))
        #expect(differing <= 30, "保持とその場で \(differing) 画素違う")
    }

    @Test("番号で指した立体の輪郭も、その場で描いた輪郭と同じ絵になる")
    func indexedOutlineMatchesImmediate() throws {
        // 添字の列では、線の頂点も自分の番号を名乗る。組み直しても頂点の数と並びは
        // 変わらないので、番号はそのまま使える。記録より先に立体を 1 つ置いておき、
        // 記録した部品の位置が形自身の 0 起点へ引き戻されていることも見る
        let (retained, immediate) = try pair(
            setup: { canvas in
                canvas.push()
                canvas.noStroke()
                canvas.fill(.linear(red: 0, green: 0, blue: 1))
                canvas.translate(20, 20, 0)
                canvas.sphere(8)
                canvas.pop()
            },
            content: strokeOnly(weight: 3) { canvas in
                let corners: [SIMD3<Float>] = [
                    SIMD3(-40, -30, 20), SIMD3(40, -30, -20), SIMD3(40, 30, -20), SIMD3(-40, 30, 20),
                ]
                canvas.beginShape(.triangles)
                for corner in corners { canvas.vertex(corner.x, corner.y, corner.z) }
                for number in [0, 1, 2, 0, 2, 3] { canvas.index(number) }
                canvas.endShape()
            },
            placement: { canvas in
                canvas.translate(64, 72, 0)
                canvas.rotateX(0.55)
            })
        let differing = differingPixels(retained, immediate)
        #expect(differing <= 30, "保持とその場で \(differing) 画素違う")
    }

    @Test("塗った面の縁の線は、置く側の太さによらず面に食われない")
    func strokeOverFillUsesTheRecordedWeight() throws {
        // 線は面に食われないよう、太さから決まる量だけ目の側へ寄せる。組み直すときに
        // 置く側の太さ (ここでは 0.1) で寄せると、傾いた面の縁で線が面に食われる
        let (retained, immediate) = try pair(
            setup: { $0.strokeWeight(0.1) },
            content: { canvas in
                canvas.fill(.linear(red: 1, green: 0, blue: 0))
                canvas.stroke(.linear(red: 0, green: 0, blue: 1))
                canvas.strokeWeight(2)
                canvas.plane(80, 60)
            },
            placement: { canvas in
                canvas.translate(60, 70, 0)
                canvas.rotateX(0.6)
                canvas.rotateY(-0.5)
            })
        let differing = differingPixels(retained, immediate)
        #expect(differing <= 30, "保持とその場で \(differing) 画素違う")
    }

    // MARK: - 塗りは変わらない

    @Test("塗りだけの箱は、回して置いても保持とその場で 1 画素も違わない")
    func fillOnlyBoxStaysIdentical() throws {
        let (retained, immediate) = try pair(
            setup: { $0.lights() },
            content: { canvas in
                canvas.noStroke()
                canvas.fill(.linear(red: 1, green: 1, blue: 1))
                canvas.box(60)
            },
            placement: { canvas in
                canvas.translate(80, 80, 0)
                canvas.rotateY(1.2)
            })
        #expect(differingPixels(retained, immediate) == 0)
    }
}
