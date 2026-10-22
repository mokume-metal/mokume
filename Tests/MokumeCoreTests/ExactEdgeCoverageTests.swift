// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Testing
import simd

@testable import MokumeCore

/// **縁 1 本の被覆は、斜めの縁でも画素の面積に一致する** ([#2991])。GPU を要する。
///
/// 縁の式は、縁から法線の向きに幅 1 の線形の渡しだった。画素の和が面積に一致するのは縁が画素の軸に
/// 沿うときだけで、45° の縁では置く位置で光の量が振れた (既定の太さ 1 の線で 0.92〜1.12・太さ 0.3 の
/// 輪郭で 0.80〜1.17)。縁 1 本の値を、半平面と画素の軸に沿った正方形の重なりの面積に替え、細い枝の
/// 境目を行ノルムから**画素の法線向きの幅** (画素の正方形を形の軸へ射影した幅・行の絶対値の和) へ
/// 移した (`Shapes.metal` の `mokume_halfPlaneCoverage`・`mokume_reachPerPixel`)。
///
/// ## 見るもの
///
/// - **光の量**: 回した輪郭と線の、描く面の線形の値の総和を面積と比べる。y を 0〜15/16 の 16 通りに
///   ずらして置き、どれも 1 ± 0.03 に入る
/// - **境目の両側**: 細い枝 (両縁を重なりの面積で数える) と縁 1 本の式の境目をまたぐ 2 つの太さの、
///   光の量の差が同じ置き方で 0.01 以下
/// - **縁の画素ごと**: 回した太い塗りの縁を、厳密な面積 (標本で数える) と画素ごとに比べる
/// - **軸に沿う形は 1 ビットも動かない**: 0°・90°・180°・270°・縦横で違う倍率の `rect`・線を、半端な
///   位置に置いた絵の指紋が、直す前と同じ
///
/// [#2991]: https://github.com/mokume-metal/mokume/issues/2991
@Suite(
    "斜めの縁の被覆は画素の面積に一致する",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ExactEdgeCoverageTests {
    /// 出す面の大きさ (正方形)。
    static let size = 128

    /// y のずらし。0〜15/16 の 16 通り。
    static let offsets: [Float] = (0..<16).map { Float($0) / 16 }

    private static func makeCanvas() throws -> Canvas {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: size, height: size)
        return try Canvas(output: output, gpu: gpu, pixelDensity: 1, upscale: .spatial)
    }

    /// 白で黒い面へ描いて、描く面の線形の値 (赤) を返す。
    private static func light(_ body: (Canvas) -> Void) throws -> PixelBuffer {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(0)
            body(canvas)
        }
        return try canvas.target.readPixels()
    }

    private static func total(_ pixels: PixelBuffer) -> Double {
        var sum = 0.0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width { sum += Double(pixels[x, y].red) }
        }
        return sum
    }

    // MARK: - 光の量

    /// 角度ごとの、(角度の名・回す角)。
    static let angles: [(name: String, radians: Float)] = [
        ("45°", Float.pi / 4), ("30°", Float.pi / 6),
    ]

    @Test(
        "回した rect の輪郭 (noFill) の光の量は、太さによらず、置く位置を 16 通りにずらしても面積の 1 ± 0.03",
        arguments: [Float(0.3), 0.5, 1, 1.5], [0, 1])
    func rotatedOutlineKeepsItsLight(_ weight: Float, _ angleIndex: Int) throws {
        let angle = Self.angles[angleIndex]
        // 20 × 20 の輪郭の帯の面積は (20 + w)² − (20 − w)² = 80 w
        let expected = Double(80 * weight)
        var broken: [String] = []
        for offset in Self.offsets {
            let pixels = try Self.light { canvas in
                canvas.noFill()
                canvas.stroke(255)
                canvas.strokeWeight(weight)
                canvas.translate(64, 64 + offset)
                canvas.rotate(angle.radians)
                canvas.rect(-10, -10, 20, 20)
            }
            let ratio = Self.total(pixels) / expected
            if abs(ratio - 1) > 0.03 { broken.append("ずらし \(offset): \(ratio)") }
        }
        #expect(broken.isEmpty, "\(angle.name)・太さ \(weight): \(broken.joined(separator: " / "))")
    }

    @Test(
        "回した四角い端の線の光の量は、細い枝の境目の両側の太さでも、16 通りの置き方で面積の 1 ± 0.03",
        arguments: [Float(0.5), 0.99, 0.995, 1, 1.5], [0, 1])
    func rotatedLineKeepsItsLight(_ weight: Float, _ angleIndex: Int) throws {
        let angle = Self.angles[angleIndex]
        let expected = Double(40 * weight)
        var broken: [String] = []
        for offset in Self.offsets {
            let pixels = try Self.light { canvas in
                canvas.stroke(255)
                canvas.strokeWeight(weight)
                canvas.strokeCap(.square)
                canvas.translate(64, 64 + offset)
                canvas.rotate(angle.radians)
                canvas.line(-20, 0, 20, 0)
            }
            let ratio = Self.total(pixels) / expected
            if abs(ratio - 1) > 0.03 { broken.append("ずらし \(offset): \(ratio)") }
        }
        #expect(broken.isEmpty, "\(angle.name)・太さ \(weight): \(broken.joined(separator: " / "))")
    }

    // MARK: - 境目の両側

    /// (長さは 100 にして、端の角 (角の外の距離場は縁 1 本ではなく角までの距離で、面積の約束の外・
    /// ADR-0039 決定 1) の寄与を相対的に小さくし、辺だけを見る。)
    ///
    /// 細い枝と縁 1 本の式の境目 (描く画素の法線向きの幅 = 45° で √2 ÷ (1 + 2/256) ≈ 1.403) をまたぐ
    /// 2 つの太さで、光の量の差が同じ置き方で 0.01 以下。**太さ 0.99・0.995 は、以前の境目 (行ノルム)
    /// の両側** で、いまはどちらも細い枝に入る。境目を行ノルムのまま縁の式だけ替えると、新しい境目の
    /// 両側で差が出る。
    @Test(
        "細い枝と縁 1 本の式の境目をまたぐ太さの対は、同じ置き方で光の量が 0.01 しか違わない (45° の線・rect の塗り)",
        arguments: [(Float(0.99), Float(0.995)), (1.4, 1.407), (1.0, 1.5)])
    func boundaryDoesNotJump(_ pair: (Float, Float)) throws {
        var broken: [String] = []
        for offset in Self.offsets {
            func measured(line weight: Float) throws -> Double {
                try Self.total(
                    Self.light { canvas in
                        canvas.stroke(255)
                        canvas.strokeWeight(weight)
                        canvas.strokeCap(.square)
                        canvas.translate(64, 64 + offset)
                        canvas.rotate(Float.pi / 4)
                        canvas.line(-50, 0, 50, 0)
                    }) / Double(100 * weight)
            }
            func measured(fill height: Float) throws -> Double {
                try Self.total(
                    Self.light { canvas in
                        canvas.noStroke()
                        canvas.fill(255)
                        canvas.translate(64, 64 + offset)
                        canvas.rotate(Float.pi / 4)
                        canvas.rect(-50, -height / 2, 100, height)
                    }) / Double(100 * height)
            }
            let (low, high) = pair
            let line = abs(try measured(line: low) - measured(line: high))
            let fill = abs(try measured(fill: low) - measured(fill: high))
            // (1.0, 1.5) は太さが違うだけの対で、境目をまたぐ比べの目安としてどちらも 1 ± 0.03 に入る
            let limit = pair.1 > 1.45 ? 0.06 : 0.01
            if line > limit { broken.append("ずらし \(offset): 線 \(line)") }
            if fill > limit { broken.append("ずらし \(offset): 塗り \(fill)") }
        }
        #expect(broken.isEmpty, "太さ \(pair.0) と \(pair.1): \(broken.joined(separator: " / "))")
    }

    // MARK: - 縁の画素ごと

    /// 回した太い塗りの縁を、厳密な面積 (標本で数える) と画素ごとに比べる。**角の画素は見ない** — 角の
    /// 外の距離場は縁 1 本ではなく角までの距離で、面積の約束の外 (ADR-0039 決定 1)。
    @Test("45° に回した太い rect の塗りの縁は、辺に沿う画素ごとに、厳密な面積と 0.012 以内で一致する")
    func rotatedFillEdgeMatchesTheExactArea() throws {
        let half: Float = 10
        var worst: Float = 0
        var where_ = ""
        for offset: Float in [0, 0.25, 0.5, 0.75] {
            let pixels = try Self.light { canvas in
                canvas.noStroke()
                canvas.fill(255)
                canvas.translate(64.3, 64.1 + offset)
                canvas.rotate(Float.pi / 4)
                canvas.rect(-half, -half, 2 * half, 2 * half)
            }
            let center = SIMD2<Float>(64.3, 64.1 + offset)
            let c = Float(0.5).squareRoot()
            func inside(_ point: SIMD2<Float>) -> Bool {
                let d = point - center
                // 逆に 45° 回して、軸に沿った正方形の内か
                let u = c * (d.x + d.y), v = c * (d.y - d.x)
                return abs(u) <= half && abs(v) <= half
            }
            let samples = 64
            for y in 0..<pixels.height {
                for x in 0..<pixels.width {
                    let at = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                    // 角 (頂点) の近くは見ない
                    let d = at - center
                    let u = c * (d.x + d.y), v = c * (d.y - d.x)
                    if abs(abs(u) - half) < 1.5 && abs(abs(v) - half) < 1.5 { continue }
                    if abs(u) > half + 1.5 || abs(v) > half + 1.5 { continue }
                    var hit = 0
                    for sy in 0..<samples {
                        for sx in 0..<samples {
                            let sample = SIMD2(
                                Float(x) + (Float(sx) + 0.5) / Float(samples),
                                Float(y) + (Float(sy) + 0.5) / Float(samples))
                            if inside(sample) { hit += 1 }
                        }
                    }
                    let exact = Float(hit) / Float(samples * samples)
                    let diff = abs(pixels[x, y].red - exact)
                    if diff > worst {
                        worst = diff
                        where_ = "(\(x), \(y)) ずらし \(offset): 値 \(pixels[x, y].red)・面積 \(exact)"
                    }
                }
            }
        }
        #expect(worst <= 0.012, "最大の差 \(worst) — \(where_)")
    }

    // MARK: - 軸に沿う形は動かない

    /// 軸に沿う形 (回さない・90° の倍数・縦横で違う倍率) の `rect` の塗り・輪郭・線を、半端な位置に置いた
    /// 絵 (出力段を通した 8 bit) の指紋。**直す前の値をそのまま写してある** — 縁の式と境目を替えても、
    /// この絵は 1 ビットも動かない (#2991 完了条件 3)。
    static let axisAlignedFingerprints: [(name: String, digest: String)] = [
        ("rect の塗りと輪郭・0°・倍率 1.0 × 1.0", "808cb3d461e566a04cefd9cea78cd004da68e61cf13b9537bb9c94a843a7ffb3"),
        ("細い rect と線・0°・倍率 1.0 × 1.0", "d978e2cac94b4ab19853f1b2646f3fe2d73af552f4b6e5db5fc0ad81f2d821b2"),
        ("rect の塗りと輪郭・0°・倍率 3.0 × 0.4", "7002fd85b92ddd40759089a9a03fced58049b6bc8f63f7ed433af70f64690796"),
        ("細い rect と線・0°・倍率 3.0 × 0.4", "ae63d0bc3c6945822990438ae6c596eef7cecf12478d6d987b11d6bc5c963c12"),
        ("rect の塗りと輪郭・0°・倍率 0.7 × 2.5", "d661f258e86942a2bf92aaa755c3695a4544deae75a903f62faec4c71d85bbd0"),
        ("細い rect と線・0°・倍率 0.7 × 2.5", "b5b9ae2d4354e375e3cee2a3596bbb43121835bd698dfdef965e9cb99c163d1a"),
        ("rect の塗りと輪郭・90°・倍率 1.0 × 1.0", "359558c47115b9c07c879773fb1a6d206a2d6f543eb0a3213bb684e09170bd9a"),
        ("細い rect と線・90°・倍率 1.0 × 1.0", "2d6cae1b29a488ff5168c4ff7b6a23f93380c85a530ad6b90b2205518fbc3415"),
        ("rect の塗りと輪郭・90°・倍率 3.0 × 0.4", "abf6b7827f5842cbc308e758410a3abab901bfdde399df2f52c13e349b91086a"),
        ("細い rect と線・90°・倍率 3.0 × 0.4", "e71e2e47ed73edbdb3df3435dcb927eb47f5e9692106af888e9f63d847ac4d70"),
        ("rect の塗りと輪郭・90°・倍率 0.7 × 2.5", "2b738f3bab62ad9c5c8be031ac726be2974eb814772515cedc99e8de9f27e43b"),
        ("細い rect と線・90°・倍率 0.7 × 2.5", "3adeea72ba93cd4ecf8677aaf5b46cbb8851542ac2dfdc0659e71b474001d49a"),
        ("rect の塗りと輪郭・180°・倍率 1.0 × 1.0", "808cb3d461e566a04cefd9cea78cd004da68e61cf13b9537bb9c94a843a7ffb3"),
        ("細い rect と線・180°・倍率 1.0 × 1.0", "c44dcda4a34f5c4eebf3a5514739d9f8391a8d3c03408bc780d63930349923e6"),
        ("rect の塗りと輪郭・180°・倍率 3.0 × 0.4", "7002fd85b92ddd40759089a9a03fced58049b6bc8f63f7ed433af70f64690796"),
        ("細い rect と線・180°・倍率 3.0 × 0.4", "dfd7647a5ba2f87795d5d0c50601970e8ade7165a81d470a952c5795deeebff4"),
        ("rect の塗りと輪郭・180°・倍率 0.7 × 2.5", "d661f258e86942a2bf92aaa755c3695a4544deae75a903f62faec4c71d85bbd0"),
        ("細い rect と線・180°・倍率 0.7 × 2.5", "11cf5bc0e2c7a36ee685740e0df71c55a31f0e853358211ff1a76b95074883de"),
        ("rect の塗りと輪郭・270°・倍率 1.0 × 1.0", "359558c47115b9c07c879773fb1a6d206a2d6f543eb0a3213bb684e09170bd9a"),
        ("細い rect と線・270°・倍率 1.0 × 1.0", "a4e8a2e79b268bdf60dce4548dc3fceb3236104800c61e0f5abc827df282f766"),
        ("rect の塗りと輪郭・270°・倍率 3.0 × 0.4", "abf6b7827f5842cbc308e758410a3abab901bfdde399df2f52c13e349b91086a"),
        ("細い rect と線・270°・倍率 3.0 × 0.4", "b6e0492d89b5f938b645e7e9535ba9f60ab5326e2fbad1be4b557007c73ca659"),
        ("rect の塗りと輪郭・270°・倍率 0.7 × 2.5", "2b738f3bab62ad9c5c8be031ac726be2974eb814772515cedc99e8de9f27e43b"),
        ("細い rect と線・270°・倍率 0.7 × 2.5", "a4ecf914cfa7cf9451902d4e9fdc0e353cb4e055f0a693fc08f3f085c6ad7605"),
    ]

    static func axisAlignedScenes() -> [(name: String, draw: (Canvas) -> Void)] {
        func place(_ canvas: Canvas, turns: Int, scale: SIMD2<Float>) {
            canvas.translate(64.3, 63.7)
            canvas.rotate(Float(turns) * Float.pi / 2)
            canvas.scale(scale.x, scale.y)
        }
        var scenes: [(String, (Canvas) -> Void)] = []
        for turns in 0..<4 {
            for scale in [SIMD2<Float>(1, 1), SIMD2<Float>(3, 0.4), SIMD2<Float>(0.7, 2.5)] {
                let label = "\(turns * 90)°・倍率 \(scale.x) × \(scale.y)"
                scenes.append(("rect の塗りと輪郭・\(label)", { canvas in
                    canvas.push()
                    place(canvas, turns: turns, scale: scale)
                    canvas.fill(200, 120, 60)
                    canvas.stroke(255)
                    canvas.strokeWeight(2.3)
                    canvas.rect(-9.4, -6.2, 18.8, 12.4)
                    canvas.pop()
                }))
                scenes.append(("細い rect と線・\(label)", { canvas in
                    canvas.push()
                    place(canvas, turns: turns, scale: scale)
                    canvas.noStroke()
                    canvas.fill(255)
                    canvas.rect(-12, -0.31, 24, 0.62)
                    canvas.stroke(255)
                    canvas.strokeWeight(0.7)
                    canvas.line(-12, 4.4, 12, 4.4)
                    canvas.strokeWeight(1.6)
                    canvas.strokeCap(.square)
                    canvas.line(-12, -4.4, 12, -4.4)
                    canvas.pop()
                }))
            }
        }
        return scenes
    }

    static func fingerprint(_ draw: (Canvas) -> Void) throws -> String {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(10, 20, 30)
            draw(canvas)
        }
        let image = try canvas.output.encodeForDisplay()
        return SHA256.hash(data: Data(image.bytes)).map { String(format: "%02x", $0) }.joined()
    }

    @Test("軸に沿う形 (0°・90°・180°・270°・縦横で違う倍率) の絵は、直す前と 1 ビットも違わない")
    func axisAlignedShapesDoNotMove() throws {
        let scenes = Self.axisAlignedScenes()
        var lines: [String] = []
        for scene in scenes {
            lines.append("\(scene.name)\t\(try Self.fingerprint(scene.draw))")
        }
        if ProcessInfo.processInfo.environment["MOKUME_PRINT_FINGERPRINTS"] != nil {
            print(lines.joined(separator: "\n"))
        }
        let expected = Dictionary(uniqueKeysWithValues: Self.axisAlignedFingerprints.map { ($0.name, $0.digest) })
        var moved: [String] = []
        for line in lines {
            let parts = line.split(separator: "\t").map(String.init)
            if expected[parts[0]] != parts[1] { moved.append(parts[0]) }
        }
        #expect(moved.isEmpty, "動いた絵: \(moved)")
    }
}
