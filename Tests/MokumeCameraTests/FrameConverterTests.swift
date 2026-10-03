// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

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
struct FrameConverterTests {
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
}
