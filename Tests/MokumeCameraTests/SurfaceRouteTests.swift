// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreVideo
import Foundation
import Metal
import Testing

@testable import MokumeCamera
@testable import MokumeCore

/// 検証した色の意味ごとの付帯 (#2962)。
nonisolated enum ColorAttachments {
    /// 復号器が色を推したコマ (ファイルが色を名乗らない HD・4K の動画。1080p と 4K の H.264 で実際に付く組 —
    /// Rec.709 の原色・伝達関数・行列と、付帯から作った ICC の色空間 — を写した)。
    static var guessed: [CFString: Any] {
        var values = rec709
        values["ColorInfoGuessedBy" as CFString] = "VideoToolbox"
        return values
    }
    /// 復号器が色を推した SD のコマ (320×240 の H.264 で実際に付く組: SMPTE-C の原色と 601 の行列)。
    static var guessedSD: [CFString: Any] {
        var values = rec709Values(primaries: kCVImageBufferColorPrimaries_SMPTE_C, matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        values["ColorInfoGuessedBy" as CFString] = "VideoToolbox"
        return values
    }
    /// Rec.709 を名乗るコマ (実際の動画のコマと同じく、付帯から作った ICC の色空間も付く)。
    static var rec709: [CFString: Any] {
        rec709Values(primaries: kCVImageBufferColorPrimaries_ITU_R_709_2, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    }
    static var sRGB: [CFString: Any] { [kCVImageBufferCGColorSpaceKey: CGColorSpace(name: CGColorSpace.sRGB)!] }
    static var displayP3: [CFString: Any] { [kCVImageBufferCGColorSpaceKey: CGColorSpace(name: CGColorSpace.displayP3)!] }
    static var none: [CFString: Any] { [:] }

    private static func rec709Values(primaries: CFString, matrix: CFString) -> [CFString: Any] {
        var values: [CFString: Any] = [
            kCVImageBufferColorPrimariesKey: primaries,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: matrix,
        ]
        if let space = CVImageBufferCreateColorSpaceFromAttachments(values as CFDictionary)?.takeRetainedValue() {
            values[kCVImageBufferCGColorSpaceKey] = space
        }
        return values
    }

    /// 面の裏付きの BGRA の `CVPixelBuffer` を作り、付帯を付けて `paint(x, y)` の (赤, 緑, 青) で塗る。
    static func buffer(
        width: Int, height: Int, attachments: [CFString: Any], opaque: Bool = true, surface: Bool = true,
        pixelFormat: OSType = kCVPixelFormatType_32BGRA,
        paint: (Int, Int) -> (UInt8, UInt8, UInt8) = { _, _ in (0, 0, 0) }
    ) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let properties: [CFString: Any] = surface ? [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] : [:]
        #expect(CVPixelBufferCreate(nil, width, height, pixelFormat, properties as CFDictionary, &made) == kCVReturnSuccess)
        let buffer = try #require(made)
        CVBufferSetAttachments(buffer, attachments as CFDictionary, .shouldPropagate)
        if opaque { CVBufferSetAttachment(buffer, "AlphaChannelIsOpaque" as CFString, kCFBooleanTrue, .shouldPropagate) }
        guard pixelFormat == kCVPixelFormatType_32BGRA else { return buffer }
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes)
            for x in 0..<width {
                let (r, g, b) = paint(x, y)
                row[x * 4] = b
                row[x * 4 + 1] = g
                row[x * 4 + 2] = r
                row[x * 4 + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}

/// 届いたコマを面のまま渡すかの判定と、色の表の持ち回し (#2962)。GPU は要らない。
@Suite("面に乗せるかの判定")
struct SurfaceRouteTests {
    private func route(
        _ buffer: CVPixelBuffer, alpha: FrameConverter.Alpha = .straight, reshaped: Bool = false, builds: Bool = true,
        tables: SurfaceTables
    ) -> SurfaceRoute.Refusal? {
        switch SurfaceRoute.surface(for: buffer, alpha: alpha, reshaped: reshaped, builds: builds, tables: tables) {
        case .success: nil
        case .failure(let refusal): refusal
        }
    }

    @Test("面・BGRA・不透明・検証した色・形を変えない、が揃ったコマだけを面で渡し、理由を名乗る")
    func refusalsAreNamed() throws {
        let tables = SurfaceTables()
        let fine = try ColorAttachments.buffer(width: 8, height: 8, attachments: ColorAttachments.rec709)
        #expect(route(fine, builds: false, tables: tables) == .tablePending, "表が無く、作らない")
        #expect(tables.built.load(ordering: .relaxed) == 0)
        #expect(route(fine, tables: tables) == nil)
        #expect(route(fine, tables: tables) == nil)
        #expect(tables.built.load(ordering: .relaxed) == 1, "同じ色の意味の表は作り直さない")
        #expect(route(fine, builds: false, tables: tables) == nil, "出来ている表は main でも使う")

        let heap = try ColorAttachments.buffer(width: 8, height: 8, attachments: ColorAttachments.rec709, surface: false)
        #expect(route(heap, tables: tables) == .noSurface)
        let planar = try ColorAttachments.buffer(
            width: 8, height: 8, attachments: ColorAttachments.rec709,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(route(planar, tables: tables) == .notBGRA)
        let maybeClear = try ColorAttachments.buffer(width: 8, height: 8, attachments: ColorAttachments.rec709, opaque: false)
        #expect(route(maybeClear, tables: tables) == .notOpaque, "動画は不透明を名乗るコマだけ")
        #expect(route(maybeClear, alpha: .opaque, tables: tables) == nil, "カメラは不透明として扱う")
        var gamma = ColorAttachments.rec709
        gamma[kCVImageBufferGammaLevelKey] = 2.2
        #expect(route(try ColorAttachments.buffer(width: 8, height: 8, attachments: gamma), tables: tables) == .unverifiedColor)
        let pq: [CFString: Any] = [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_2020,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
        ]
        #expect(route(try ColorAttachments.buffer(width: 8, height: 8, attachments: pq), tables: tables) == .unverifiedColor)
        #expect(route(fine, reshaped: true, tables: tables) == .reshaped)
        // SD の推した色 (SMPTE-C → Display P3) は、出力の赤が入力の青で変わるので表に詰められない。作れなかった
        // ことを覚え、今の CPU の道で変換する (絵は変わらない)
        let sd = try ColorAttachments.buffer(width: 8, height: 8, attachments: ColorAttachments.guessedSD)
        #expect(ColorMeaning(sd)?.kind == .guessed)
        let built = tables.built.load(ordering: .relaxed)
        #expect(route(sd, tables: tables) == .tableRejected)
        #expect(route(sd, tables: tables) == .tableRejected)
        #expect(tables.built.load(ordering: .relaxed) == built + 1, "作れなかった表は作り直さない")
    }

    @Test("検証した 5 つの色の意味を、付帯から見分ける")
    func meaningsAreRecognised() throws {
        let cases: [([CFString: Any], ColorMeaning.Kind)] = [
            (ColorAttachments.guessed, .guessed), (ColorAttachments.rec709, .rec709), (ColorAttachments.sRGB, .sRGB),
            (ColorAttachments.displayP3, .displayP3), (ColorAttachments.none, .none),
        ]
        for (attachments, kind) in cases {
            let buffer = try ColorAttachments.buffer(width: 4, height: 4, attachments: attachments)
            #expect(ColorMeaning(buffer)?.kind == kind, "\(kind)")
        }
    }
}

/// 面の道と今の CPU の道で、絵が 1 bit も変わらない (#2962 の完了条件 2)。
@Suite(
    "面の道と CPU の道の一致",
    .enabled(if: RenderDevice.isAvailable, "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする"),
    .serialized)
@MainActor struct SurfacePathExactnessTests {
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

    @Test(
        "検証した色の意味ごとに、全 16,777,216 色を面の道で書いた絵が、本物の変換器で書いた絵と半精度の bit で一致する",
        arguments: ["guessed", "rec709", "sRGB", "displayP3", "none"])
    func everyColorMatchesTheConverter(meaning: String) throws {
        let attachments: [CFString: Any] =
            switch meaning {
            case "guessed": ColorAttachments.guessed
            case "rec709": ColorAttachments.rec709
            case "sRGB": ColorAttachments.sRGB
            case "displayP3": ColorAttachments.displayP3
            default: ColorAttachments.none
            }
        let gpu = try RenderDevice()
        let canvas = try Canvas(target: try RenderTarget(gpu: gpu, width: 32, height: 32), gpu: gpu)
        let side = 1024
        let tables = SurfaceTables()
        let converter = FrameConverter(width: side, height: side, alpha: .straight)
        let viaSurface = try canvas.createImage(side, side)
        let viaConverter = try canvas.createImage(side, side)
        var mismatched = 0
        for part in 0..<16 {
            let buffer = try ColorAttachments.buffer(width: side, height: side, attachments: attachments) { x, y in
                let color = part << 20 | y << 10 | x
                return (UInt8(color & 255), UInt8(color >> 8 & 255), UInt8(color >> 16 & 255))
            }
            let surface = try SurfaceRoute.surface(
                for: buffer, alpha: .straight, reshaped: false, builds: true, tables: tables
            ).get()
            viaSurface.write(surface)
            viaConverter.write(try converter.convert(buffer))
            #expect(viaSurface.surfaceInput != nil)
            try canvas.draw {
                canvas.image(viaSurface, 0, 0, 16, 16)
                canvas.image(viaConverter, 16, 0, 16, 16)
            }
            if try texels(viaSurface, on: gpu) != texels(viaConverter, on: gpu) { mismatched += 1 }
        }
        #expect(mismatched == 0, "\(meaning): \(mismatched) / 16 枚で違う")
        #expect(tables.built.load(ordering: .relaxed) == 1)
    }
}
