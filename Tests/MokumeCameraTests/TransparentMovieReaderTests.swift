// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCamera
import MokumeCore

/// 透過の動画 (#2881)。動画は検査の中で ProRes 4444 で作る。
///
/// 読んだ絵は ``DisplayImage`` の約束どおり、乗算していないアルファのまま届く。
@Suite(
    "透過の動画のアルファ",
    .enabled(if: TestMovie.canWriteTransparent, "この機械には ProRes 4444 の符号化器が無い")
)
struct TransparentMovieReaderTests {
    /// 固定の時計 (30 fps) の `frame` 枚目 (0 始まり) の時刻。
    private func time(_ frame: Int) -> Double { Double(Float(Double(frame) / 30)) }

    /// 透明・半透明・不透明・薄い半透明の 4 つの帯を、枚ごとに 1 帯ずつずらす。
    /// 色はどれも同じ (乗算していない赤橙) で、アルファだけが違う。
    private nonisolated static let alphas: [UInt8] = [0, 128, 255, 64]

    private nonisolated static func pixel(_ index: Int, _ x: Int, _ y: Int) -> TestMovie.Straight {
        let alpha = alphas[(x / 2 + index) % alphas.count]
        // 透明な画素の色は意味を持たない。黒にしておく (書き出しも透明なところは黒になる)
        return alpha == 0 ? (0, 0, 0, 0) : (240, 150, 70, alpha)
    }

    @Test("アルファ 0 / 64 / 128 / 255 を保ち、半透明の色は暗くならない (複数のコマで)")
    func keepsAlphaAndStraightColour() async throws {
        let url = try await TestMovie.writeTransparent(frames: 3, pixel: Self.pixel)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try MovieReader(url: url, path: url.path)
        for frame in 0..<3 {
            let picture = try #require(try reader.picture(at: time(frame)), "\(frame) 枚目が届かない")
            for x in 0..<8 {
                let expected = Self.pixel(frame, x, 1)
                let actual = picture[x, 1]
                #expect(
                    abs(Int(actual.alpha) - Int(expected.alpha)) <= 1,
                    "\(frame) 枚目の x=\(x) の不透明度は \(expected.alpha) のはずが \(actual.alpha)")
                guard expected.alpha > 0 else { continue }
                // 符号化の色差と色空間の丸めは許す。半分に暗くなる (乗算が混ざる) ほどは許さない
                #expect(abs(Int(actual.red) - Int(expected.red)) <= 4, "\(frame) 枚目の x=\(x) の赤 \(actual.red)")
                #expect(abs(Int(actual.green) - Int(expected.green)) <= 4, "\(frame) 枚目の x=\(x) の緑 \(actual.green)")
                #expect(abs(Int(actual.blue) - Int(expected.blue)) <= 4, "\(frame) 枚目の x=\(x) の青 \(actual.blue)")
            }
        }
    }

    @Test("全面が不透明の透過形式の動画は、読んでも不透明のまま")
    func opaqueContentInAnAlphaFormatStaysOpaque() async throws {
        let url = try await TestMovie.writeTransparent(frames: 2) { _, _, _ in (10, 200, 90, 255) }
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try MovieReader(url: url, path: url.path)
        let picture = try #require(try reader.picture(at: 0))
        for x in 0..<picture.width {
            #expect(picture[x, 0].alpha == 255)
            #expect(abs(Int(picture[x, 0].green) - 200) <= 4)
        }
    }
}

/// アルファ付きの HEVC (Safari でも読める透過動画) は、乗算済みを名乗って届く。
@Suite(
    "アルファ付き HEVC のアルファ",
    .enabled(if: TestMovie.canWriteHEVCWithAlpha, "この機械にはアルファ付き HEVC の符号化器が無い")
)
struct PremultipliedMovieReaderTests {
    @Test("乗算済みで届く透過動画も、乗算を戻して、色を暗くせずアルファを保つ")
    func undoesPremultiplication() async throws {
        // 64x64 を 16 画素幅の帯 4 本に分ける: 透明・半透明・不透明・薄い半透明
        let url = try await TestMovie.writeTransparent(
            codec: .hevcWithAlpha, frames: 2, width: 64, height: 64
        ) { _, x, _ in
            switch x / 16 {
            case 0: (0, 0, 0, 0)
            case 1: (240, 150, 70, 128)
            case 2: (240, 150, 70, 255)
            default: (240, 150, 70, 96)
            }
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try MovieReader(url: url, path: url.path)
        let picture = try #require(try reader.picture(at: 0))
        for (band, alpha) in [(0, 0), (1, 128), (2, 255), (3, 96)] {
            let pixel = picture[band * 16 + 8, 32]
            #expect(abs(Int(pixel.alpha) - alpha) <= 3, "帯 \(band) の不透明度 \(pixel.alpha)")
            guard alpha > 0 else { continue }
            // 不可逆の符号化 (乗算済みの 8 bit) なので、色は大きめに許す。半分に暗くなる誤りは見逃さない
            #expect(abs(Int(pixel.red) - 240) <= 16, "帯 \(band) の赤 \(pixel.red)")
            #expect(abs(Int(pixel.green) - 150) <= 16, "帯 \(band) の緑 \(pixel.green)")
            #expect(abs(Int(pixel.blue) - 70) <= 16, "帯 \(band) の青 \(pixel.blue)")
        }
    }
}
