// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// `UnitSphere.metal` が写した入力の型が、Shapes.metal と一字一句同じか ([#1862])。
///
/// 写しは別のライブラリに置くため (`UnitSphere.metal` の冒頭)、Shapes.metal の型を直しても
/// 反射の検査 (`ShaderInterfaceTests`) は写しを見ない。ずれると単位球の頂点関数だけが
/// 違う並びで頂点と置き場所を読む。
///
/// [#1862]: https://github.com/mokume-metal/mokume/issues/1862
@Suite("単位球の頂点関数が写した型 (#1862)")
struct UnitSphereCopiedDeclarationTests {
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
        let blocks = try Self.copiedBlocks(in: Self.source("UnitSphere"))
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
        let diverged = try Self.source("UnitSphere")
            .replacingOccurrences(of: "    float4 normal0;", with: "    float4 normal0x;")
        let blocks = try Self.copiedBlocks(in: diverged)
        #expect(blocks.contains { !shapes.contains($0) })
    }
}

/// 正の半径の球の塗りを、単位球の頂点と置き場所ごとの半径で描く ([#1862])。
///
/// **約束は、半径ごとに頂点を組む経路と 1 ビットも違わないこと**: 線形の画素の全成分と、利用者の
/// 断片が読む `shapePosition` の全ビット。同じビルドで ``Canvas/sharesUnitSpheres`` を切り替えて
/// 比べる。単位球の頂点関数は積和の順を明示して一致させており (`UnitSphere.metal` の冒頭)、
/// コンパイラや GPU が変わってもこの検査がずれを誤差を許さずに見つける。
///
/// [#1862]: https://github.com/mokume-metal/mokume/issues/1862
@Suite(
    "単位球の塗り (#1862)", .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct UnitSphereTests {
    private static let width = 320
    private static let height = 200
    private static let count = 240

    enum Scene: String, CaseIterable {
        /// 重なる半透明 (裏 → 表のまとめ描き)・鏡映を含む非一様変換
        case translucent
        /// 鏡映・非一様変換
        case mirrored
        /// 斜めの視点の透視と、置き場所ごとに違う回転・拡大
        case oblique
        /// 影を落とす
        case shadow
        /// 線あり (線は半径ごとの形のまま)
        case stroke
        /// 細かさ 12 の、重なる半透明と斜めの視点
        case coarse
    }

    private static func setUp(_ c: Canvas, _ scene: Scene) {
        c.resetShader()
        c.background(.linear(red: 0.015, green: 0.02, blue: 0.03))
        c.noStroke()
        if scene == .oblique || scene == .coarse {
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

    private static func spheres(_ c: Canvas, _ scene: Scene) {
        let translucent = scene == .translucent || scene == .coarse
        let alpha: Float = translucent ? 0.45 : 1
        c.fill(LinearRGBA(premultipliedRed: 0.7 * alpha, green: 0.35 * alpha, blue: 0.15 * alpha, alpha: alpha))
        if scene == .stroke {
            c.stroke(.linear(red: 0.1, green: 0.65, blue: 0.8))
            c.strokeWeight(0.7)
        }
        let detail = scene == .coarse ? 12 : 24
        let spacing: Float = translucent ? 9 : 16
        for i in 0..<count {
            // 半径はどれも違う (同じ半径の形を使い回さない)
            let radius = 3.013 + Float(i) * 0.00917
            c.push()
            c.translate(Float(i % 20) * spacing + 8.13, Float(i / 20) * spacing + 8.27, Float(i % 7) * 0.31)
            if scene != .shadow && scene != .stroke {
                c.rotateX(0.171)
                c.rotateY(0.219)
                c.rotateZ(0.113)
                c.scale(i % 2 == 0 ? -1.13 : 1.13, 0.79, 1.31)
            }
            if scene == .oblique || scene == .coarse {
                c.rotateX(Float(i % 37) * 0.0917)
                c.rotateY(Float(i % 29) * -0.07013)
                c.translate(0.091, -0.173, Float(i % 13) * 4.73 - 20)
                c.scale(0.31 + Float(i % 7) * 0.19, 0.27 + Float(i % 11) * 0.21, 0.43 + Float(i % 5) * 0.39)
            }
            c.sphere(radius, detail: detail)
            c.pop()
        }
    }

    private static func render(_ c: Canvas, _ scene: Scene, shader: Shader? = nil) throws {
        try c.draw {
            setUp(c, scene)
            if let shader { c.shader(shader) }
            spheres(c, scene)
        }
    }

    /// 利用者の断片が読む `shapePosition` の全ビット。1 回に 1 バイトずつ、0…255 の整数として
    /// RGBA16F へ出す (half で正確に表せる)。4 回描いて 32 ビットへ組み直す。座標を読むのは塗りの
    /// 断片だけ — 線の被覆の合成が値を変えるので、線の断片 (`shapeNormal` が 0) は捨てる。
    private static func shapePositionBits(_ c: Canvas, _ scene: Scene, using shaders: [Shader]) throws -> [UInt32] {
        var bits = [UInt32](repeating: 0, count: width * height * 3)
        for (byte, shader) in shaders.enumerated() {
            try render(c, scene, shader: shader)
            let pixels = try c.target.readPixels()
            for index in bits.indices {
                let pixel = index / 3
                let value = Float(pixels.components[pixel * 4 + index % 3])
                // 背景は小数なので 0 になる。座標のある断片は必ず整数
                bits[index] |= UInt32(max(0, min(255, value.rounded()))) << (byte * 8)
            }
        }
        return bits
    }

    private static func byteShaders(on c: Canvas) throws -> [Shader] {
        try (0..<4).map { byte in
            try c.makeShader(
                """
                float4 paint(Fragment in, Values values) {
                    if (all(in.shapeNormal == float3(0.0))) { discard_fragment(); }
                    uint3 bits = as_type<uint3>(in.shapePosition);
                    return float4(float3((bits >> \(byte * 8)u) & uint3(255u)), 1.0);
                }
                """)
        }
    }

    @Test("単位球の塗りは、半径ごとに組む経路と線形の画素・shapePosition が 1 ビットも違わない", arguments: Scene.allCases)
    func matchesPerRadiusMeshesBitForBit(_ scene: Scene) throws {
        let gpu = try RenderDevice()
        let perRadius = try CanvasFixture.make(gpu: gpu, width: Self.width, height: Self.height)
        perRadius.sharesUnitSpheres = false
        let shared = try CanvasFixture.make(gpu: gpu, width: Self.width, height: Self.height)

        try Self.render(perRadius, scene)
        let expected = try perRadius.target.readPixels()
        try Self.render(shared, scene)
        let actual = try shared.target.readPixels()

        // 前提: 共有する側は、半径ごとの球を組んでいない (線は半径ごとの稜線のために組む)
        if scene != .stroke {
            #expect(shared.spheresFromUnit == 0, "単位球の経路を通っていない (球を \(shared.spheresFromUnit) 回組んだ)")
        }
        #expect(perRadius.spheresFromUnit == Self.count, "検査の前提: 比べる側が半径ごとの球を組んでいない")

        let linear = zip(expected.components, actual.components).filter { $0.bitPattern != $1.bitPattern }.count
        #expect(linear == 0, "\(scene): 線形の画素の \(linear) 成分が違う")
        #expect(expected.components.contains { $0.bitPattern != 0 })

        let expectedBits = try Self.shapePositionBits(perRadius, scene, using: Self.byteShaders(on: perRadius))
        let actualBits = try Self.shapePositionBits(shared, scene, using: Self.byteShaders(on: shared))
        #expect(expectedBits.contains { $0 != 0 }, "検査の前提: 断片の座標を読めていない")
        let differing = zip(expectedBits, actualBits).filter { $0 != $1 }.count
        #expect(differing == 0, "\(scene): shapePosition の \(differing) 成分のビットが違う")
    }

    @Test("半径の違う球は、形を組まずに 1 列で描く。半径を毎フレーム変えても組み直さない")
    func spheresOfManyRadiiShareOneRun() throws {
        let gpu = try RenderDevice()
        let c = try CanvasFixture.make(gpu: gpu, width: 64, height: 64)
        for frame in 0..<3 {
            try c.draw {
                c.noStroke()
                for i in 0..<50 {
                    c.push()
                    c.translate(Float(i % 8) * 8 + 4, Float(i / 8) * 8 + 4, 0)
                    c.sphere(1 + Float(i) * 0.05 + Float(frame) * 0.01)
                    c.pop()
                }
            }
            #expect(c.drawCallsInLastFrame == 1, "フレーム \(frame): 半径の違う球を 1 列で描いていない")
        }
        // 単位球を 1 度組むだけで、半径ごとの球は組まない
        #expect(c.solidMeshesBuilt == 1)
        #expect(c.spheresFromUnit == 0)
    }

    @Test("半径 0 の球と、保持する形へ記録する球は、半径ごとの形のまま置く")
    func zeroRadiusAndRecordingKeepPerRadiusMeshes() throws {
        let gpu = try RenderDevice()
        let c = try CanvasFixture.make(gpu: gpu, width: 64, height: 64)
        try c.draw { c.sphere(0) }
        #expect(c.spheresFromUnit == 1, "半径 0 の球を、半径ごとの形で置いていない")

        var held: Shape?
        try c.draw {
            held = c.createShape {
                c.sphere(5)
                c.sphere(6)
            }
        }
        // 記録は置き場所を頂点へ焼くので、半径ごとの形を組む (単位球は使わない)
        #expect(c.spheresFromUnit == 3, "記録する球を、半径ごとの形で置いていない")
        let recorded = try #require(held)
        try c.draw { c.shape(recorded) }
    }

    /// 利用者の断片を `color` の単色で書く。
    private static func paintBody(_ color: String) -> String {
        "float4 paint(Fragment in, Values values) { return float4(\(color), 1.0); }"
    }

    /// 単位球の列と半径ごとの形の列を交互に置き、それぞれの中心の色を返す。
    private static func alternatingSpheres(on c: Canvas, painted shader: Shader) throws -> [LinearRGBA] {
        try c.draw {
            c.background(.linear(red: 0, green: 0, blue: 0))
            c.noStroke()
            c.shader(shader)
            for (i, shares) in [true, false, true, false].enumerated() {
                c.sharesUnitSpheres = shares
                c.push()
                c.translate(Float(i * 20 + 10), 16, 0)
                c.sphere(7)
                c.pop()
            }
            c.sharesUnitSpheres = true
        }
        return (0..<4).map { c.get($0 * 20 + 10, 16) }
    }

    @Test("その場で組む再読込は、単位球の列の断片も揃えて差し替え、組めなければ前のまま残す")
    func reloadInPlaceSwapsUnitSphereStatesTogether() throws {
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
            "単位球の列か半径ごとの列の一方が、差し替える前の断片で描かれた")

        try "this is not MSL".write(to: url, atomically: true, encoding: .utf8)
        shader.reload()
        #expect(shader.failure != nil)
        #expect(
            try Self.alternatingSpheres(on: c, painted: shader) == [green, green, green, green],
            "組めなかった後に、前の断片のまま描いていない")
    }

    /// 窓の経路 (裏で組む) のスケッチ。単位球の列と半径ごとの形の列を交互に置く。
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
                target.sharesUnitSpheres = shares
                push()
                translate(Float(i * 20 + 10), 16, 0)
                sphere(7)
                pop()
            }
            target.sharesUnitSpheres = true
            resetShader()
        }
    }

    @Test("裏で組む再読込も、単位球の列の断片を揃えて差し替え、組めなければ前のまま残す")
    func backgroundReloadSwapsUnitSphereStatesTogether() throws {
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
            "単位球の列か半径ごとの列の一方が、差し替える前の断片で描かれた")

        try save("float4 paint(Fragment in, Values values) { return undeclared\(Int.random(in: 0...999_999)); }")
        #expect(try advance { shader.failure != nil }, "30 秒回しても、組めない中身の失敗を名乗らない")
        try runtime.advance()
        #expect(shader.generation == 1)
        #expect(try centres().allSatisfy { $0.green == 1 && $0.red < 0.01 }, "組めなかった後に、前の断片のまま描いていない")
    }
}
