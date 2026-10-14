// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// `UnitShape.metal` が写した入力の型が、Shapes.metal と一字一句同じか ([#1862])。
///
/// 写しは別のライブラリに置くため (`UnitShape.metal` の冒頭)、Shapes.metal の型を直しても
/// 反射の検査 (`ShaderInterfaceTests`) は写しを見ない。ずれると単位の形の頂点関数だけが
/// 違う並びで頂点と置き場所を読む。
///
/// [#1862]: https://github.com/mokume-metal/mokume/issues/1862
@Suite("単位の形の頂点関数が写した型 (#1862)")
struct UnitShapeCopiedDeclarationTests {
    private static func source(_ name: String) throws -> String {
        let url = try #require(ModuleResources.url(forResource: name, withExtension: "metal"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 写しの範囲の、空行で区切った塊のうち、コメントだけではないもの。
    static func copiedBlocks(in source: String) throws -> [String] {
        let start = try #require(source.range(of: "// MARK: - Shapes.metal の写し (ここから)"))
        let end = try #require(source.range(of: "// MARK: - Shapes.metal の写し (ここまで)"))
        return source[start.upperBound..<end.lowerBound]
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { block in
                block.split(separator: "\n").contains { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            }
    }

    @Test("写した塊は、どれも Shapes.metal にそのまま含まれる")
    func copiedBlocksAppearVerbatimInShapes() throws {
        let shapes = try Self.source("Shapes")
        let blocks = try Self.copiedBlocks(in: Self.source("UnitShape"))
        let names = ["struct FlatFrame", "struct SolidVertex", "struct SolidInstance", "kSolidFlipsNormal"]
        for name in names {
            #expect(blocks.contains { $0.contains(name) }, "写しの範囲に \(name) が無い")
        }
        for block in blocks {
            #expect(shapes.contains(block), "Shapes.metal と食い違う写し:\n\(block)")
        }
    }

    @Test("写しが 1 字違えば見つける")
    func aDivergedCopyIsCaught() throws {
        let shapes = try Self.source("Shapes")
        let diverged = try Self.source("UnitShape")
            .replacingOccurrences(of: "    float4 normal0;", with: "    float4 normal0x;")
        let blocks = try Self.copiedBlocks(in: diverged)
        #expect(blocks.contains { !shapes.contains($0) })
    }
}

/// 正の寸法の球・箱・平面・円柱の塗りと線を、単位の形と置き場所ごとの軸の寸法で描く ([#1862]・[#2386])。
///
/// **約束は、寸法ごとに頂点・稜線・線の骨を組む経路と 1 ビットも違わないこと**: 線形の画素の全成分と、
/// 利用者の断片が読む `shapePosition`・`shapeNormal` の全ビット。同じビルドで
/// ``Canvas/sharesUnitShapes`` を切り替えて比べる。単位の形の頂点関数は積和の順を明示して一致させて
/// おり (`UnitShape.metal` の冒頭)、コンパイラや GPU が変わってもこの検査がずれを誤差を許さずに見つける。
///
/// [#1862]: https://github.com/mokume-metal/mokume/issues/1862
/// [#2386]: https://github.com/mokume-metal/mokume/issues/2386
@Suite(
    "単位の形の塗りと線 (#1862・#2386)", .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct UnitShapeTests {
    private static let width = 320
    private static let height = 200
    private static let count = 120

    /// 単位の形に乗る形。寸法は置くたびに違う (同じ寸法の形を使い回さない)。
    enum Kind: String, CaseIterable {
        case sphere
        /// 細かさ 12 の球
        case coarseSphere
        case box
        /// 片面の平面 (裏から見える)
        case plane
        case cylinder
        /// 細かさ 7 の円柱
        case coarseCylinder

        func place(_ c: Canvas, _ i: Int) {
            let t = Float(i)
            switch self {
            case .sphere: c.sphere(3.013 + t * 0.00917)
            case .coarseSphere: c.sphere(3.013 + t * 0.00917, detail: 12)
            // 寸法の多くは、箱の向きを `normalize` で求めていた頃に長さが 1 ulp ずれた組 (#2386)
            case .box: c.box(5.1 + t * 0.013, 3.7 + t * 0.0071, 4.3 + t * 0.0113)
            case .plane: c.plane(6.1 + t * 0.011, 4.3 + t * 0.017)
            case .cylinder: c.cylinder(2.9 + t * 0.007, 5.3 + t * 0.013)
            case .coarseCylinder: c.cylinder(2.9 + t * 0.007, 5.3 + t * 0.013, detail: 7)
            }
        }
    }

    enum Scene: String, CaseIterable {
        /// 重なる半透明 (裏 → 表のまとめ描き)・鏡映を含む非一様変換
        case translucent
        /// 鏡映・非一様変換
        case mirrored
        /// 斜めの視点の透視と、置き場所ごとに違う回転・拡大
        case oblique
        /// 影を落とす
        case shadow
        /// 不透明な線 (組み込みの形は GPU の骨で広げる)
        case stroke
        /// 半透明の線 (CPU の帯で組む)
        case translucentStroke
    }

    nonisolated struct Case: CustomTestStringConvertible, Sendable {
        let kind: Kind
        let scene: Scene
        var testDescription: String { "\(kind.rawValue) / \(scene.rawValue)" }
    }

    nonisolated static let cases = Kind.allCases.flatMap { kind in Scene.allCases.map { Case(kind: kind, scene: $0) } }

    private static func setUp(_ c: Canvas, _ scene: Scene) {
        c.resetShader()
        c.background(.linear(red: 0.015, green: 0.02, blue: 0.03))
        c.noStroke()
        if scene == .oblique {
            c.camera(171.27, 127.13, 297.19, 160.7, 100.3, 0.19, 0.03, 1, 0.02)
            c.perspective(1.137, 1.6, 1.3, 1900)
        }
        c.shadows(scene == .shadow)
        c.ambientLight(.linear(red: 0.15, green: 0.15, blue: 0.15))
        c.directionalLight(.linear(red: 0.85, green: 0.85, blue: 0.85), -0.4, 0.5, -1)
        if scene == .shadow {
            c.castShadow(false)
            c.fill(.linear(red: 0.4, green: 0.4, blue: 0.4))
            c.push()
            c.translate(160, 100, -20)
            c.box(320, 200, 2)
            c.pop()
            c.castShadow(true)
        }
    }

    private static func shapes(_ c: Canvas, _ kind: Kind, _ scene: Scene) {
        let translucent = scene == .translucent
        let alpha: Float = translucent ? 0.45 : 1
        c.fill(LinearRGBA(premultipliedRed: 0.7 * alpha, green: 0.35 * alpha, blue: 0.15 * alpha, alpha: alpha))
        switch scene {
        case .stroke:
            c.stroke(.linear(red: 0.1, green: 0.65, blue: 0.8))
            c.strokeWeight(0.7)
        case .translucentStroke:
            c.stroke(LinearRGBA(premultipliedRed: 0.05, green: 0.33, blue: 0.4, alpha: 0.5))
            c.strokeWeight(1.3)
        default:
            break
        }
        let spacing: Float = translucent ? 9 : 16
        for i in 0..<count {
            c.push()
            c.translate(Float(i % 20) * spacing + 8.13, Float(i / 20) * spacing + 8.27, Float(i % 7) * 0.31)
            if scene == .translucent || scene == .mirrored || scene == .oblique {
                c.rotateX(0.171)
                c.rotateY(0.219)
                c.rotateZ(0.113)
                c.scale(i % 2 == 0 ? -1.13 : 1.13, 0.79, 1.31)
            }
            if scene == .oblique {
                c.rotateX(Float(i % 37) * 0.0917)
                c.rotateY(Float(i % 29) * -0.07013)
                c.translate(0.091, -0.173, Float(i % 13) * 4.73 - 20)
                c.scale(0.31 + Float(i % 7) * 0.19, 0.27 + Float(i % 11) * 0.21, 0.43 + Float(i % 5) * 0.39)
            }
            kind.place(c, i)
            c.pop()
        }
    }

    private static func render(_ c: Canvas, _ test: Case, shader: Shader? = nil) throws {
        try c.draw {
            setUp(c, test.scene)
            if let shader { c.shader(shader) }
            shapes(c, test.kind, test.scene)
        }
    }

    /// 利用者の断片が読む `shapePosition` か `shapeNormal` の全ビット。1 回に 1 バイトずつ、0…255 の
    /// 整数として RGBA16F へ出す (half で正確に表せる)。4 回描いて 32 ビットへ組み直す。読むのは塗りの
    /// 断片だけ — 線の被覆の合成が値を変えるので、線の断片 (`shapeNormal` が 0) は捨てる。
    private static func fragmentBits(_ c: Canvas, _ test: Case, using shaders: [Shader]) throws -> [UInt32] {
        var bits = [UInt32](repeating: 0, count: width * height * 3)
        for (byte, shader) in shaders.enumerated() {
            try render(c, test, shader: shader)
            let pixels = try c.target.readPixels()
            for index in bits.indices {
                let pixel = index / 3
                let value = Float(pixels.components[pixel * 4 + index % 3])
                // 背景は小数なので 0 になる。値のある断片は必ず整数
                bits[index] |= UInt32(max(0, min(255, value.rounded()))) << (byte * 8)
            }
        }
        return bits
    }

    private static func byteShaders(on c: Canvas, reading field: String) throws -> [Shader] {
        try (0..<4).map { byte in
            try c.makeShader(
                """
                float4 paint(Fragment in, Values values) {
                    if (all(in.shapeNormal == float3(0.0))) { discard_fragment(); }
                    uint3 bits = as_type<uint3>(in.\(field));
                    return float4(float3((bits >> \(byte * 8)u) & uint3(255u)), 1.0);
                }
                """)
        }
    }

    @Test("単位の形は、寸法ごとに組む経路と線形の画素・shapePosition・shapeNormal が 1 ビットも違わない", arguments: cases)
    func matchesPerDimensionMeshesBitForBit(_ test: Case) throws {
        let gpu = try RenderDevice()
        let perDimension = try CanvasFixture.make(gpu: gpu, width: Self.width, height: Self.height)
        perDimension.sharesUnitShapes = false
        let shared = try CanvasFixture.make(gpu: gpu, width: Self.width, height: Self.height)

        try Self.render(perDimension, test)
        let expected = try perDimension.target.readPixels()
        try Self.render(shared, test)
        let actual = try shared.target.readPixels()

        // 前提: 共有する側は寸法ごとの形を組まず (単位の形と、影の床の箱が使う単位の箱だけ)、比べる側は
        // 寸法ごとに組んでいる。球の線は #1606 から半径 1 の稜線を共有する
        #expect(shared.solidMeshesBuilt <= 2, "単位の形の経路を通っていない (形を \(shared.solidMeshesBuilt) 回組んだ)")
        #expect(perDimension.solidMeshesBuilt >= Self.count, "検査の前提: 比べる側が寸法ごとの形を組んでいない")

        let linear = zip(expected.components, actual.components).filter { $0.bitPattern != $1.bitPattern }.count
        #expect(linear == 0, "\(test.testDescription): 線形の画素の \(linear) 成分が違う")
        #expect(expected.components.contains { $0.bitPattern != 0 })

        for field in ["shapePosition", "shapeNormal"] {
            let expectedBits = try Self.fragmentBits(
                perDimension, test, using: Self.byteShaders(on: perDimension, reading: field))
            let actualBits = try Self.fragmentBits(shared, test, using: Self.byteShaders(on: shared, reading: field))
            #expect(expectedBits.contains { $0 != 0 }, "検査の前提: 断片の \(field) を読めていない")
            let differing = zip(expectedBits, actualBits).filter { $0 != $1 }.count
            #expect(differing == 0, "\(test.testDescription): \(field) の \(differing) 成分のビットが違う")
        }
    }

    @Test("寸法の違う形は、形を組まずに 1 列で描く。寸法を毎フレーム変えても組み直さない", arguments: Kind.allCases)
    func shapesOfManyDimensionsShareOneRun(_ kind: Kind) throws {
        let gpu = try RenderDevice()
        let c = try CanvasFixture.make(gpu: gpu, width: 64, height: 64)
        for frame in 0..<3 {
            try c.draw {
                c.noStroke()
                for i in 0..<50 {
                    c.push()
                    c.translate(Float(i % 8) * 8 + 4, Float(i / 8) * 8 + 4, 0)
                    c.scale(0.3, 0.3, 0.3)
                    kind.place(c, i + frame * 50)
                    c.pop()
                }
            }
            #expect(c.drawCallsInLastFrame == 1, "フレーム \(frame): 寸法の違う \(kind) を 1 列で描いていない")
        }
        // 単位の形を 1 度組むだけで、寸法ごとの形は組まない
        #expect(c.solidMeshesBuilt == 1)
        #expect(c.spheresFromUnit == 0)
    }

    @Test("線を引いて寸法を毎フレーム変えても、稜線と線の骨を組み直さない", arguments: [Kind.box, .plane, .cylinder, .coarseCylinder])
    func movingDimensionsReuseUnitEdgesAndSkeletons(_ kind: Kind) throws {
        let gpu = try RenderDevice()
        let c = try CanvasFixture.make(gpu: gpu, width: 64, height: 64)
        var made: [(edges: Int, skeletons: Int)] = []
        for frame in 0..<3 {
            try c.draw {
                c.stroke(.linear(red: 1, green: 1, blue: 1))
                for i in 0..<30 {
                    c.push()
                    c.translate(Float(i % 6) * 10 + 5, Float(i / 6) * 10 + 5, 0)
                    c.scale(0.4, 0.4, 0.4)
                    kind.place(c, i + frame * 30)
                    c.pop()
                }
            }
            made.append((c.solidEdges.made, c.solidStrokeGeometry.made))
        }
        // 単位の形の稜線 1 つと線の骨 1 つを、最初のフレームで作るだけ (平面の縁も閉じた輪なので骨で引く)
        #expect(made.allSatisfy { $0.edges == 1 }, "\(kind): 稜線を作った数 \(made.map(\.edges))")
        #expect(made.allSatisfy { $0.skeletons == 1 }, "\(kind): 線の骨を作った数 \(made.map(\.skeletons))")
        #expect(c.solidMeshesBuilt == 1, "\(kind): 寸法ごとの形を組んだ")
    }

    @Test("寸法 0 の形と、保持する形へ記録する形は、寸法ごとの形のまま置く")
    func zeroDimensionsAndRecordingKeepPerDimensionMeshes() throws {
        let gpu = try RenderDevice()
        let c = try CanvasFixture.make(gpu: gpu, width: 64, height: 64)
        try c.draw {
            c.sphere(0)
            c.box(0, 5, 5)
            c.cylinder(4, 0)
        }
        let zero: [SolidShape] = [
            .sphere(radius: 0, detail: Canvas.defaultSolidDetail), .box(width: 0, height: 5, depth: 5),
            .cylinder(radius: 4, height: 0, detail: Canvas.defaultSolidDetail),
        ]
        for shape in zero {
            #expect(c.solidMeshes[shape] != nil, "寸法 0 の \(shape) を、寸法ごとの形で置いていない")
        }

        var held: Shape?
        try c.draw {
            held = c.createShape {
                c.sphere(5)
                c.box(5, 6, 7)
                c.plane(3, 4)
                c.cylinder(2, 3)
            }
        }
        // 記録は置き場所を頂点へ焼くので、寸法ごとの形を組む (単位の形は使わない)
        let recorded: [SolidShape] = [
            .sphere(radius: 5, detail: Canvas.defaultSolidDetail), .box(width: 5, height: 6, depth: 7),
            .plane(width: 3, height: 4), .cylinder(radius: 2, height: 3, detail: Canvas.defaultSolidDetail),
        ]
        for shape in recorded {
            #expect(c.solidMeshes[shape] != nil, "記録する \(shape) を、寸法ごとの形で置いていない")
        }
        let shape = try #require(held)
        try c.draw { c.shape(shape) }
    }

    /// 利用者の断片を `color` の単色で書く。
    private static func paintBody(_ color: String) -> String {
        "float4 paint(Fragment in, Values values) { return float4(\(color), 1.0); }"
    }

    /// 単位の形の列と寸法ごとの形の列を交互に置き、それぞれの中心の色を返す。
    private static func alternatingSpheres(on c: Canvas, painted shader: Shader) throws -> [LinearRGBA] {
        try c.draw {
            c.background(.linear(red: 0, green: 0, blue: 0))
            c.noStroke()
            c.shader(shader)
            for (i, shares) in [true, false, true, false].enumerated() {
                c.sharesUnitShapes = shares
                c.push()
                c.translate(Float(i * 20 + 10), 16, 0)
                c.sphere(7)
                c.pop()
            }
            c.sharesUnitShapes = true
        }
        return (0..<4).map { c.get($0 * 20 + 10, 16) }
    }

    @Test("その場で組む再読込は、単位の形の列の断片も揃えて差し替え、組めなければ前のまま残す")
    func reloadInPlaceSwapsUnitShapeStatesTogether() throws {
        let gpu = try RenderDevice()
        let c = try CanvasFixture.make(gpu: gpu, width: 80, height: 32)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-unit-sphere-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("paint.metal")
        let red = LinearRGBA.linear(red: 1, green: 0, blue: 0)
        let green = LinearRGBA.linear(red: 0, green: 1, blue: 0)

        try Self.paintBody("1.0, 0.0, 0.0").write(to: url, atomically: true, encoding: .utf8)
        let shader = try c.loadShader(url.path)
        #expect(try Self.alternatingSpheres(on: c, painted: shader) == [red, red, red, red])

        try Self.paintBody("0.0, 1.0, 0.0").write(to: url, atomically: true, encoding: .utf8)
        shader.reload()
        #expect(shader.failure == nil)
        #expect(
            try Self.alternatingSpheres(on: c, painted: shader) == [green, green, green, green],
            "単位の形の列か寸法ごとの列の一方が、差し替える前の断片で描かれた")

        try "this is not MSL".write(to: url, atomically: true, encoding: .utf8)
        shader.reload()
        #expect(shader.failure != nil)
        #expect(
            try Self.alternatingSpheres(on: c, painted: shader) == [green, green, green, green],
            "組めなかった後に、前の断片のまま描いていない")
    }

    /// 窓の経路 (裏で組む) のスケッチ。単位の形の列と寸法ごとの形の列を交互に置く。
    final class Alternating: Sketch {
        var settings = SketchSettings(width: 80, height: 32, frameRate: 60)
        var paint: Shader?
        weak var target: Canvas?

        init() {}
        func draw() {
            background(.linear(red: 0, green: 0, blue: 0))
            guard let paint, let target else { return }
            noStroke()
            shader(paint)
            for (i, shares) in [true, false, true, false].enumerated() {
                target.sharesUnitShapes = shares
                push()
                translate(Float(i * 20 + 10), 16, 0)
                sphere(7)
                pop()
            }
            target.sharesUnitShapes = true
            resetShader()
        }
    }

    @Test("裏で組む再読込も、単位の形の列の断片を揃えて差し替え、組めなければ前のまま残す")
    func backgroundReloadSwapsUnitShapeStatesTogether() throws {
        let gpu = try RenderDevice()
        gpu.rebuildsShadersInBackground = true
        let sketch = Alternating()
        let runtime = try SketchRuntime(sketch: sketch, gpu: gpu, clock: nil, now: { 0 })
        try runtime.advance()
        sketch.target = runtime.canvas
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-unit-sphere-bg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("paint.metal")
        // 定数を毎回変えて、冷えた状態で組ませる (同じ中身は Metal の控えに当たる)
        let mark = Double.random(in: 0.0001...0.001)
        try Self.paintBody("1.0, \(mark), 0.0").write(to: url, atomically: true, encoding: .utf8)
        let shader = try runtime.canvas.loadShader(url.path)
        sketch.paint = shader
        try runtime.advance()

        func centres() throws -> [(red: Float, green: Float)] {
            let pixels = try runtime.target.readPixels()
            return (0..<4).map { (pixels[$0 * 20 + 10, 16].red, pixels[$0 * 20 + 10, 16].green) }
        }
        func advance(until done: () -> Bool) throws -> Bool {
            let deadline = DispatchTime.now() + 30
            while !done() {
                guard DispatchTime.now() < deadline else { return false }
                try runtime.advance()
                Thread.sleep(forTimeInterval: 0.005)
            }
            return true
        }
        func save(_ body: String) throws {
            let watcher = try #require(shader.watcher, "検査の前提: 断片を見張っていない")
            let before = watcher.arrivedEventCount
            try body.write(to: url, atomically: true, encoding: .utf8)
            let deadline = DispatchTime.now() + 5
            while watcher.arrivedEventCount == before, DispatchTime.now() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            try #require(watcher.arrivedEventCount > before, "検査の前提: 書き換えた事象が見張りに届いていない")
        }
        #expect(try centres().allSatisfy { $0.red == 1 })

        try save(Self.paintBody("\(mark), 1.0, 0.0"))
        #expect(try advance { shader.generation == 1 }, "30 秒回しても、裏で組んだ断片が差し替わらない")
        try runtime.advance()
        #expect(
            try centres().allSatisfy { $0.green == 1 && $0.red < 0.01 },
            "単位の形の列か寸法ごとの列の一方が、差し替える前の断片で描かれた")

        try save("float4 paint(Fragment in, Values values) { return undeclared\(Int.random(in: 0...999_999)); }")
        #expect(try advance { shader.failure != nil }, "30 秒回しても、組めない中身の失敗を名乗らない")
        try runtime.advance()
        #expect(shader.generation == 1)
        #expect(try centres().allSatisfy { $0.green == 1 && $0.red < 0.01 }, "組めなかった後に、前の断片のまま描いていない")
    }
}
