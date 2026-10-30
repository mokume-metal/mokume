// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import simd

/// **SVG の被覆を、CoreSVG が CPU で描いた絵から取る参照** (#3207 の提案 2・#3494)。
///
/// `CoverageReference` は図形 (rect・円) を解析的に数える。SVG は塗り規則 (`evenodd`)・群の `opacity`・
/// 入れ子の変換が絡み、解析的に書くと mokume の読み解きの写しになるので、**外の描画器が描いた絵**を参照にする。
/// 使うのは公開の `NSImage(contentsOf:)` だけで、SVG の中身は `_NSSVGImageRep` (CoreSVG) が読む。
/// ビットマップの CGContext へ描くので GPU は要らない。
///
/// ## 何を比べ、何を比べないか
///
/// - **比べる**: 50% の被覆で白黒にした形 (``halfTone(_:threshold:)``) と、線形の被覆で重みを付けた重心
///   (``centroid(_:width:)``)。CoreGraphics の AA は円で画素ごとに最大 0.064 外れ (#3217 の実測)、mokume の
///   許容 (曲線の縁 0.02) より粗いので、**中間値は比べない**
/// - **比べない**: CSS の優先順位 (`!important`・詳細度) を含む入力。CoreSVG はこれを誤る (#2348・#2334・#2410 の型)
///   ので参照にならない。生成しない (``CoverageTable/svgOutOfScope``)
///
/// ## 被覆の取り方
///
/// 透明な面へ描き、**アルファを被覆とする**。色空間 (sRGB・線形) に依らず、白黒の塗りでなくても取れる。
/// 画素 (x, y) は左上が原点で、mokume の `readPixels()` と同じ向きである。
///
/// ## 公開の口と版
///
/// `_NSSVGImageRep` が保証される API かは確かめていない (公開の保証は `NSImage` が SVG を読めることまで)。
/// 参照そのものの自己検査 (`CoreSVGReferenceTests`・GPU なし) が、下限の macOS (ADR-0009) と手元の版で
/// 同じ値を返すことを毎回確かめる。値が動けば、比べる検査より先にそちらが赤になる。
public nonisolated enum CoreSVGReference {
    /// 参照を作れなかった理由。
    public struct Failure: Error, CustomStringConvertible, Sendable, Equatable {
        public let description: String
    }

    /// 被覆 (アルファ・0〜1) の画素の並び (行ごと・上から)。
    public struct Raster: Sendable {
        public let width: Int
        public let height: Int
        public let coverage: [Double]

        public subscript(x: Int, y: Int) -> Double { coverage[y * width + x] }
    }

    /// SVG の文を `width` × `height` の面へ等倍で描き、被覆を返す。
    ///
    /// SVG の根の `width` / `height` は面と同じ大きさで書くこと (CoreSVG はその大きさで画を作る)。
    public static func render(svg: String, width: Int, height: Int) throws -> Raster {
        let url = TestScratch.path("mokume-coresvg", pathExtension: "svg")
        try svg.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let image = NSImage(contentsOf: url) else {
            throw Failure(description: "[svg-reference] CoreSVG が SVG を読めない (NSImage(contentsOf:) が nil)")
        }
        guard image.representations.contains(where: { String(describing: type(of: $0)).contains("SVG") }) else {
            throw Failure(description: "[svg-reference] SVG の表現 (_NSSVGImageRep) で読まれていない: "
                + "\(image.representations.map { String(describing: type(of: $0)) })")
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard
                let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            let graphics = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            image.draw(
                in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .sourceOver,
                fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        guard drawn else { throw Failure(description: "[svg-reference] ビットマップの文脈を作れない") }
        let coverage = (0..<(width * height)).map { Double(bytes[$0 * 4 + 3]) / 255 }
        return Raster(width: width, height: height, coverage: coverage)
    }

    /// 被覆が `threshold` 以上の画素を真にした白黒。縁の中間値は、ここで 0 / 1 に落ちる。
    public static func halfTone(_ coverage: [Double], threshold: Double = 0.5) -> [Bool] {
        coverage.map { $0 >= threshold }
    }

    /// 被覆 (線形の重み) で重みを付けた重心 (画素の座標・画素の中心を +0.5 とする)。被覆の総和が 0 なら `nil`。
    public static func centroid(_ coverage: [Double], width: Int) -> SIMD2<Double>? {
        var total = 0.0
        var sum = SIMD2<Double>(0, 0)
        for (index, weight) in coverage.enumerated() where weight > 0 {
            total += weight
            sum += SIMD2(Double(index % width) + 0.5, Double(index / width) + 0.5) * weight
        }
        return total > 0 ? sum / total : nil
    }

    /// 2 つの白黒の、一致しない画素の数。
    public static func mismatches(_ a: [Bool], _ b: [Bool]) -> Int {
        precondition(a.count == b.count, "白黒の大きさが違う")
        return zip(a, b).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
    }

    /// 白黒の形の縁の画素の数 (真で、4 近傍に偽か面の外を持つ画素)。一致しない画素の許容を、縁の長さで割るための物差し。
    public static func edgePixels(_ shape: [Bool], width: Int) -> Int {
        let height = shape.count / width
        func filled(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            return shape[y * width + x]
        }
        var count = 0
        for y in 0..<height {
            for x in 0..<width where shape[y * width + x] {
                // 4 近傍のどれかが偽 (面の外も偽) なら縁
                if !filled(x - 1, y) || !filled(x + 1, y) || !filled(x, y - 1) || !filled(x, y + 1) {
                    count += 1
                }
            }
        }
        return count
    }
}
