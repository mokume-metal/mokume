// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Accelerate
import CoreGraphics
import CoreVideo
import Testing

@testable import MokumeCamera
import MokumeCore

/// カメラの 1 枚を ``DisplayImage`` にする変換。GPU も機材も要らない。
///
/// ``DisplayImage`` の値は Display P3 の原色として読まれるので、カメラ (Rec.709 / sRGB) の
/// 絵は原色を移してから渡す (ADR-0011 の入口の表)。
@Suite("カメラの 1 枚の変換")
nonisolated struct FrameConverterTests {
    /// BGRA の器を作る。`colorSpace` を渡せば、その色空間を名乗らせる。
    private func buffer(
        width: Int, height: Int, colorSpace: CFString? = nil,
        pixel: (Int, Int) -> (blue: UInt8, green: UInt8, red: UInt8)
    ) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA, nil, &made)
        let buffer = try #require(made, "CVPixelBufferCreate: \(status)")
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let (blue, green, red) = pixel(x, y)
                let at = base.advanced(by: y * rowBytes + x * 4).assumingMemoryBound(to: UInt8.self)
                at[0] = blue
                at[1] = green
                at[2] = red
                at[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        if let colorSpace, let space = CGColorSpace(name: colorSpace) {
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        }
        return buffer
    }

    /// 不透明度を持つ BGRA の器。`pixel` は (赤, 緑, 青, 不透明度) で、バッファへそのまま書く。
    /// `mode` はバッファが名乗る不透明度の形式 (`kCVImageBufferAlphaChannelMode_*`)。
    private func alphaBuffer(
        width: Int, height: Int, mode: CFString?,
        pixel: (Int, Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)
    ) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &made)
        let buffer = try #require(made)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let value = pixel(x, y)
                let at = base.advanced(by: y * rowBytes + x * 4).assumingMemoryBound(to: UInt8.self)
                at[0] = value.blue
                at[1] = value.green
                at[2] = value.red
                at[3] = value.alpha
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(
            buffer, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.displayP3)!,
            .shouldPropagate)
        if let mode { CVBufferSetAttachment(buffer, kCVImageBufferAlphaChannelModeKey, mode, .shouldPropagate) }
        return buffer
    }

    private func rgba(_ picture: DisplayImage, _ x: Int, _ y: Int) -> [Int] {
        let at = (y * picture.width + x) * 4
        return picture.bytes[at..<at + 4].map(Int.init)
    }

    private func near(_ actual: [Int], _ expected: [Int], within tolerance: Int = 2) -> Bool {
        zip(actual, expected).allSatisfy { abs($0 - $1) <= tolerance }
    }

    @Test("行に詰め物のある BGRA から、詰め物の無い RGBA を作る")
    func dropsRowPaddingAndReordersChannels() throws {
        // 幅 5 の BGRA は 1 行 20 バイトだが、CoreVideo は行を揃えて詰め物を置く
        let source = try buffer(width: 5, height: 3, colorSpace: CGColorSpace.displayP3) { x, y in
            (blue: UInt8(10 * x), green: UInt8(20 * y), red: 200)
        }
        #expect(CVPixelBufferGetBytesPerRow(source) > 5 * 4, "詰め物が無いと検査にならない")
        let picture = try FrameConverter(width: 5, height: 3).convert(source)
        #expect(picture.width == 5)
        #expect(picture.height == 3)
        #expect(picture.bytes.count == 5 * 3 * 4)
        // 名乗りが Display P3 なので原色は動かない
        #expect(near(rgba(picture, 4, 2), [200, 40, 40, 255]))
        #expect(near(rgba(picture, 0, 0), [200, 0, 0, 255]))
    }

    @Test("名乗りの無い絵は sRGB とみなし、純色の赤を Display P3 の赤へ移す")
    func movesSRGBPrimariesIntoDisplayP3() throws {
        let source = try buffer(width: 2, height: 2) { _, _ in (blue: 0, green: 0, red: 255) }
        let picture = try FrameConverter(width: 2, height: 2).convert(source)
        // sRGB の (1, 0, 0) は Display P3 で (0.9175, 0.2003, 0.1386) — 8 bit で (234, 51, 35)
        #expect(near(rgba(picture, 1, 1), [234, 51, 35, 255]))
    }

    @Test("名乗った色空間に従う (sRGB と名乗れば移し、P3 と名乗れば動かさない)")
    func followsTheDeclaredColorSpace() throws {
        let green = { (_: Int, _: Int) in (blue: UInt8(0), green: UInt8(255), red: UInt8(0)) }
        let fromSRGB = try FrameConverter(width: 2, height: 2).convert(
            try buffer(width: 2, height: 2, colorSpace: CGColorSpace.sRGB, pixel: green))
        let fromP3 = try FrameConverter(width: 2, height: 2).convert(
            try buffer(width: 2, height: 2, colorSpace: CGColorSpace.displayP3, pixel: green))
        // sRGB の (0, 1, 0) は Display P3 で (0.4584, 0.9853, 0.2983) — 8 bit で (117, 251, 76)
        #expect(near(rgba(fromSRGB, 0, 0), [117, 251, 76, 255]))
        #expect(near(rgba(fromP3, 0, 0), [0, 255, 0, 255]))
    }

    @Test("原色と伝達関数の付属情報で名乗る BGRA も、Display P3 へ移す")
    func followsPrimariesAttachments() throws {
        // カメラが出す BGRA は CGColorSpace ではなく、原色・伝達関数の付属情報で名乗る
        let source = try buffer(width: 2, height: 2) { _, _ in (blue: 0, green: 0, red: 255) }
        CVBufferSetAttachment(
            source, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate)
        CVBufferSetAttachment(
            source, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate)
        let picture = try FrameConverter(width: 2, height: 2).convert(source)
        #expect(near(rgba(picture, 0, 0), [234, 51, 35, 255]))
    }

    /// 420v を vImage で直に変換すると、色差が中立の灰色が緑になった (#1977 の実機で踏んだ)。
    /// 黙って違う色にせず、断る。
    @Test("BGRA 以外の形式は、黙って違う色にせず断る")
    func refusesOtherFormats() throws {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, 4, 4, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &made)
        let source = try #require(made)
        // 実機と同じ付属情報を付ける。無いと変換器が作れずに断るので、守りの有無を見分けられない
        CVBufferSetAttachment(
            source, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate)
        CVBufferSetAttachment(
            source, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate)
        CVBufferSetAttachment(
            source, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate)
        #expect(throws: FrameConverter.Failure.unsupportedFormat(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)) {
            try FrameConverter(width: 4, height: 4).convert(source)
        }
    }

    @Test("カメラには 32BGRA と頼んだ大きさを頼む")
    func asksTheCameraForBGRA() {
        let settings = CameraSource.videoSettings(width: 640, height: 480)
        #expect(settings[kCVPixelBufferPixelFormatTypeKey as String] as? OSType == kCVPixelFormatType_32BGRA)
        #expect(settings[kCVPixelBufferWidthKey as String] as? Int == 640)
        #expect(settings[kCVPixelBufferHeightKey as String] as? Int == 480)
    }

    @Test("縦横比が違えば、真ん中を切り取ってから縮める (ゆがめない)")
    func cropsTheCentreBeforeScaling() throws {
        // 8x4 の両端 2 列ずつが青、真ん中 4 列が赤。4x4 の真ん中だけを 2x2 へ縮める
        let source = try buffer(width: 8, height: 4, colorSpace: CGColorSpace.displayP3) { x, _ in
            (2..<6).contains(x) ? (blue: 0, green: 0, red: 255) : (blue: 255, green: 0, red: 0)
        }
        let picture = try FrameConverter(width: 2, height: 2).convert(source)
        for y in 0..<2 {
            for x in 0..<2 {
                #expect(near(rgba(picture, x, y), [255, 0, 0, 255]), "(\(x), \(y)) に端の青が混ざった")
            }
        }
    }

    // MARK: - 縮めるときは光の量で平均する (#3682)

    /// 8 bit のエンコード値を、sRGB の曲線で光の量 (0–1) へ戻す。実装の表を使わず式で出す。
    private func light(_ encoded: Int) -> Double {
        let value = Double(encoded) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// 白と黒が 1 画素ずつ交互に並ぶ縦縞。
    private func stripes(_ x: Int, _ alpha: UInt8) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        x.isMultiple(of: 2) ? (255, 255, 255, alpha) : (0, 0, 0, alpha)
    }

    /// 縮めた行の、光の量の平均。
    ///
    /// **画素ごとではなく行の平均で見る。** 縮める窓 (Lanczos) は縞の周期で揺れ (1 画素ずつ ±0.07 ほど)、
    /// その揺れは平均の取り方と関係が無い。エンコードした値のまま平均すると、行の平均は 0.23 になる
    /// (縞が 128 前後に並ぶ)。光の量で平均すれば 0.5 になる。
    private func rowLight(_ picture: DisplayImage, _ y: Int, channel: Int = 0) -> Double {
        (0..<picture.width).map { light(rgba(picture, $0, y)[channel]) }.reduce(0, +) / Double(picture.width)
    }

    @Test("縮める道: 白黒の縞を半分に縮めると、光の量で平均した値になる", arguments: [
        FrameConverter.Alpha.opaque, FrameConverter.Alpha.straight,
    ])
    func scalingAveragesLinearLight(alpha: FrameConverter.Alpha) throws {
        let source = try alphaBuffer(
            width: 8, height: 8, mode: kCVImageBufferAlphaChannelMode_StraightAlpha
        ) { x, _ in stripes(x, 255) }
        let picture = try FrameConverter(width: 4, height: 4, alpha: alpha).convert(source)
        for y in 0..<4 {
            let mean = rowLight(picture, y)
            #expect(abs(mean - 0.5) < 0.04, "y=\(y): 光の量の平均 \(mean)")
            for x in 0..<4 {
                let pixel = rgba(picture, x, y)
                #expect(pixel[0] == pixel[1] && pixel[1] == pixel[2] && pixel[3] == 255, "(\(x), \(y)): \(pixel)")
            }
        }
    }

    @Test("縮める道: 半透明の縞も、乗算を戻した色が光の量で平均した値になる")
    func scalingAveragesLinearLightThroughAlpha() throws {
        let source = try alphaBuffer(
            width: 8, height: 8, mode: kCVImageBufferAlphaChannelMode_StraightAlpha
        ) { x, _ in stripes(x, 128) }
        let picture = try FrameConverter(width: 4, height: 4, alpha: .straight).convert(source)
        for y in 0..<4 {
            let mean = rowLight(picture, y)
            #expect(abs(mean - 0.5) < 0.04, "y=\(y): 光の量の平均 \(mean)")
            for x in 0..<4 { #expect(abs(rgba(picture, x, y)[3] - 128) <= 1, "(\(x), \(y))") }
        }
    }

    /// 乗算済みを名乗る元 (アルファ付きの HEVC) は、8 bit で乗算を戻してから線形へ移し、乗算して縮める。
    /// 戻し忘れれば色が半分の暗さになり、二重に掛ければもっと暗くなる。
    @Test("縮める道: 乗算済みを名乗る半透明の縞も、光の量で平均した値になる")
    func scalingPremultipliedSourcesAveragesLinearLight() throws {
        // 乗算していない白 (255) を不透明度 128 で乗算すると 128
        let source = try alphaBuffer(
            width: 8, height: 8, mode: kCVImageBufferAlphaChannelMode_PremultipliedAlpha
        ) { x, _ in x.isMultiple(of: 2) ? (128, 128, 128, 128) : (0, 0, 0, 128) }
        let picture = try FrameConverter(width: 4, height: 4, alpha: .straight).convert(source)
        for y in 0..<4 {
            let mean = rowLight(picture, y)
            #expect(abs(mean - 0.5) < 0.04, "y=\(y): 光の量の平均 \(mean)")
            for x in 0..<4 { #expect(abs(rgba(picture, x, y)[3] - 128) <= 1, "(\(x), \(y))") }
        }
    }

    @Test("縮める道でも、名乗りの無い絵の原色を Display P3 へ移す")
    func scalingMovesSRGBPrimariesIntoDisplayP3() throws {
        let source = try buffer(width: 4, height: 4) { _, _ in (blue: 0, green: 0, red: 255) }
        let picture = try FrameConverter(width: 2, height: 2).convert(source)
        // sRGB の (1, 0, 0) は Display P3 で 8 bit の (234, 51, 35)
        #expect(near(rgba(picture, 1, 1), [234, 51, 35, 255]), "\(rgba(picture, 1, 1))")
    }

    // MARK: - 不透明度 (#2881)

    /// 左から 透明 / 半透明 / 不透明 の 3 画素 (乗算していない赤橙)。
    private func strip(_ x: Int, _ y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        switch x {
        case 0: (0, 0, 0, 0)
        case 1: (240, 150, 70, 128)
        default: (240, 150, 70, 255)
        }
    }

    @Test("動画 (.straight): 乗算していない不透明度を保ち、半透明の色を暗くしない")
    func straightKeepsAlphaAndColour() throws {
        let source = try alphaBuffer(
            width: 3, height: 2, mode: kCVImageBufferAlphaChannelMode_StraightAlpha, pixel: strip)
        let picture = try FrameConverter(width: 3, height: 2, alpha: .straight).convert(source)
        #expect(rgba(picture, 0, 0)[3] == 0)
        #expect(near(rgba(picture, 1, 1), [240, 150, 70, 128]))
        #expect(near(rgba(picture, 2, 0), [240, 150, 70, 255]))
    }

    @Test("動画 (.straight): 乗算済みを名乗る元は、乗算を戻して運ぶ")
    func straightUndoesPremultipliedSources() throws {
        // 乗算済みの (120, 75, 35, 128) は、乗算していない (240, 150, 70, 128)
        let source = try alphaBuffer(
            width: 3, height: 2, mode: kCVImageBufferAlphaChannelMode_PremultipliedAlpha
        ) { x, _ in
            switch x {
            case 0: (0, 0, 0, 0)
            case 1: (120, 75, 35, 128)
            default: (240, 150, 70, 255)
            }
        }
        let picture = try FrameConverter(width: 3, height: 2, alpha: .straight).convert(source)
        #expect(rgba(picture, 0, 0)[3] == 0)
        #expect(near(rgba(picture, 1, 0), [240, 150, 70, 128], within: 3), "\(rgba(picture, 1, 0))")
        #expect(near(rgba(picture, 2, 0), [240, 150, 70, 255]))
    }

    @Test("カメラ (.opaque、既定): 元の不透明度によらず、すべて 255 のまま")
    func opaqueIgnoresSourceAlpha() throws {
        let source = try alphaBuffer(
            width: 3, height: 2, mode: kCVImageBufferAlphaChannelMode_StraightAlpha, pixel: strip)
        for converter in [FrameConverter(width: 3, height: 2), FrameConverter(width: 3, height: 2, alpha: .opaque)] {
            let picture = try converter.convert(source)
            for x in 0..<3 { #expect(rgba(picture, x, 0)[3] == 255, "x=\(x)") }
            // 元の不透明度を読まないので、半透明・透明だった画素の色も暗くならない
            #expect(near(rgba(picture, 1, 0), [240, 150, 70, 255]))
            #expect(near(rgba(picture, 0, 0), [0, 0, 0, 255]))
        }
    }

    @Test("不透明な絵は、.straight でも .opaque と 1 バイトも変わらない (縮める道も)")
    func opaqueSourcesAreIdenticalInBothModes() throws {
        let source = try buffer(width: 8, height: 4, colorSpace: CGColorSpace.sRGB) { x, y in
            (blue: UInt8(30 * x), green: UInt8(60 * y), red: UInt8(255 - 20 * x))
        }
        for (width, height) in [(8, 4), (4, 4), (3, 2)] {
            let opaque = try FrameConverter(width: width, height: height, alpha: .opaque).convert(source)
            let straight = try FrameConverter(width: width, height: height, alpha: .straight).convert(source)
            #expect(opaque == straight, "\(width)x\(height)")
        }
    }

    @Test("縮める道: 透明な画素の色が、不透明な画素の縁へにじまない")
    func scalingDoesNotBleedTransparentColour() throws {
        // 左の 1 列は透明な青、残りは不透明な赤。4x4 を 3x3 へ縮めると、左端は両方を混ぜる
        let source = try alphaBuffer(
            width: 4, height: 4, mode: kCVImageBufferAlphaChannelMode_StraightAlpha
        ) { x, _ in x == 0 ? (0, 0, 255, 0) : (255, 0, 0, 255) }
        let picture = try FrameConverter(width: 3, height: 3, alpha: .straight).convert(source)
        for y in 0..<3 {
            for x in 0..<3 {
                let pixel = rgba(picture, x, y)
                // 見える画素 (不透明度がある) の青は、混ざった分だけ増えてはいけない
                if pixel[3] > 16 { #expect(pixel[2] <= 8, "(\(x), \(y)) に透明な青がにじんだ: \(pixel)") }
            }
        }
        // 右の画素は不透明な赤のまま
        #expect(near(rgba(picture, 2, 1), [255, 0, 0, 255], within: 4))
    }

    // MARK: - 確保 (#3252)

    /// 場所によって色が変わる、不透明度つきの BGRA。大きさが違っても同じ式で作る。
    private func patterned(width: Int, height: Int) throws -> CVPixelBuffer {
        try alphaBuffer(
            width: width, height: height, mode: kCVImageBufferAlphaChannelMode_StraightAlpha
        ) { x, y in
            (
                red: UInt8((x * 37 + y * 11) % 256), green: UInt8((x * 5 + y * 53) % 256),
                blue: UInt8((x * 91 + y * 7) % 256), alpha: UInt8(40 + (x * 13 + y * 29) % 216)
            )
        }
    }

    @Test("大きさの違う元を同じ大きさで続けて呼んでも、一時の器を取り直さない")
    func keepsTheResizeBufferForTheSameSize() throws {
        let converter = FrameConverter(width: 2, height: 2)
        #expect(converter.resizedBufferAddress == nil, "大きさが同じ経路は器を使わない")
        #expect(converter.scaledBufferAddress == nil)
        let source = try patterned(width: 8, height: 4)
        _ = try converter.convert(source)
        let first = try #require(converter.resizedBufferAddress)
        let firstScaled = try #require(converter.scaledBufferAddress)
        for _ in 0..<3 { _ = try converter.convert(source) }
        #expect(converter.resizedBufferAddress == first)
        #expect(converter.scaledBufferAddress == firstScaled)
        // 小さい元でも、足りているので取り直さない
        _ = try converter.convert(try patterned(width: 4, height: 4))
        #expect(converter.resizedBufferAddress == first)
        #expect(converter.scaledBufferAddress == firstScaled)
    }

    @Test("頼んだ大きさと同じ元は、一時の器を使わない")
    func exactSizeSourcesNeedNoResizeBuffer() throws {
        let converter = FrameConverter(width: 8, height: 4)
        _ = try converter.convert(try patterned(width: 8, height: 4))
        #expect(converter.resizedBufferAddress == nil)
    }

    /// 持ち回す器の前の中身が、次の枚へ漏れない。大きい元 → 小さい元 → 大きい元 → 同じ大きさ、
    /// の順に 1 つの変換器へ渡し、毎回まっさらな変換器と 1 バイトも変わらないことを見る。
    @Test("大きさ違いを続けて呼んでも、まっさらな変換器と 1 バイトも変わらない", arguments: [
        FrameConverter.Alpha.opaque, FrameConverter.Alpha.straight,
    ])
    func reusedConverterMatchesAFreshOne(alpha: FrameConverter.Alpha) throws {
        let reused = FrameConverter(width: 4, height: 4, alpha: alpha)
        let sizes = [(8, 4), (16, 9), (6, 6), (4, 4), (8, 4), (5, 11), (16, 9), (4, 4)]
        for (width, height) in sizes {
            let source = try patterned(width: width, height: height)
            let expected = try FrameConverter(width: 4, height: 4, alpha: alpha).convert(source)
            let actual = try reused.convert(source)
            #expect(actual == expected, "\(width)x\(height) \(alpha)")
            #expect(actual.bytes.count == 4 * 4 * 4)
        }
    }

    /// 出力の配列は 0 埋めの確保を挟まない。**全部のバイトを書き切っていること**を、確保の前に
    /// ごみ (0xCD) を詰めて捨てた直後の確保で見る (書き残しがあればごみが残る)。
    @Test("出力の配列は、未初期化の確保でも全部のバイトを書き切る", arguments: [
        FrameConverter.Alpha.opaque, FrameConverter.Alpha.straight,
    ])
    func writesEveryByteOfTheOutput(alpha: FrameConverter.Alpha) throws {
        let source = try alphaBuffer(
            width: 32, height: 32, mode: kCVImageBufferAlphaChannelMode_StraightAlpha
        ) { _, _ in (red: 10, green: 20, blue: 30, alpha: 255) }
        for (width, height) in [(32, 32), (16, 16), (24, 16)] {
            let converter = FrameConverter(width: width, height: height, alpha: alpha)
            for _ in 0..<8 {
                // 同じ大きさの配列にごみを詰めて、すぐ手放す (malloc の空き札に残る)
                for _ in 0..<16 { _ = [UInt8](repeating: 0xCD, count: width * height * 4) }
                let picture = try converter.convert(source)
                #expect(!picture.bytes.contains(0xCD), "\(width)x\(height) \(alpha)")
            }
        }
    }

    @Test("vImage が失敗したら、書けたことにせず変換の失敗として断る")
    func aFailingFillIsRefused() {
        #expect(throws: FrameConverter.Failure.conversion(-21772)) {
            try FrameConverter.picture(width: 4, height: 4, alpha: .opaque) { _ in -21772 }
        }
        // 失敗した後も次の呼び出しは成り立つ
        let ok = try? FrameConverter.picture(width: 2, height: 2, alpha: .straight) { destination in
            memset(destination.data, 7, 2 * 2 * 4)
            return vImage_Error(kvImageNoError)
        }
        #expect(ok?.bytes == [UInt8](repeating: 7, count: 16))
    }
}
