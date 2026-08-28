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
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(target: target, gpu: gpu)
    }

    // MARK: - 平面と立体で同じ規約

    @Test("同じ断片が、平面にも立体にも同じ渡し方で効く")
    func theSameShaderPaintsBothKinds() throws {
        let canvas = try makeCanvas()
        let painted = try canvas.makeShader(
            flat, values: ["tint": .color(.opaque(red: 0.1, green: 0.9, blue: 0.3))])
        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            canvas.lights()
            canvas.noStroke()
            canvas.shader(painted)
            // 左に平面、右に立体
            canvas.fill(.opaque(red: 1, green: 0, blue: 0))
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
            flat, values: ["tint": .color(.opaque(red: 0.1, green: 0.9, blue: 0.3))])
        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
            canvas.lights()
            canvas.noStroke()
            canvas.fill(.opaque(red: 0.9, green: 0.2, blue: 0.2))
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
                canvas.background(.opaque(red: 0, green: 0, blue: 0))
                canvas.lights()
                canvas.noStroke()
                canvas.fill(.opaque(red: 0.8, green: 0.7, blue: 0.5))
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
            flat, values: ["tint": .color(.opaque(red: 0.2, green: 0.5, blue: 0.9))])
        try canvas.draw {
            canvas.background(.opaque(red: 0, green: 0, blue: 0))
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
                canvas.background(.opaque(red: 0, green: 0, blue: 0))
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
                canvas.background(.opaque(red: 0, green: 0, blue: 0))
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
}
