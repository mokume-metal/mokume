// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import MokumeCore

/// #1862 の採否を決める試作専用。通常の検査・公開 API へ採用しない。
@Suite("単位球の比較試作", .serialized,
       .enabled(if: RenderDevice.isAvailable, "Metal 4 GPU が必要"))
struct UnitSpherePrototypeTests {
    private let width = 640
    private let height = 400
    private var output: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["MOKUME_SPHERE_OUTPUT"]
            ?? "/private/tmp/mokume-sphere-1862/results")
    }

    private func setup(_ c: Canvas, scene: String) {
        c.resetShader()
        c.background(.linear(red: 0.015, green: 0.02, blue: 0.03))
        c.noStroke()
        if scene == "orbit" || scene == "random" {
            c.camera(371.27, 227.13, 417.19, 320.7, 200.3, 0.19, 0.03, 1, 0.02)
            c.perspective(1.137, 1.6, 1.3, 1900)
        } else if scene == "ortho" { c.ortho() }
        if scene == "add" { c.blendMode(.add) }
        if scene == "replace" { c.blendMode(.replace) }
        c.shadows(scene == "shadow")
        c.ambientLight(.linear(red: 0.15, green: 0.15, blue: 0.15))
        c.directionalLight(.linear(red: 0.85, green: 0.85, blue: 0.85), -0.4, 0.5, -1)
        if scene == "shadow" {
            c.castShadow(false)
            c.fill(.linear(red: 0.4, green: 0.4, blue: 0.4))
            c.push(); c.translate(320, 200, -20); c.box(640, 400, 2); c.pop()
            c.castShadow(true)
        }
    }

    private func spheres(_ c: Canvas, scene: String, frame: Int, radii: String) {
        let alpha: Float = scene == "alpha" ? 0.45 : 1
        c.fill(LinearRGBA(premultipliedRed: 0.7 * alpha, green: 0.35 * alpha, blue: 0.15 * alpha, alpha: alpha))
        if scene == "stroke" { c.stroke(.linear(red: 0.1, green: 0.65, blue: 0.8)); c.strokeWeight(0.7) }
        else { c.noStroke() }
        let detail = Int(ProcessInfo.processInfo.environment["MOKUME_SPHERE_DETAIL"] ?? "24") ?? 24
        let originalMode = c.prototypeUnitSpheres
        defer { c.prototypeUnitSpheres = originalMode }
        for i in 0..<1000 {
            if scene == "mixed" { c.prototypeUnitSpheres = originalMode && i % 2 == 0 }
            let r: Float = scene == "zero" ? 0 : (scene == "unit" ? 1 : (radii == "same" ? 4.123 : 3.013 + Float(i) * 0.00217
                + (radii == "moving" ? Float(frame) * 0.0031 : 0)))
            c.push()
            let spacing: Float = scene == "alpha" ? 9 : 16
            c.translate(Float(i % 40) * spacing + 8.13, Float(i / 40) * spacing + 8.27, Float(i % 7) * 0.31)
            if ["transform", "alpha", "orbit", "ortho", "add", "replace", "mixed", "random"].contains(scene) {
                c.rotateX(0.171); c.rotateY(0.219); c.rotateZ(0.113)
                c.scale(i % 2 == 0 ? -1.13 : 1.13, 0.79, 1.31)
            }
            if scene == "random" {
                c.rotateX(Float(i % 37) * 0.0917)
                c.rotateY(Float(i % 29) * -0.07013)
                c.translate(0.091, -0.173, Float(i % 13) * 4.73 - 20)
                c.scale(0.31 + Float(i % 7) * 0.19, 0.27 + Float(i % 11) * 0.21, 0.43 + Float(i % 5) * 0.39)
            }
            c.sphere(r, detail: detail)
            c.pop()
        }
    }

    private func render(_ c: Canvas, scene: String, frame: Int = 0, radii: String = "fixed",
                        held: Shape? = nil, shader: Shader? = nil) throws -> Double {
        var placed = 0.0
        try c.draw {
            let start = ProcessInfo.processInfo.systemUptime
            setup(c, scene: scene)
            if let shader { c.shader(shader) } else { c.resetShader() }
            if let held { c.shape(held) } else { spheres(c, scene: scene, frame: frame, radii: radii) }
            placed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        return placed
    }

    private func retained(_ c: Canvas, scene: String) throws -> Shape? {
        guard scene == "retained" else { return nil }
        var held: Shape?
        try c.draw { held = c.createShape { spheres(c, scene: scene, frame: 0, radii: "fixed") } }
        return held
    }

    @Test("光・影・半透明・線・保持形の全バイトと断片座標")
    func compatibility() throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let gpu = try RenderDevice()
        var report = "scene,linear_half_components,display_bytes,shape_float_components,max_ulp\n"
        let scenes = ProcessInfo.processInfo.environment["MOKUME_SPHERE_SCENES"]?.split(separator: ",").map(String.init)
            ?? ["light", "shadow", "alpha", "stroke", "retained", "transform"]
        for scene in scenes {
            let a = try CanvasFixture.make(gpu: gpu, width: width, height: height)
            let b = try CanvasFixture.make(gpu: gpu, width: width, height: height)
            b.prototypeUnitSpheres = ProcessInfo.processInfo.environment["MOKUME_SPHERE_CONTROL"] != "1"
            let ah = try retained(a, scene: scene), bh = try retained(b, scene: scene)
            _ = try render(a, scene: scene, held: ah)
            let ap = try a.target.readPixels(), ad = try a.target.encodeForDisplay()
            try a.target.writePNG(to: output.appendingPathComponent("\(scene)-before.png"))
            _ = try render(b, scene: scene, held: bh)
            let bp = try b.target.readPixels(), bd = try b.target.encodeForDisplay()
            try b.target.writePNG(to: output.appendingPathComponent("\(scene)-after.png"))
            let linear = zip(ap.components, bp.components).filter { $0.bitPattern != $1.bitPattern }.count
            let display = zip(ad.bytes, bd.bytes).filter { $0 != $1 }.count
            var bitsA = [UInt32](repeating: 0, count: width * height * 3)
            var bitsB = bitsA
            for byte in 0..<4 {
                // 各成分の1バイトを0...255の整数としてRGBA16Fへ出す。halfで全て正確に表せる。
                let source = """
                    float4 paint(Fragment in, Values values) {
                        // 線のcoverage合成がバイト値を変えるので、座標検査では塗りだけを読む。
                        // 通常画像の比較では線も含める。
                        if (all(in.shapeNormal == float3(0.0))) { discard_fragment(); }
                        uint3 bits = as_type<uint3>(in.shapePosition);
                        return float4(float3((bits >> \(byte * 8)u) & uint3(255u)), 1.0);
                    }
                    """
                let shader = try a.makeShader(source)
                for (index, c) in [a, b].enumerated() {
                    _ = try render(c, scene: scene, held: index == 0 ? ah : bh, shader: shader)
                    let pixels = try c.target.readPixels()
                    for pixel in 0..<(width * height) {
                        for component in 0..<3 {
                            let v = Float(pixels.components[pixel * 4 + component])
                            // 背景は小数なので0になる。座標のある断片は必ず整数。
                            let octet = UInt32(max(0, min(255, v.rounded())))
                            if index == 0 { bitsA[pixel * 3 + component] |= octet << (byte * 8) }
                            else { bitsB[pixel * 3 + component] |= octet << (byte * 8) }
                        }
                    }
                }
            }
            try ap.components.withUnsafeBufferPointer { Data(buffer: $0) }
                .write(to: output.appendingPathComponent("\(scene)-before.rgba16f"))
            try bp.components.withUnsafeBufferPointer { Data(buffer: $0) }
                .write(to: output.appendingPathComponent("\(scene)-after.rgba16f"))
            try bitsA.withUnsafeBufferPointer { Data(buffer: $0) }
                .write(to: output.appendingPathComponent("\(scene)-before.shape32"))
            try bitsB.withUnsafeBufferPointer { Data(buffer: $0) }
                .write(to: output.appendingPathComponent("\(scene)-after.shape32"))
            if scene != "zero" { #expect(bitsA.contains { $0 != 0 }, "断片座標を読めていない") }
            var different = 0, maxULP: UInt32 = 0
            for (a, b) in zip(bitsA, bitsB) where a != b {
                different += 1
                func ordered(_ x: UInt32) -> UInt32 { x & 0x80000000 != 0 ? ~x : x | 0x80000000 }
                let x = ordered(a), y = ordered(b)
                maxULP = max(maxULP, x > y ? x - y : y - x)
            }
            let line = "\(scene),\(linear),\(display),\(different),\(maxULP)"
            print("SPHERE_COMPAT,\(line)")
            report += line + "\n"
            try report.write(to: output.appendingPathComponent("compatibility.csv"), atomically: true, encoding: .utf8)
            // 同じ試作内の2経路の一致。mainとの比較はprobe runnerのREFERENCEで別に行う。
            #expect(linear == 0)
            #expect(display == 0)
            #expect(different == 0)
            #expect(ad.bytes.contains { $0 != 0 })
        }
    }


    @Test("単位球と従来の球の列を混ぜても正しく選び、断片を再読込する")
    func isolatedRouting() throws {
        let gpu = try RenderDevice()
        let c = try CanvasFixture.make(gpu: gpu, width: 80, height: 32)
        let directory = output.appendingPathComponent("reload-source")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("paint.metal")
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ color: String) throws {
            try "float4 paint(Fragment in, Values values) { return float4(\(color), 1.0); }"
                .write(to: url, atomically: true, encoding: .utf8)
        }
        try write("1.0, 0.0, 0.0")
        let shader = try c.loadShader(url.path)
        func draw() throws {
            try c.draw {
                c.background(.linear(red: 0, green: 0, blue: 0)); c.noStroke()
                c.shader(shader)
                for (i, useUnit) in [true, false, true, false].enumerated() {
                    c.prototypeUnitSpheres = useUnit
                    c.push(); c.translate(Float(i * 20 + 10), 16, 0)
                    // 両方式の形の鍵が同じ半径1でも列の入口は分ける。
                    c.scale(7, 7, 7); c.sphere(1, detail: 24); c.pop()
                }
            }
        }
        try draw()
        let first = try c.target.readPixels()
        for i in 0..<4 { #expect(c.get(i * 20 + 10, 16) == .linear(red: 1, green: 0, blue: 0)) }
        #expect(c.drawCallsInLastFrame == 4)
        try write("0.0, 1.0, 0.0")
        shader.reload()
        #expect(shader.failure == nil)
        try draw()
        for i in 0..<4 { #expect(c.get(i * 20 + 10, 16) == .linear(red: 0, green: 1, blue: 0)) }
        let second = try c.target.readPixels()
        #expect(first.components.map(\.bitPattern) != second.components.map(\.bitPattern))
        try "this is not MSL".write(to: url, atomically: true, encoding: .utf8)
        shader.reload()
        #expect(shader.failure != nil)
        try draw()
        #expect(try c.target.readPixels().components.map(\.bitPattern) == second.components.map(\.bitPattern))
    }

    @Test("専用ライブラリとパイプラインの生成費用を記録する")
    func setupCost() throws {
        let gpu = try RenderDevice()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var report = "round,canvas_ms,unit_library_ms,unit_states_ms,shader_ms,unit_shader_states_ms\n"
        for round in 0..<6 {
            let start = ProcessInfo.processInfo.systemUptime
            let c = try CanvasFixture.make(gpu: gpu, width: 64, height: 64)
            let canvasMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let shaderStart = ProcessInfo.processInfo.systemUptime
            let shader = try c.makeShader("float4 paint(Fragment in, Values values) { return float4(in.shapePosition * 0.03, 1.0); }")
            let shaderMS = (ProcessInfo.processInfo.systemUptime - shaderStart) * 1000
            report += "\(round),\(canvasMS),\(c.pipeline.unitSphereLibraryMilliseconds),\(c.pipeline.unitSphereStatesMilliseconds),\(shaderMS),\(shader.unitSphereBuildMilliseconds)\n"
        }
        try report.write(to: output.appendingPathComponent("setup.csv"), atomically: true, encoding: .utf8)
    }

    @Test("releaseで交互に従来と試作を測る")
    func performance() throws {
        #if DEBUG
        throw NSError(domain: "release build required", code: 1)
        #else
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let gpu = try RenderDevice()
        var report = "scene,radii,round,unit,place_ms,submit_ms,wall_ms,draws,spheres_from_unit,fill_cache\n"
        let scenes = ProcessInfo.processInfo.environment["MOKUME_SPHERE_SCENES"]?.split(separator: ",").map(String.init)
            ?? ["light", "shadow", "alpha", "stroke", "retained", "transform"]
        for scene in scenes {
            for radii in (scene == "light" ? ["same", "fixed", "moving"] : ["fixed"]) {
                let a = try CanvasFixture.make(gpu: gpu, width: width, height: height)
                let b = try CanvasFixture.make(gpu: gpu, width: width, height: height)
                b.prototypeUnitSpheres = ProcessInfo.processInfo.environment["MOKUME_SPHERE_CONTROL"] != "1"
                let ah = try retained(a, scene: scene), bh = try retained(b, scene: scene)
                for round in -3..<15 {
                    for unit in (round % 2 == 0 ? [false, true] : [true, false]) {
                        // 保持形は共有方式の対象外。同じ形・同じ面で切替だけを比較し、
                        // 別の巨大な保持バッファの配置差を性能差へ混ぜない。
                        let c = scene == "retained" ? a : (unit ? b : a)
                        c.prototypeUnitSpheres = unit && ProcessInfo.processInfo.environment["MOKUME_SPHERE_CONTROL"] != "1"
                        let builds = c.spheresFromUnit
                        let start = ProcessInfo.processInfo.systemUptime
                        let place = try render(c, scene: scene, frame: round + 3, radii: radii, held: scene == "retained" ? ah : (unit ? bh : ah))
                        let submitEnd = ProcessInfo.processInfo.systemUptime
                        try gpu.settle()
                        let end = ProcessInfo.processInfo.systemUptime
                        if round >= 0 {
                            let line = "\(scene),\(radii),\(round),\(unit),\(place),\((submitEnd - start)*1000-place),\((end-start)*1000),\(c.drawCallsInLastFrame),\(c.spheresFromUnit-builds),\(c.modelFills.count)"
                            report += line + "\n"
                        }
                    }
                }
                print("SPHERE_PERF,\(scene),\(radii),done")
                try report.write(to: output.appendingPathComponent("performance.csv"), atomically: true, encoding: .utf8)
            }
        }
        #endif
    }
}
