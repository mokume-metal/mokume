// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
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
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-shader-\(UUID().uuidString)")
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
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-shader-\(UUID().uuidString)")
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

    @Test("平面の図形では、表面の位置も向きも 0")
    func flatShapesCarryNoSurface() throws {
        let canvas = try makeCanvas()
        // どれかが 0 でなければ赤、全部 0 なら緑。**向きは 3 つとも見る** (#847)
        let probe = try canvas.makeShader(
            """
            float4 paint(Fragment in, Values values) {
                float sum = dot(in.shapePosition, in.shapePosition)
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
}
