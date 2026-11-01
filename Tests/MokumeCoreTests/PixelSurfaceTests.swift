// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreVideo
import Foundation
import IOSurface
import Metal
import Testing

@testable import MokumeCore

/// 写像を決める道具。種を決めた混ぜ方で、0–255 を返す。
nonisolated enum TableMapping {
    static func hash(_ a: Int, _ b: Int, _ c: Int, _ salt: UInt64) -> UInt64 {
        var value = UInt64(a) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(b) &* 0xC2B2_AE3D_27D4_EB4F
            ^ UInt64(c) &* 0x1656_67B1_9E37_79F9 ^ salt
        value ^= value >> 29
        value = value &* 0xBF58_476D_1CE4_E5B9
        value ^= value >> 32
        return value
    }

    /// 詰め方の性質を満たす、でたらめな写像の青の値ごとの絵。赤と緑は (r, g) だけで決まり、青は 32 色の
    /// 区画ごとの頭 (224 以下) に、区画の中で 0 か 1 の段差を足していく。
    static func scrambledSlice(_ b: Int) -> [UInt8] {
        var image = [UInt8](repeating: 255, count: 256 * 256 * 4)
        for g in 0..<256 {
            var blue = 0
            for r in 0..<256 {
                blue = r % 32 == 0 ? Int(hash(b, g, r / 32, 3) % 225) : blue + Int(hash(b, g, r, 4) & 1)
                let index = (g * 256 + r) * 4
                image[index] = UInt8(hash(r, g, 0, 1) & 255)
                image[index + 1] = UInt8(hash(r, g, 0, 2) & 255)
                image[index + 2] = UInt8(blue)
            }
        }
        return image
    }

    /// 恒等の写像の青の値ごとの絵。
    static func identitySlice(_ b: Int) -> [UInt8] { slice(b, identity) }

    /// 検査の間で使い回す表 (debug では 1 つ作るのに数秒かかる)。
    static let scrambledTable = PixelSurface.ColorTable(converting: scrambledSlice)!
    static let identityTable = PixelSurface.ColorTable(converting: identitySlice)!

    /// 写像から、青の値ごとの絵 (ColorTable の作る口が受ける形) を作る。
    static func slice(_ blue: Int, _ map: (Int, Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var image = [UInt8](repeating: 255, count: 256 * 256 * 4)
        for green in 0..<256 {
            for red in 0..<256 {
                let (r, g, b) = map(red, green, blue)
                let index = (green * 256 + red) * 4
                image[index] = r
                image[index + 1] = g
                image[index + 2] = b
            }
        }
        return image
    }

    static func identity(_ r: Int, _ g: Int, _ b: Int) -> (UInt8, UInt8, UInt8) { (UInt8(r), UInt8(g), UInt8(b)) }
}

/// 面の色の表を詰めて引く (#2962)。GPU は要らない。
@Suite("面の色の表")
struct ColorTableTests {
    @Test("詰め方の性質を満たす写像は、全 16,777,216 色を写像どおりに引ける (恒等とでたらめの 2 種)")
    func everyColorRoundTrips() throws {
        let scrambled = TableMapping.scrambledTable
        let identity = TableMapping.identityTable
        #expect(scrambled.gpuBytes.count == 2_752_512, "2.625 MiB")
        var mismatches = 0
        for b in 0..<256 {
            let slice = TableMapping.scrambledSlice(b)
            for g in 0..<256 {
                for r in 0..<256 {
                    let index = (g * 256 + r) * 4
                    let got = scrambled.convert(red: UInt8(r), green: UInt8(g), blue: UInt8(b))
                    if got != (slice[index], slice[index + 1], slice[index + 2]) { mismatches += 1 }
                    if identity.convert(red: UInt8(r), green: UInt8(g), blue: UInt8(b)) != (UInt8(r), UInt8(g), UInt8(b)) {
                        mismatches += 1
                    }
                }
            }
        }
        #expect(mismatches == 0)
    }

    @Test("赤・緑が青で変わる、青の段差が 2 以上か下がる、不透明でない、大きさが違う写像からは作らない")
    func refusesWhatItCannotPack() {
        // 青が 1 のときだけ赤が違う
        #expect(
            PixelSurface.ColorTable { blue in
                TableMapping.slice(blue) { r, g, b in (UInt8(b == 1 ? (r + 1) & 255 : r), UInt8(g), UInt8(b)) }
            } == nil)
        // 赤を 1 段上げると青が 2 段上がる
        #expect(PixelSurface.ColorTable { blue in TableMapping.slice(blue) { r, g, _ in (UInt8(r), UInt8(g), UInt8(r % 32 * 2)) } } == nil)
        // 赤を上げると青が下がる
        #expect(PixelSurface.ColorTable { blue in TableMapping.slice(blue) { r, g, _ in (UInt8(r), UInt8(g), UInt8(255 - r)) } } == nil)
        // 透けた画素が 1 つある
        #expect(
            PixelSurface.ColorTable { blue in
                var image = TableMapping.slice(blue, TableMapping.identity)
                if blue == 200 { image[(17 * 256 + 3) * 4 + 3] = 254 }
                return image
            } == nil)
        // 絵の大きさが違う
        #expect(PixelSurface.ColorTable { _ in [UInt8](repeating: 255, count: 16) } == nil)
    }

    @Test("作り手の変換が投げたら、そのまま投げる")
    func rethrowsTheMakersFailure() {
        struct Broken: Error {}
        #expect(throws: Broken.self) {
            _ = try PixelSurface.ColorTable { blue in
                if blue == 7 { throw Broken() }
                return TableMapping.slice(blue, TableMapping.identity)
            }
        }
    }
}

/// 面を絵に書く (#2962)。GPU で引いた色が CPU で引いた色と bit で一致すること、面の寿命、逃げ道。
@Suite(
    "面を絵に書く",
    .enabled(if: RenderDevice.isAvailable, "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする"),
    .serialized)
@MainActor struct PixelSurfaceTests {
    private let side = 1024

    /// BGRA の面を作り、`paint(x, y)` が返す (赤, 緑, 青) で塗る。
    static func surface(
        width: Int, height: Int, pixelFormat: OSType = kCVPixelFormatType_32BGRA,
        paint: (Int, Int) -> (UInt8, UInt8, UInt8) = { _, _ in (0, 0, 0) }
    ) throws -> IOSurface {
        let surface = try #require(
            IOSurface(properties: [
                .width: width, .height: height, .bytesPerElement: 4, .pixelFormat: pixelFormat,
            ]))
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = base.advanced(by: y * surface.bytesPerRow)
            for x in 0..<width {
                let (r, g, b) = paint(x, y)
                row[x * 4] = b
                row[x * 4 + 1] = g
                row[x * 4 + 2] = r
                row[x * 4 + 3] = 255
            }
        }
        return surface
    }

    private func texels(_ image: Image, on gpu: RenderDevice) throws -> [SIMD4<Float16>] {
        try gpu.settle()
        var values = [SIMD4<Float16>](repeating: .zero, count: image.width * image.height)
        values.withUnsafeMutableBytes {
            image.texture.getBytes(
                $0.baseAddress!, bytesPerRow: image.width * 8,
                from: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0)
        }
        return values
    }

    /// CPU で表を引いた規範 (8 bit の Display P3 → 作業空間)。
    private func expected(_ surface: PixelSurface) -> [SIMD4<Float16>] {
        OutputStage.decode(surface.converted())
    }

    @Test("全 16,777,216 色を、GPU で引いた結果が CPU で引いた結果と半精度の bit で一致する (でたらめの表)")
    func everyColorMatchesTheCPU() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 32, height: 32)
        let table = TableMapping.scrambledTable
        let image = try canvas.createImage(side, side)
        var mismatched = 0
        for part in 0..<16 {
            let surface = try Self.surface(width: side, height: side) { x, y in
                let color = part << 20 | y << 10 | x
                return (UInt8(color & 255), UInt8(color >> 8 & 255), UInt8(color >> 16 & 255))
            }
            let frame = try #require(PixelSurface(surface, conversion: table))
            image.write(frame)
            #expect(image.surfaceInput != nil, "CPU の道だけで検査を通していない")
            try canvas.draw { canvas.image(image, 0, 0, 32, 32) }
            #expect(canvas.imageInputPass != nil)
            if try texels(image, on: gpu) != expected(frame) { mismatched += 1 }
        }
        #expect(mismatched == 0, "\(mismatched) / 16 枚で GPU と CPU が違う")
        #expect(
            gpu.commandFaultCount == 0,
            "GPU が仕事を \(gpu.commandFaultCount) 回打ち切った: \(gpu.lastCommandFault ?? "")")
    }

    @Test("恒等の表で書いた面は、同じ色の DisplayImage を書いた絵と bit で一致する (奇数の幅・行の詰め物を含む)")
    func identityMatchesTheDisplayImagePath() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 32, height: 32)
        let table = TableMapping.identityTable
        let (width, height) = (1031, 1019)
        let paint: (Int, Int) -> (UInt8, UInt8, UInt8) = { x, y in
            (UInt8(x * 7 & 255), UInt8(y * 13 & 255), UInt8((x ^ y) & 255))
        }
        let surface = try Self.surface(width: width, height: height, paint: paint)
        #expect(surface.bytesPerRow >= width * 4)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = paint(x, y)
                (bytes[(y * width + x) * 4], bytes[(y * width + x) * 4 + 1], bytes[(y * width + x) * 4 + 2]) = (r, g, b)
            }
        }
        let viaSurface = try canvas.createImage(width, height)
        let viaBytes = try canvas.createImage(width, height)
        viaSurface.write(try #require(PixelSurface(surface, conversion: table)))
        viaBytes.write(DisplayImage(width: width, height: height, bytes: bytes))
        try canvas.draw {
            canvas.image(viaSurface, 0, 0, 16, 16)
            canvas.image(viaBytes, 16, 0, 16, 16)
        }
        #expect(try texels(viaSurface, on: gpu) == texels(viaBytes, on: gpu))
    }

    @Test("BGRA でない面からは作らない")
    func refusesOtherFormats() throws {
        let table = TableMapping.identityTable
        let rgba = try Self.surface(width: 8, height: 8, pixelFormat: kCVPixelFormatType_32RGBA)
        #expect(PixelSurface(rgba, conversion: table) == nil)
        let bgra = try Self.surface(width: 8, height: 8)
        #expect(PixelSurface(bgra, conversion: table) != nil)
    }

    @Test("面は値がある間だけ使用中で、絵が次の 1 枚に替わるか捨てられ、GPU が読み終えると放す")
    func leaseFollowsTheValue() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 32, height: 32)
        let table = TableMapping.identityTable
        let before = SurfaceLease.live.load(ordering: .relaxed)
        let first = try Self.surface(width: side, height: side) { _, _ in (10, 20, 30) }
        let second = try Self.surface(width: side, height: side) { _, _ in (40, 50, 60) }
        var image: Image? = try canvas.createImage(side, side)
        do {
            let frame = try #require(PixelSurface(first, conversion: table))
            #expect(first.isInUse)
            image!.write(frame)
        }
        #expect(first.isInUse, "絵が持っている間は使用中")
        try canvas.draw { canvas.image(image!, 0, 0, 32, 32) }
        image!.write(try #require(PixelSurface(second, conversion: table)))
        try gpu.settle()
        try canvas.draw { canvas.image(image!, 0, 0, 32, 32) }
        try gpu.settle()
        #expect(!first.isInUse, "次の 1 枚に替わり、GPU が読み終えたら放す")
        #expect(second.isInUse)
        image = nil
        try canvas.draw { canvas.background(.transparent) }
        try gpu.settle()
        #expect(!second.isInUse, "絵を捨てて GPU が読み終えたら放す")
        #expect(SurfaceLease.live.load(ordering: .relaxed) == before)
    }

    @Test("同じ面を書き直してもテクスチャは作り直さず、しばらく使わない面のテクスチャは手放す")
    func texturesFollowSurfaces() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 32, height: 32)
        let table = TableMapping.identityTable
        let first = try Self.surface(width: side, height: side) { _, _ in (10, 20, 30) }
        let second = try Self.surface(width: side, height: side) { _, _ in (40, 50, 60) }
        let image = try canvas.createImage(side, side)
        for surface in [first, first, second, first] {
            image.write(try #require(PixelSurface(surface, conversion: table)))
            try canvas.draw { canvas.image(image, 0, 0, 32, 32) }
        }
        let pass = try #require(canvas.imageInputPass)
        #expect(pass.surfaceTextureCount == 2, "動画のプールのように巡ってくる面は、初めて見たときだけ作る")
        #expect(try texels(image, on: gpu) == expected(try #require(PixelSurface(first, conversion: table))))
        for _ in 0...ImageInputPass.surfaceTextureIdleSubmissions {
            try canvas.draw { canvas.background(.transparent) }
        }
        #expect(pass.surfaceTextureCount == 0, "書かなくなった面は、届けるものが無いフレームでも手放す")
        try gpu.settle()
    }

    @Test("CPU で読むと表を CPU で引いて写し、面を放す。編集も載る")
    func readingOnTheCPUMaterializes() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 32, height: 32)
        let table = TableMapping.scrambledTable
        let surface = try Self.surface(width: side, height: side) { x, y in (UInt8(x & 255), UInt8(y & 255), 77) }
        let frame = try #require(PixelSurface(surface, conversion: table))
        let image = try canvas.createImage(side, side)
        image.write(frame)
        image.set(5, 6, .linear(red: 0, green: 0, blue: 1))
        try canvas.draw { canvas.image(image, 0, 0, 32, 32) }
        let onGPU = try texels(image, on: gpu)
        #expect(onGPU[6 * side + 5] == SIMD4(0, 0, 1, 1), "編集が載っている")
        var reference = expected(frame)
        reference[6 * side + 5] = SIMD4(0, 0, 1, 1)
        #expect(onGPU == reference)
        #expect(image.workingPixels == reference)
        #expect(image.surfaceInput == nil, "CPU へ写したら面を持たない")
    }

    @Test("100 万画素に満たない絵へは、その場で CPU で引いて書き、面を持たない")
    func smallImagesConvertAtOnce() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 32, height: 32)
        let table = TableMapping.scrambledTable
        let surface = try Self.surface(width: 64, height: 48) { x, y in (UInt8(x * 4), UInt8(y * 5), 200) }
        let image = try canvas.createImage(64, 48)
        let frame = try #require(PixelSurface(surface, conversion: table))
        image.write(frame)
        #expect(image.surfaceInput == nil)
        #expect(image.workingPixels == expected(frame))
    }

    @Test("GPU の準備が使えなくても、表を CPU で引いて同じ値を届ける")
    func preparationFallback() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 32, height: 32)
        canvas.failImageInputForTesting = true
        let table = TableMapping.scrambledTable
        let surface = try Self.surface(width: side, height: side) { x, y in (UInt8(x & 255), UInt8(y & 255), 3) }
        let frame = try #require(PixelSurface(surface, conversion: table))
        let image = try canvas.createImage(side, side)
        image.write(frame)
        try canvas.draw { canvas.image(image, 0, 0, 32, 32) }
        #expect(try texels(image, on: gpu) == expected(frame))
    }

    @Test("大きさの違う面は書かない")
    func sizeMismatchIsIgnored() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 32, height: 32)
        let table = TableMapping.identityTable
        let image = try canvas.createImage(side, side)
        let generation = image.uploadGeneration
        image.write(try #require(PixelSurface(try Self.surface(width: 8, height: 8), conversion: table)))
        #expect(image.surfaceInput == nil)
        #expect(image.uploadGeneration == generation)
    }
}
