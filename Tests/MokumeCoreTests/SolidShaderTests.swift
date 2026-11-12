// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Testing

@testable import MokumeCore

/// 利用者が書いた断片で立体を塗る検査。GPU を要する。
///
/// 見たいのは**平面と立体で規約が同じ**であること。同じ断片・同じ渡し方・同じ
/// 差し替えで、両方が塗れる。片方だけ違う扱いにすると、後から揃えるときに
/// どちらかの利用者のコードが壊れる。
@Suite(
    "立体を利用者の断片で塗る",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SolidShaderTests {
    /// 渡した色でべた塗りする断片。
    private let flat = """
        float4 paint(Fragment in, Values values) {
            return values.tint;
        }
        """

    private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
    }

    // MARK: - 平面と立体で同じ規約

    @Test("同じ断片が、平面にも立体にも同じ渡し方で効く")
    func theSameShaderPaintsBothKinds() throws {
        let canvas = try makeCanvas()
        let painted = try canvas.makeShader(
            flat, values: ["tint": .color(.linear(red: 0.1, green: 0.9, blue: 0.3))])
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.lights()
            canvas.noStroke()
            canvas.shader(painted)
            // 左に平面、右に立体
            canvas.fill(.linear(red: 1, green: 0, blue: 0))
            canvas.rect(4, 20, 24, 24)
            canvas.push()
            canvas.translate(46, 32, 0)
            canvas.box(22)
            canvas.pop()
        }
        let image = try canvas.target.encodeForDisplay()
        // どちらも断片の色 (緑) になる。塗り (赤) のままなら効いていない
        #expect(image[16, 32].green > image[16, 32].red, "平面に効いていない")
        #expect(image[46, 32].green > image[46, 32].red, "立体に効いていない")
    }

    @Test("組み込みの塗りへ戻せる")
    func theBuiltInPaintComesBack() throws {
        let canvas = try makeCanvas()
        let painted = try canvas.makeShader(
            flat, values: ["tint": .color(.linear(red: 0.1, green: 0.9, blue: 0.3))])
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.lights()
            canvas.noStroke()
            canvas.fill(.linear(red: 0.9, green: 0.2, blue: 0.2))
            canvas.shader(painted)
            canvas.push()
            canvas.translate(18, 32, 0)
            canvas.box(20)
            canvas.pop()
            canvas.resetShader()
            canvas.push()
            canvas.translate(46, 32, 0)
            canvas.box(20)
            canvas.pop()
        }
        let image = try canvas.target.encodeForDisplay()
        #expect(image[18, 32].green > image[18, 32].red, "断片が効いていない")
        #expect(image[46, 32].red > image[46, 32].green, "組み込みの塗りへ戻っていない")
    }

    @Test("立体の断片には、光と材質を通した色が届く")
    func theSolidFragmentSeesTheLitColor() throws {
        // `in.color` をそのまま返せば、組み込みの塗りと同じ絵になる。ここが
        // 光の前の色だと、断片を使った瞬間に陰影が消える
        let canvas = try makeCanvas()
        let passthrough = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values) {
                return in.color;
            }
            """)
        func picture(_ apply: (Canvas) -> Void) throws -> DisplayImage {
            let canvas = try makeCanvas()
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.lights()
                canvas.noStroke()
                canvas.fill(.linear(red: 0.8, green: 0.7, blue: 0.5))
                apply(canvas)
                canvas.push()
                canvas.translate(32, 32, 0)
                canvas.sphere(24)
                canvas.pop()
            }
            return try canvas.target.encodeForDisplay()
        }
        let built = try picture { _ in }
        let written = try picture { $0.shader(passthrough) }
        _ = canvas
        #expect(built.bytes == written.bytes)
    }

    // MARK: - まとめ描きと同居する

    @Test("まとめて描く経路でも、同じ断片で同じ絵が出る")
    func batchedSolidsAreShadedTheSameWay() throws {
        // 頂点の側 (置き場所) と塗りの側は別の仕組みなので、混ざらない
        let canvas = try makeCanvas(width: 96, height: 96)
        let painted = try canvas.makeShader(
            flat, values: ["tint": .color(.linear(red: 0.2, green: 0.5, blue: 0.9))])
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.lights()
            canvas.noStroke()
            canvas.shader(painted)
            for index in 0..<6 {
                canvas.push()
                canvas.translate(16 + Float(index) * 12, 48, 0)
                canvas.box(9)
                canvas.pop()
            }
        }
        #expect(canvas.drawCallsInLastFrame == 1, "断片を使うとまとまらなくなっている")
        let image = try canvas.target.encodeForDisplay()
        #expect(image[16, 48].blue > image[16, 48].red, "1 つ目が断片で塗られていない")
        #expect(image[76, 48].blue > image[76, 48].red, "最後が断片で塗られていない")
    }

    // MARK: - 差し替え

    @Test("保存を 2 回続けても、2 回とも差し替わる")
    func twoSavesInARowBothLand() throws {
        // **1 回だけでは判別力が無い** — 1 度目で控えが埋まり、2 度目が素通り
        // する形の壊れ方が残る
        let canvas = try makeCanvas()
        let directory = TestScratch.path("mokume-shader")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("paint.metal")

        func write(_ green: Float) throws {
            try """
                float4 paint(Fragment in, Values values) {
                    return float4(0.0, \(green), 0.0, 1.0);
                }
                """.write(to: url, atomically: true, encoding: .utf8)
        }
        try write(0.2)
        let shader = try canvas.loadShader(url.path)

        func brightness() throws -> Int {
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.lights()
                canvas.noStroke()
                canvas.shader(shader)
                canvas.push()
                canvas.translate(32, 32, 0)
                canvas.box(30)
                canvas.pop()
            }
            return Int(try canvas.target.encodeForDisplay()[32, 32].green)
        }
        let first = try brightness()

        try write(0.6)
        shader.reload()
        #expect(shader.generation == 1)
        let second = try brightness()
        #expect(second > first, "1 度目の差し替えが届いていない")

        try write(1.0)
        shader.reload()
        #expect(shader.generation == 2)
        let third = try brightness()
        #expect(third > second, "2 度目の差し替えが届いていない")
    }

    @Test("壊れた断片では絵が消えず、前の断片が残って理由が伝わる")
    func abrokenShaderKeepsThePicture() throws {
        let canvas = try makeCanvas()
        let directory = TestScratch.path("mokume-shader")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("paint.metal")
        try """
            float4 paint(Fragment in, Values values) {
                return float4(0.1, 0.9, 0.3, 1.0);
            }
            """.write(to: url, atomically: true, encoding: .utf8)
        let shader = try canvas.loadShader(url.path)

        func picture() throws -> DisplayImage {
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.lights()
                canvas.noStroke()
                canvas.shader(shader)
                canvas.push()
                canvas.translate(32, 32, 0)
                canvas.box(30)
                canvas.pop()
            }
            return try canvas.target.encodeForDisplay()
        }
        let before = try picture()

        try "これは MSL ではない".write(to: url, atomically: true, encoding: .utf8)
        shader.reload()
        let after = try picture()

        #expect(after.bytes == before.bytes, "壊れた断片で絵が変わっている")
        #expect(shader.failure != nil, "理由が残っていない")
        #expect(canvas.shaderFailures.count == 1, "観測へ載っていない")
        #expect(shader.generation == 0, "壊れた断片が差し替わったことになっている")
    }
    // MARK: - 表面の位置と向き (#367)

    /// 形自身の座標をそのまま色へ写す断片。
    ///
    /// **光を掛けない**ので、出た色がそのまま座標を名乗る。回しても色が変わらなければ、
    /// 断片が受け取っているのは画面の位置ではなく形自身の座標である。
    ///
    /// **端を折り返す** (`fract`) — 折り返さないと、範囲の外の座標が白へ張り付いて
    /// 「どこを指しても同じ色」になり、位置が届いていない実装でも色が揃ってしまう。
    private static let surface = """
        float4 paint(Fragment in, Values values) {
            return float4(fract(in.shapePosition / values.extent + 0.5), 1.0);
        }
        """

    /// 形自身の座標での向きを色へ写す断片。
    private static let facing = """
        float4 paint(Fragment in, Values values) {
            return float4(in.shapeNormal * 0.5 + 0.5, 1.0);
        }
        """

    /// 箱を `angle` だけ回して描き、**形の上の同じ点**が来た画素の色を返す。
    ///
    /// 追跡は `screenX` / `screenY` で行う (#375) — 形自身の座標の点が、回した後に
    /// どの画素へ来るかをそのまま引ける。
    private func sampleTurnedBox(
        painting body: String, values: [String: ShaderValue] = [:],
        at point: SIMD3<Float>, angle: Float
    ) throws -> (red: Int, green: Int, blue: Int) {
        let canvas = try makeCanvas(width: 128, height: 128)
        let painted = try canvas.makeShader(body, values: values)
        var screen = SIMD2<Float>.zero
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(painted)
            canvas.fill(.linear(red: 1, green: 1, blue: 1))
            canvas.push()
            canvas.translate(64, 64, 0)
            canvas.rotateX(0.6)
            canvas.rotateY(angle)
            canvas.box(60)
            screen = SIMD2(
                canvas.screenX(point.x, point.y, point.z),
                canvas.screenY(point.x, point.y, point.z))
            canvas.pop()
        }
        let pixel = try canvas.target.encodeForDisplay()[
            Int(screen.x.rounded()), Int(screen.y.rounded())]
        return (Int(pixel.red), Int(pixel.green), Int(pixel.blue))
    }

    @Test("回しても、断片が受け取る表面の位置は変わらない")
    func theSurfacePositionRidesAlongWithTheShape() throws {
        // 見えている面の 1 点。**箱の座標で指す**ので、回しても指す先は同じ木口である。
        // **回すと画面の上で大きく動く点**を選ぶ — 動かない点では、画面に貼り付いた
        // 塗りとの区別が付かない
        let onFace = SIMD3<Float>(24, 30, -20)
        let values: [String: ShaderValue] = ["extent": 120]
        let straight = try sampleTurnedBox(
            painting: Self.surface, values: values, at: onFace, angle: 0)
        let turned = try sampleTurnedBox(
            painting: Self.surface, values: values, at: onFace, angle: 0.9)

        #expect(abs(straight.red - turned.red) <= 16, "回すと表面の位置がずれている")
        #expect(abs(straight.green - turned.green) <= 16, "回すと表面の位置がずれている")
        #expect(abs(straight.blue - turned.blue) <= 16, "回すと表面の位置がずれている")

        // **色が本当に座標を名乗っているか。** ここを見ないと、位置が届かず一定の色に
        // なっているだけの絵でも上の 3 つが通ってしまう
        let elsewhere = try sampleTurnedBox(
            painting: Self.surface, values: values, at: SIMD3(-20, 30, 12), angle: 0)
        #expect(
            abs(straight.red - elsewhere.red) > 30 || abs(straight.blue - elsewhere.blue) > 30,
            "表面の別の点が同じ色になっている (位置が届いていない)")
    }

    @Test("画面の位置で塗ると、同じ点の色が回すたびに変わる")
    func paintingByTheScreenPlaceSlidesOffTheShape() throws {
        // #367 の症状そのもの。**上の検査が本当に区別していること**を、こちらで固定する
        let onFace = SIMD3<Float>(24, 30, -20)
        let byPlace = """
            float4 paint(Fragment in, Values values) {
                return float4(in.place, 0.5, 1.0);
            }
            """
        let straight = try sampleTurnedBox(painting: byPlace, at: onFace, angle: 0)
        let turned = try sampleTurnedBox(painting: byPlace, at: onFace, angle: 0.9)
        #expect(
            abs(straight.red - turned.red) > 20 || abs(straight.green - turned.green) > 20,
            "画面の位置で塗ったのに、形の上の同じ点で色が変わらない")
    }

    @Test("回しても、断片が受け取る面の向きは変わらない")
    func theSurfaceNormalRidesAlongWithTheShape() throws {
        let onFace = SIMD3<Float>(24, 30, -20)
        let straight = try sampleTurnedBox(painting: Self.facing, at: onFace, angle: 0)
        let turned = try sampleTurnedBox(painting: Self.facing, at: onFace, angle: 0.9)
        #expect(abs(straight.green - turned.green) <= 4, "回すと面の向きが変わっている")
        #expect(abs(straight.blue - turned.blue) <= 4, "回すと面の向きが変わっている")

        // 別の面は別の向き — 向きが届いていなければ、どの面も同じ色になる
        let onFront = try sampleTurnedBox(painting: Self.facing, at: SIMD3(6, 6, 30), angle: 0)
        #expect(
            abs(straight.green - onFront.green) > 40 && abs(straight.blue - onFront.blue) > 40,
            "並びの違う 2 つの面が同じ向きになっている")
    }

    @Test("面の向きは長さ 1 で届く")
    func theSurfaceNormalArrivesUnit() throws {
        let canvas = try makeCanvas()
        // 長さが 1 なら緑、違えば赤
        let probe = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values) {
                return abs(length(in.shapeNormal) - 1.0) < 0.01
                    ? float4(0.0, 1.0, 0.0, 1.0) : float4(1.0, 0.0, 0.0, 1.0);
            }
            """)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(probe)
            canvas.fill(.linear(red: 1, green: 1, blue: 1))
            canvas.push()
            canvas.translate(32, 32, 0)
            // **面ごとに向きが違う形**で見る。球なら 1 つの絵で多くの向きを通る
            canvas.sphere(24)
            canvas.pop()
        }
        let image = try canvas.target.encodeForDisplay()
        for point in [(32, 20), (32, 32), (24, 40), (40, 40)] {
            let pixel = image[point.0, point.1]
            #expect(pixel.green > 200 && pixel.red < 40, "\(point) の向きの長さが 1 でない")
        }
    }

    @Test("平面の図形では、表面の位置も世界の位置も向きも 0")
    func flatShapesCarryNoSurface() throws {
        let canvas = try makeCanvas()
        // どれかが 0 でなければ赤、全部 0 なら緑。**向きは 3 つとも見る** (#847)
        let probe = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values) {
                float sum = dot(in.shapePosition, in.shapePosition)
                    + dot(in.worldPosition, in.worldPosition)
                    + dot(in.shapeNormal, in.shapeNormal)
                    + dot(in.worldNormal, in.worldNormal)
                    + dot(in.viewNormal, in.viewNormal);
                return sum > 0.0 ? float4(1.0, 0.0, 0.0, 1.0) : float4(0.0, 1.0, 0.0, 1.0);
            }
            """)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(probe)
            canvas.rect(8, 8, 48, 48)
        }
        let pixel = try canvas.target.encodeForDisplay()[32, 32]
        #expect(pixel.green > 200 && pixel.red < 40, "平面に表面の位置か向きが入っている")
    }

    @Test("立体の線には向きが無く、位置は書いたときの座標のまま")
    func solidStrokesCarryThePositionTheyWereWrittenWith() throws {
        let canvas = try makeCanvas(width: 128, height: 128)
        // 向きがあれば赤 (3 つのどれでも)。無ければ、書いた座標を色にする
        let probe = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values) {
                if (dot(in.shapeNormal, in.shapeNormal) + dot(in.worldNormal, in.worldNormal)
                    + dot(in.viewNormal, in.viewNormal) > 0.0) {
                    return float4(1.0, 0.0, 0.0, 1.0);
                }
                return float4(in.shapePosition.xy / values.extent, 0.0, 1.0);
            }
            """,
            values: ["extent": 128])
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.stroke(.linear(red: 1, green: 1, blue: 1))
            canvas.strokeWeight(9)
            canvas.shader(probe)
            // **変換を通して置く。** 頂点を並べた形は変換を頂点へ焼き込むので、
            // 焼き込む前の座標が届いていなければ、ここで色がずれる
            canvas.push()
            canvas.translate(20, 0, 0)
            canvas.beginShape(.lines)
            canvas.vertex(24, 48, 0)
            canvas.vertex(104, 48, 0)
            canvas.endShape()
            canvas.pop()
        }
        // 書いた座標で (64, 48) の点は、変換のぶんだけ右へずれた画素に出る
        let pixel = try canvas.target.encodeForDisplay()[84, 48]
        #expect(pixel.red < 200, "線に面の向きが入っている")
        // 64 / 128 = 0.5、48 / 128 = 0.375 — 出力段を通るので、順序だけを見る
        #expect(pixel.red > pixel.green, "線が書いたときの座標を名乗っていない")
        #expect(pixel.green > 100 && pixel.green < 190, "線が書いたときの座標を名乗っていない")
    }

    @Test("頂点を並べて作った形でも、回すと模様が形に留まる")
    func handBuiltSolidsKeepTheirPatternToo() throws {
        // **組み込みの立体と同じ約束**が要る。片方だけ留まると、同じ形を書いても
        // 通した道具で模様の留まり方が変わる (ADR-0021 決定 5)
        func sample(angle: Float, at point: SIMD3<Float>) throws -> (red: Int, blue: Int) {
            let canvas = try makeCanvas(width: 128, height: 128)
            let painted = try canvas.makeShader(Self.surface, values: ["extent": 120])
            var screen = SIMD2<Float>.zero
            try canvas.draw {
                canvas.background(.linear(red: 0, green: 0, blue: 0))
                canvas.noStroke()
                canvas.shader(painted)
                canvas.fill(.linear(red: 1, green: 1, blue: 1))
                canvas.push()
                canvas.translate(64, 64, 0)
                canvas.rotateX(0.6)
                canvas.rotateY(angle)
                canvas.beginShape()
                canvas.vertex(-30, 0, -20)
                canvas.vertex(30, 0, -20)
                canvas.vertex(30, 0, 20)
                canvas.vertex(-30, 0, 20)
                canvas.endShape(.close)
                screen = SIMD2(
                    canvas.screenX(point.x, point.y, point.z),
                    canvas.screenY(point.x, point.y, point.z))
                canvas.pop()
            }
            let pixel = try canvas.target.encodeForDisplay()[
                Int(screen.x.rounded()), Int(screen.y.rounded())]
            return (Int(pixel.red), Int(pixel.blue))
        }
        // **回すと画面の上で大きく動く点**を追う (箱のときと同じ理由)
        let onFace = SIMD3<Float>(24, 0, -16)
        let straight = try sample(angle: 0, at: onFace)
        let turned = try sample(angle: 0.9, at: onFace)
        #expect(abs(straight.red - turned.red) <= 16, "回すと模様が滑っている")
        #expect(abs(straight.blue - turned.blue) <= 16, "回すと模様が滑っている")

        // 色が本当に座標を名乗っているか (箱のときと同じ理由)
        let elsewhere = try sample(angle: 0, at: SIMD3(-24, 0, 16))
        #expect(
            abs(straight.red - elsewhere.red) > 30 || abs(straight.blue - elsewhere.blue) > 30,
            "表面の別の点が同じ色になっている (位置が届いていない)")
    }

    // MARK: - 世界と視点の向き (#847)

    /// 向きの 1 欄を色へ写す断片。**光を掛けない**ので、出た色がそのまま向きを名乗る。
    private static func painting(normal field: String) -> String {
        """
        float4 paint(Fragment in, Values values) {
            return float4(in.\(field) * 0.5 + 0.5, 1.0);
        }
        """
    }

    /// 既定の視点がある距離。**同じ距離のまま回り込む**視点を作るのに使う。
    private static let fittingDistance: Float = 64 / tan(Float.pi / 6)

    /// 立体を 1 つ置き、**形の上の同じ点**が来た画素の色を返す。
    ///
    /// `place` が視点・変換・形を決める。点は置いた変換のまま `screenX` / `screenY` へ
    /// 通すので、視点を動かしても回しても形の上の同じ点を追える。
    private func sampleSolid(
        painting body: String, at point: SIMD3<Float>, place: (Canvas) -> Void
    ) throws -> (red: Int, green: Int, blue: Int) {
        let canvas = try makeCanvas(width: 128, height: 128)
        let painted = try canvas.makeShader(body)
        var screen = SIMD2<Float>.zero
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(painted)
            canvas.fill(.linear(red: 1, green: 1, blue: 1))
            canvas.push()
            place(canvas)
            screen = SIMD2(
                canvas.screenX(point.x, point.y, point.z),
                canvas.screenY(point.x, point.y, point.z))
            canvas.pop()
        }
        let pixel = try canvas.target.encodeForDisplay()[
            Int(screen.x.rounded()), Int(screen.y.rounded())]
        return (Int(pixel.red), Int(pixel.green), Int(pixel.blue))
    }

    /// 2 つの色が、どれかの成分で `margin` より離れているか。
    private static func differ(
        _ a: (red: Int, green: Int, blue: Int), _ b: (red: Int, green: Int, blue: Int),
        by margin: Int
    ) -> Bool {
        abs(a.red - b.red) > margin || abs(a.green - b.green) > margin
            || abs(a.blue - b.blue) > margin
    }

    /// 2 つの色が、どの成分でも `margin` 以内か。
    private static func agree(
        _ a: (red: Int, green: Int, blue: Int), _ b: (red: Int, green: Int, blue: Int),
        within margin: Int
    ) -> Bool {
        !differ(a, b, by: margin)
    }

    @Test("形を回すと、世界の向きも視点の向きも変わる")
    func turningTheShapeTurnsTheWorldAndViewNormals() throws {
        // **前の面**の 1 点を追う。上下の面は縦の軸で回しても向きが変わらないので、
        // 届いていない実装と区別が付かない
        let onFront = SIMD3<Float>(6, 6, 30)
        for field in ["worldNormal", "viewNormal"] {
            let straight = try sampleTurnedBox(
                painting: Self.painting(normal: field), at: onFront, angle: 0)
            let turned = try sampleTurnedBox(
                painting: Self.painting(normal: field), at: onFront, angle: 0.9)
            #expect(Self.differ(straight, turned, by: 40), "回しても \(field) が変わらない")
        }
        // 同じ回し方で形自身の向きは動かない — 上の差が本当に「変換の後」から来ている
        let straight = try sampleTurnedBox(
            painting: Self.painting(normal: "shapeNormal"), at: onFront, angle: 0)
        let turned = try sampleTurnedBox(
            painting: Self.painting(normal: "shapeNormal"), at: onFront, angle: 0.9)
        #expect(Self.agree(straight, turned, within: 6), "形自身の向きまで回っている")
    }

    @Test("視点を動かすと、視点の向きだけが変わる")
    func movingTheCameraTurnsOnlyTheViewNormal() throws {
        let onFront = SIMD3<Float>(6, 6, 30)
        func sample(_ field: String, orbit: Float?) throws -> (red: Int, green: Int, blue: Int) {
            try sampleSolid(painting: Self.painting(normal: field), at: onFront) { canvas in
                if let orbit {
                    // 同じ距離のまま横へ回り込む。形はまったく動かさない
                    canvas.camera(
                        64 + Self.fittingDistance * sin(orbit), 64,
                        Self.fittingDistance * cos(orbit), 64, 64, 0, 0, 1, 0)
                }
                canvas.translate(64, 64, 0)
                canvas.box(60)
            }
        }
        let world = try sample("worldNormal", orbit: nil)
        let worldMoved = try sample("worldNormal", orbit: 0.6)
        let view = try sample("viewNormal", orbit: nil)
        let viewMoved = try sample("viewNormal", orbit: 0.6)

        #expect(Self.agree(world, worldMoved, within: 6), "視点を動かすと世界の向きが変わっている")
        #expect(Self.differ(view, viewMoved, by: 40), "視点を動かしても視点の向きが変わらない")
        // **何も指定していない視点は面の正面から見ている**ので、2 つは一致する
        #expect(Self.agree(world, view, within: 6), "既定の視点で世界と視点の向きが食い違う")
    }

    @Test("視点の向きは、x が画面の右・y が画面の下・z が手前を指す")
    func theViewNormalFollowsTheScreen() throws {
        // **視点を傾けて**見る。傾けないと世界の軸と画面の軸が一致して、世界の向きを
        // そのまま渡している実装でも通ってしまう
        let canvas = try makeCanvas(width: 128, height: 128)
        let painted = try canvas.makeShader(Self.painting(normal: "viewNormal"))
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(painted)
            canvas.fill(.linear(red: 1, green: 1, blue: 1))
            canvas.camera(64, 64, Self.fittingDistance, 64, 64, 0, sin(Float(0.8)), cos(Float(0.8)), 0)
            canvas.translate(64, 64, 0)
            canvas.sphere(40)
        }
        let image = try canvas.target.encodeForDisplay()
        // 出力段を通るので、0.5 (向きの成分 0) は 188 前後に出る。そこからどちらへ振れたかを見る
        let right = image[96, 64]
        let below = image[64, 96]
        let middle = image[64, 64]
        #expect(right.red > 225 && right.green < 215, "画面の右の縁で x が正になっていない")
        #expect(below.green > 225 && below.red < 215, "画面の下の縁で y が正になっていない")
        #expect(middle.blue > 245, "正面で z が手前を向いていない")
    }

    @Test("平らな面を回すと、視点の向きの色が入れ替わる")
    func turningAPlaneChangesItsViewNormal() throws {
        // #847 の実測そのもの — 形自身の向きで塗った平らな面は、何度回しても 1 色だった
        func sample(_ field: String, angle: Float) throws -> (red: Int, green: Int, blue: Int) {
            try sampleSolid(painting: Self.painting(normal: field), at: .zero) { canvas in
                canvas.translate(64, 64, 0)
                canvas.rotateY(angle)
                canvas.plane(80, 80)
            }
        }
        #expect(
            Self.differ(try sample("viewNormal", angle: 0), try sample("viewNormal", angle: 0.9), by: 40),
            "平らな面を回しても視点の向きが変わらない")
        #expect(
            Self.agree(try sample("shapeNormal", angle: 0), try sample("shapeNormal", angle: 0.9), within: 6),
            "平らな面の形自身の向きが回っている")
    }

    @Test("拡大を含む置き場所でも、世界と視点の向きは長さ 1 で届く")
    func theWorldAndViewNormalsArriveUnitUnderScale() throws {
        let canvas = try makeCanvas(width: 128, height: 128)
        // 両方の長さが 1 なら緑、どちらかが違えば赤
        let probe = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values) {
                return abs(length(in.worldNormal) - 1.0) < 0.01
                    && abs(length(in.viewNormal) - 1.0) < 0.01
                    ? float4(0.0, 1.0, 0.0, 1.0) : float4(1.0, 0.0, 0.0, 1.0);
            }
            """)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(probe)
            canvas.fill(.linear(red: 1, green: 1, blue: 1))
            canvas.camera(90, 40, Self.fittingDistance, 64, 64, 0, 0, 1, 0)
            canvas.translate(64, 64, 0)
            // **軸ごとに違う倍率**で潰す。向きを移す行列が長さを変えるので、揃え直して
            // いなければここで長さが 1 から外れる
            canvas.scale(1.6, 1, 0.5)
            canvas.sphere(28)
        }
        let image = try canvas.target.encodeForDisplay()
        for point in [(64, 64), (50, 60), (78, 70), (64, 50)] {
            let pixel = image[point.0, point.1]
            #expect(pixel.green > 200 && pixel.red < 40, "\(point) の向きの長さが 1 でない")
        }
    }

    @Test("形から求めた向きは、巻き方によらず 3 つそろって見えている側を向く")
    func derivedNormalsFlipTogether() throws {
        let canvas = try makeCanvas(width: 128, height: 128)
        // 3 つとも手前 (z が正) を向いていれば緑。**どれか 1 つでも裏返り損ねると赤**
        let probe = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values) {
                return in.shapeNormal.z > 0.9 && in.worldNormal.z > 0.9 && in.viewNormal.z > 0.9
                    ? float4(0.0, 1.0, 0.0, 1.0) : float4(1.0, 0.0, 0.0, 1.0);
            }
            """)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(probe)
            canvas.fill(.linear(red: 1, green: 1, blue: 1))
            // 向きを書かずに三角形を 2 枚。**巻き方だけを逆にする** — 片方は表、片方は
            // 裏を向いて見える
            canvas.beginShape(.triangles)
            canvas.vertex(10, 20, 0)
            canvas.vertex(58, 20, 0)
            canvas.vertex(34, 100, 0)
            canvas.vertex(118, 20, 0)
            canvas.vertex(70, 20, 0)
            canvas.vertex(94, 100, 0)
            canvas.endShape()
        }
        let image = try canvas.target.encodeForDisplay()
        for point in [(34, 40), (94, 40)] {
            let pixel = image[point.0, point.1]
            #expect(pixel.green > 200 && pixel.red < 40, "\(point) の三角形で向きが見えている側を向いていない")
        }
    }

    // MARK: - 世界の位置と光を通す前の色 (#3573)

    /// 世界の位置が、**z = 0 の面の上では画素の位置そのもの**になることを見る断片。合えば緑、外れれば赤。
    ///
    /// 既定の視点は z = 0 の面を出す画素と 1:1 で写すので、そこに置いた平らな面の画素は、世界の位置の
    /// xy が `in.position` (出す画素で数えた画素の中心) と一致し、z が 0 になる。形自身の座標
    /// (`shapePosition`) や視点の座標を渡していれば、回した・ずらした面でここが外れる。
    static let worldMatchesScreen = """
        float4 paint(Fragment in, Values values) {
            return length(in.worldPosition - float3(in.position, 0.0)) < 0.25
                ? float4(0.0, 1.0, 0.0, 1.0) : float4(1.0, 0.0, 0.0, 1.0);
        }
        """

    /// 緑の画素と赤の画素を数える (どちらでもない画素は背景)。
    static func greenAndRed(_ image: DisplayImage) -> (green: Int, red: Int) {
        var green = 0
        var red = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let pixel = image[x, y]
                if pixel.green > 200 && pixel.red < 40 { green += 1 }
                if pixel.red > 200 && pixel.green < 40 { red += 1 }
            }
        }
        return (green, red)
    }

    @Test("立体の断片には、置き場所の変換を通した世界の座標での位置が届く")
    func theWorldPositionArrivesInWorldCoordinates() throws {
        let canvas = try makeCanvas(width: 128, height: 128)
        let probe = try canvas.makeShader(Self.worldMatchesScreen)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(probe)
            canvas.fill(.linear(red: 1, green: 1, blue: 1))
            // **ずらして回して拡げる** — 形自身の座標 (中心が 0) を渡していれば、ここで外れる
            canvas.translate(60, 70, 0)
            canvas.rotateZ(0.5)
            canvas.scale(1.5, 1, 1)
            canvas.plane(50, 50)
        }
        let image = try canvas.target.encodeForDisplay()
        let (green, red) = Self.greenAndRed(image)
        #expect(green > 2000, "面が世界の位置で塗られていない: 緑 \(green) 画素")
        #expect(red == 0, "世界の位置が画素の位置と食い違う画素が \(red) ある")
    }

    @Test("視点を動かしても、世界の位置は置いた面の上に留まる")
    func theWorldPositionStaysPutWhenTheCameraMoves() throws {
        let canvas = try makeCanvas(width: 128, height: 128)
        // 面は世界の z = 0・中心 (64, 64)・一辺 80。**視点の座標を渡していれば** z も xy も外れる
        let probe = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values) {
                float3 p = in.worldPosition;
                return abs(p.z) < 0.25 && abs(p.x - 64.0) < 40.5 && abs(p.y - 64.0) < 40.5
                    ? float4(0.0, 1.0, 0.0, 1.0) : float4(1.0, 0.0, 0.0, 1.0);
            }
            """)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.shader(probe)
            canvas.fill(.linear(red: 1, green: 1, blue: 1))
            canvas.camera(
                64 + Self.fittingDistance * sin(0.7), 40,
                Self.fittingDistance * cos(0.7), 64, 64, 0, 0, 1, 0)
            canvas.translate(64, 64, 0)
            canvas.plane(80, 80)
        }
        let (green, red) = Self.greenAndRed(try canvas.target.encodeForDisplay())
        #expect(green > 1000, "面が塗られていない: 緑 \(green) 画素")
        #expect(red == 0, "視点を動かすと世界の位置が面から外れる画素が \(red) ある")
    }

    @Test("まとめ描き (shape(_:at:)) でも、置き場所ごとの世界の位置が届く")
    func placedShapesCarryTheirWorldPosition() throws {
        let canvas = try makeCanvas(width: 128, height: 128)
        let probe = try canvas.makeShader(Self.worldMatchesScreen)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            canvas.fill(.linear(red: 1, green: 1, blue: 1))
            // 形は記録した時点の断片で塗る (#1649) ので、断片を当ててから記録する
            canvas.shader(probe)
            let tile = canvas.createShape { canvas.plane(30, 30) }
            // 置き場所が違えば世界の位置も違う — 1 か所目の値を使い回していれば、2 か所目が赤くなる
            canvas.shape(tile, at: [Placement(x: 32, y: 40), Placement(x: 92, y: 88, rotation: Vector3(0, 0, 0.4))])
        }
        let image = try canvas.target.encodeForDisplay()
        let (green, red) = Self.greenAndRed(image)
        for point in [(32, 40), (92, 88)] {
            let pixel = image[point.0, point.1]
            #expect(pixel.green > 200 && pixel.red < 40, "\(point) の置き場所が世界の位置で塗られていない")
        }
        #expect(green > 1200, "まとめ描きの面が世界の位置で塗られていない: 緑 \(green) 画素")
        #expect(red == 0, "まとめ描きで世界の位置が画素の位置と食い違う画素が \(red) ある")
    }

    /// 球 1 つと、まとめ描きの箱 2 つ (置き場所ごとに違う色) を置いた絵。
    private func litScene(lit: Bool, paint body: String?) throws -> DisplayImage {
        let canvas = try makeCanvas(width: 128, height: 128)
        let painted = try body.map { try canvas.makeShader($0) }
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            if lit { canvas.lights() } else { canvas.noLights() }
            canvas.noStroke()
            canvas.fill(.linear(red: 0.8, green: 0.5, blue: 0.2))
            // 形は記録した時点の断片で塗る (#1649) ので、断片を当ててから記録する
            if let painted { canvas.shader(painted) }
            let block = canvas.createShape { canvas.box(24) }
            canvas.push()
            canvas.translate(40, 44, 0)
            canvas.rotateY(0.6)
            canvas.sphere(30)
            canvas.pop()
            canvas.shape(
                block,
                at: [
                    Placement(x: 32, y: 100, fill: .linear(red: 0.2, green: 0.4, blue: 0.9)),
                    Placement(x: 96, y: 96, rotation: Vector3(0.3, 0.5, 0), fill: .linear(red: 0.3, green: 0.9, blue: 0.3)),
                ])
        }
        return try canvas.target.encodeForDisplay()
    }

    @Test("光の下の立体でも、baseColor は光を通す前の色で、光を切った組み込みの塗りと 1 画素も違わない")
    func theBaseColorIsTheColorBeforeTheLight() throws {
        let flat = try litScene(lit: false, paint: nil)
        let base = try litScene(
            lit: true,
            paint: """
                float4 paint(Fragment in, Values values) {
                    return in.baseColor;
                }
                """)
        #expect(base.bytes == flat.bytes, "光の下の baseColor が、光を切った塗りの色と違う")
        // **比べる相手が光で変わっていること** — 光が効かない絵どうしでは上の一致が何も言わない
        let litColor = try litScene(
            lit: true,
            paint: """
                float4 paint(Fragment in, Values values) {
                    return in.color;
                }
                """)
        #expect(litColor.bytes != flat.bytes, "光の下の color が光を切った絵と同じ (光が効いていない)")
    }

    @Test("光の効かない形 (平面・光を切った立体・立体の線) では、baseColor は color と同じ")
    func theBaseColorMatchesTheColorWithoutLight() throws {
        let canvas = try makeCanvas(width: 128, height: 128)
        let probe = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values) {
                return all(in.baseColor == in.color)
                    ? float4(0.0, 1.0, 0.0, 1.0) : float4(1.0, 0.0, 0.0, 1.0);
            }
            """)
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.shader(probe)
            canvas.noStroke()
            // 半透明 (乗算済み) — 4 成分そろって同じかを見る
            canvas.fill(LinearRGBA(premultipliedRed: 0.54, green: 0.18, blue: 0.12, alpha: 0.6))
            canvas.rect(8, 8, 40, 40)
            canvas.push()
            canvas.translate(92, 30, 0)
            canvas.sphere(22)
            canvas.pop()
            // 立体の線は、光の下でも光を受けない
            canvas.lights()
            canvas.stroke(.linear(red: 0.2, green: 0.5, blue: 0.9))
            canvas.strokeWeight(8)
            canvas.beginShape(.lines)
            canvas.vertex(10, 100, 0)
            canvas.vertex(118, 100, 0)
            canvas.endShape()
        }
        let image = try canvas.target.encodeForDisplay()
        for point in [(28, 28), (92, 30), (64, 100)] {
            let pixel = image[point.0, point.1]
            #expect(pixel.green > 200 && pixel.red < 40, "\(point) で baseColor が color と違う")
        }
        #expect(Self.greenAndRed(image).red == 0, "baseColor が color と違う画素がある")
    }

    @Test("#2458 の作例のトゥーンは noLights() 無しで書け、lights() の下の球が 4 段の明暗に塗り分けられる")
    func theToonExampleBandsTheSphereInFour() throws {
        let canvas = try makeCanvas(width: 128, height: 128)
        let toon = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values) {
                float n = max(dot(in.worldNormal, normalize(values.light)), 0.0);
                float band = floor(n * values.bands) / values.bands;
                return float4(in.baseColor.rgb * (0.3 + 0.7 * band), in.baseColor.a);
            }
            """,
            values: ["light": .vector3(Vector3(0.5, -0.6, 1)), "bands": 4])
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.lights()
            canvas.noStroke()
            canvas.fill(.linear(red: 0.9, green: 0.6, blue: 0.3))
            canvas.shader(toon)
            canvas.translate(64, 64, 0)
            canvas.sphere(50)
        }
        let image = try canvas.target.encodeForDisplay()
        // 球の上の色ごとの画素数。縁の混ざった画素を数えないよう、多く出た色だけを段とみなす
        var counts: [UInt32: Int] = [:]
        for y in 0..<image.height {
            for x in 0..<image.width {
                let pixel = image[x, y]
                guard pixel.red > 0 || pixel.green > 0 || pixel.blue > 0 else { continue }
                counts[UInt32(pixel.red) << 16 | UInt32(pixel.green) << 8 | UInt32(pixel.blue), default: 0] += 1
            }
        }
        let bands = counts.filter { $0.value > 60 }
        #expect(bands.count == 4, "球の段の数が 4 でない: \(bands.count) (\(bands.values.sorted()))")
    }
}
