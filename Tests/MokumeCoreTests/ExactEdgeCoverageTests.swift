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
/// 移した (`Shapes.metal` の `mokume_pixelCdf`・`mokume_reachPerPixel`)。
///
/// ## 見るもの
///
/// - **光の量**: 回した輪郭と線の、描く面の線形の値の総和を面積と比べる。y を 0〜15/16 の 16 通りに
///   ずらして置き、どれも 1 ± 0.03 に入る
/// - **境目の両側**: 細い枝 (両縁を重なりの面積で数える) と縁 1 本の式の境目をまたぐ 2 つの太さの、
///   光の量の差が同じ置き方で 0.01 以下
/// - **縁の画素ごと**: 回した太い塗りの縁を、厳密な面積 (標本で数える) と画素ごとに比べる
/// - **軸に沿う形は 1 ビットも動かない**: 0°・90°・180°・270°・縦横で違う倍率の `rect`・線を、半端な
///   位置に置いた絵の指紋が、直す前と同じ。**円や回した形と同じ列に並べた (旗が立った組で描かれる)
///   軸に沿う `rect`・線も、列の外で描いたのと 1 ビットも違わない**
/// - **曲線の縁は回しても同じ**: 細い枝の境目を、法線が一定の直線の縁 (`rect`・線) は画素の法線向きの幅
///   (行の絶対値の和) で、法線が回る曲線の縁 (円・楕円・扇・丸い点) は向きによらない行ノルムで測る。
///   回した円の光の量が 0° のときと同じで、45° の細い楕円は境目の手前・外のそれぞれで光の量が続く
///   (境目そのものの跳びは既知の限界で、main より大きくならないことだけを見る)
/// - **曲がった部分は軸に沿う `rect` でも面積**: 角丸の角・`strokeJoin(.round)` の外縁・`.bevel` の削ぎは
///   画素ごとに厳密な面積と一致し、既定の丸い端・`point()` は線形の渡しのまま (従来と 1 ビットも違わない)
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

    private static func makeCanvas(width: Int = size, height: Int = size) throws -> Canvas {
        let gpu = try RenderDevice()
        let output = try RenderTarget(gpu: gpu, width: width, height: height)
        return try Canvas(output: output, gpu: gpu, pixelDensity: 1, upscale: .spatial)
    }

    /// 白で黒い面へ描いて、描く面の線形の値 (赤) を返す。
    private static func light(width: Int = size, height: Int = size, _ body: (Canvas) -> Void) throws -> PixelBuffer {
        let canvas = try makeCanvas(width: width, height: height)
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

    // MARK: - 曲線の縁は回しても同じ

    /// 25 × 24 通りの置き方 (小数点以下を x は 1/25・y は 1/24 ずつずらす) で、1 枚の面に並べた図形の光の総量
    /// (描く面の線形の値の赤の総和)。`draw` は、図形の中心を原点に置いた変換の中で呼ばれる。
    private static func gridLight(angle: Float, _ draw: (Canvas) -> Void) throws -> Double {
        let columns = 25, rows = 24, pitch: Float = 12
        let pixels = try light(width: Int(Float(columns + 1) * pitch), height: Int(Float(rows + 1) * pitch)) { canvas in
            for row in 0..<rows {
                for column in 0..<columns {
                    canvas.push()
                    canvas.translate(
                        pitch + Float(column) * pitch + Float(column) / Float(columns),
                        pitch + Float(row) * pitch + Float(row) / Float(rows))
                    canvas.rotate(angle)
                    draw(canvas)
                    canvas.pop()
                }
            }
        }
        return total(pixels)
    }

    /// **回した円の光の量は、回さない円と同じ** (置き方 600 通りの総和・1 ± 0.01)。円は回しても同じ形なので、
    /// 細い枝の境目 (直径 1) も回して動いてはならない。境目を行の絶対値の和 (45° で √2) で測ると、直径が
    /// 1〜1.41 の円が細い枝 (外接する四角の面積 · 円板より 27% 多い) に入り、光の量が回すだけで動く。
    @Test(
        "円の塗りは、45° に回しても光の量が変わらない (置き方 600 通りの総和)",
        arguments: [Float(0.9), 1, 1.2, 1.4, 1.5, 2])
    func rotatedCircleFillKeepsItsLight(_ diameter: Float) throws {
        func fillCircle(_ canvas: Canvas) {
            canvas.noStroke()
            canvas.fill(255)
            canvas.circle(0, 0, diameter)
        }
        let plain = try Self.gridLight(angle: 0, fillCircle)
        let rotated = try Self.gridLight(angle: Float.pi / 4, fillCircle)
        #expect(abs(rotated / plain - 1) <= 0.01, "直径 \(diameter): 回した光 \(rotated)・回さない光 \(plain)・比 \(rotated / plain)")
    }

    @Test(
        "円の輪郭は、45° に回しても光の量が変わらない (置き方 600 通りの総和・帯の穴の境目も円の向きによらない)",
        arguments: [(Float(1.8), Float(0.9)), (2.4, 1.0), (3, 1.2), (1.6, 0.3)])
    func rotatedCircleOutlineKeepsItsLight(_ pair: (Float, Float)) throws {
        func ring(_ canvas: Canvas) {
            canvas.noFill()
            canvas.stroke(255)
            canvas.strokeWeight(pair.1)
            canvas.circle(0, 0, pair.0)
        }
        let plain = try Self.gridLight(angle: 0, ring)
        let rotated = try Self.gridLight(angle: Float.pi / 4, ring)
        #expect(
            abs(rotated / plain - 1) <= 0.01,
            "直径 \(pair.0)・太さ \(pair.1): 回した光 \(rotated)・回さない光 \(plain)・比 \(rotated / plain)")
    }

    /// **45° の細い楕円の塗りの光の量は、細い枝の中と縁 1 本の式の側のそれぞれで続き、境目の跳びは main より
    /// 大きくならない。** 楕円の境目は行ノルム (向きによらない) で、細い枝の中の見積もり
    /// (`mokume_thinEllipseCoverage` の `reach`) も同じ行ノルム — 境目は和・見積もりは行ノルムと混ざると、
    /// 境目の両側 (細い側) の続き方まで崩れる (境目を和に移した直後は、1.4 の前後でも 0.06 跳んだ)。
    ///
    /// **境目そのものの跳びは、既知の限界で、約束の外に置く。** 45° の細い楕円は、太さが行ノルムの 1 を越えても、
    /// 画素の法線向きの幅 (√2) より細い間は両縁が 1 つの画素に入り、縁 1 本の式は向こう側の縁を見られず
    /// 数えすぎる (太さ 0.99 → 0.995 で光の量が最大 0.21〜0.26 跳ぶ。**main は 0.26**)。これを無くすには
    /// 境目を直線並みの法線向きの幅へ移すことになるが、そうすると円が回すだけで境目が動く (メンテナの決定で、
    /// 曲線の縁は行ノルム・#2991)。上限は main の値より小さい 0.23 にして、退行だけを見る。
    @Test(
        "45° の細い楕円の塗りの光の量は、境目の手前・外のそれぞれで続き、境目の跳びは main より大きくならない",
        arguments: [
            (Float(0.95), Float(0.98), 0.01), (0.985, 0.99, 0.01), (1.4, 1.407, 0.01), (0.99, 0.995, 0.23),
        ])
    func thinEllipseLightKeepsContinuous(_ pair: (Float, Float, Double)) throws {
        var broken: [String] = []
        for offset in Self.offsets {
            func measured(_ width: Float) throws -> Double {
                try Self.total(
                    Self.light { canvas in
                        canvas.noStroke()
                        canvas.fill(255)
                        canvas.translate(64, 64 + offset)
                        canvas.rotate(Float.pi / 4)
                        canvas.ellipse(0, 0, 40, width)
                    }) / Double(Float.pi / 4 * 40 * width)
            }
            let diff = abs(try measured(pair.0) - measured(pair.1))
            if diff > pair.2 { broken.append("ずらし \(offset): \(diff)") }
        }
        #expect(broken.isEmpty, "太さ \(pair.0) と \(pair.1)・上限 \(pair.2): \(broken.joined(separator: " / "))")
    }

    // MARK: - 縁の画素ごと

    /// 画素 (x, y) の面積を、`samples` × `samples` の標本で数える。画素の 4 角と中心が同じ側なら標本を取らない。
    private static func sampledArea(
        _ x: Int, _ y: Int, samples: Int = 48, inside: (SIMD2<Float>) -> Bool
    ) -> Float {
        let origin = SIMD2(Float(x), Float(y))
        let probes = [SIMD2<Float>(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1), SIMD2(0.5, 0.5)]
        let hits = probes.map { inside(origin + $0) }
        if hits.allSatisfy({ $0 }) { return 1 }
        if !hits.contains(true) { return 0 }
        var hit = 0
        for sy in 0..<samples {
            for sx in 0..<samples {
                let sample = origin + SIMD2(
                    (Float(sx) + 0.5) / Float(samples), (Float(sy) + 0.5) / Float(samples))
                if inside(sample) { hit += 1 }
            }
        }
        return Float(hit) / Float(samples * samples)
    }

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

    // MARK: - 軸に沿う rect の曲がった部分

    /// 軸に沿った `rect` の、曲がった部分 (角丸の角・`strokeJoin(.round)` の外縁・`.bevel` の削ぎ) の画素を、
    /// 厳密な面積と比べる。**軸に沿う `rect` の直線の縁は線形の渡しのままだが、曲がった部分は斜めの縁を
    /// 持つので面積で数える** — 旗が立ち、`keepsLinearEdge` が偽になる。`skipping` の近く (形の角・頂点) は
    /// 見ない (角の外の距離場は縁 1 本ではなく角までの距離で、面積の約束の外・ADR-0039 決定 1)。
    /// `shift` は、輪郭が画面で寄る量 (0.5 画素・ADR-0039 決定 2)。
    private static func worstEdgeError(
        draw: (Canvas) -> Void, shift: SIMD2<Float>, skipping: [SIMD2<Float>],
        inside: (SIMD2<Float>) -> Bool
    ) throws -> (error: Float, at: String) {
        let pixels = try light(draw)
        var worst: Float = 0
        var at = ""
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let center = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                if skipping.contains(where: { simd_distance($0 + shift, center) < 2.2 }) { continue }
                let exact = sampledArea(x, y) { inside($0 - shift) }
                let diff = abs(pixels[x, y].red - exact)
                if diff > worst {
                    worst = diff
                    at = "(\(x), \(y)): 値 \(pixels[x, y].red)・面積 \(exact)"
                }
            }
        }
        return (worst, at)
    }

    /// 角を半径 `r` で丸めた箱の内か (中心 `c`・半幅 `half`)。
    private static func insideRoundedBox(_ point: SIMD2<Float>, center c: SIMD2<Float>, half: SIMD2<Float>, radius r: Float) -> Bool {
        let q = simd_abs(point - c) - (half - r)
        let outside = simd_length(simd_max(q, .zero)) + min(max(q.x, q.y), 0) - r
        return outside <= 0
    }

    @Test("軸に沿う角丸の rect の塗りの角は、画素ごとに厳密な面積と 0.02 以内で一致する (線形の渡しでは外れる)")
    func roundedCornerOfAxisAlignedRectMatchesTheExactArea() throws {
        let center = SIMD2<Float>(42.3, 35.4), half = SIMD2<Float>(22, 15)
        let result = try Self.worstEdgeError(
            draw: { canvas in
                canvas.noStroke()
                canvas.fill(255)
                canvas.rect(20.3, 20.4, 44, 30, 12)
            }, shift: .zero, skipping: []
        ) { Self.insideRoundedBox($0, center: center, half: half, radius: 12) }
        #expect(result.error <= 0.02, "最大の差 \(result.error) — \(result.at)")
    }

    @Test("軸に沿う rect の strokeJoin(.round) の外縁は、画素ごとに厳密な面積と 0.02 以内で一致する")
    func roundJoinOfAxisAlignedRectMatchesTheExactArea() throws {
        let center = SIMD2<Float>(42.3, 35.4), half = SIMD2<Float>(22, 15), weight: Float = 12
        // 帯 = 外縁 (半幅を太さの半分だけ広げた丸い角) の内で、穴 (半幅を太さの半分だけ縮めた箱) の外
        let corners = [-1, 1].flatMap { sx in
            [-1, 1].map { sy in center + SIMD2(Float(sx), Float(sy)) * (half - weight / 2) }
        }
        let result = try Self.worstEdgeError(
            draw: { canvas in
                canvas.noFill()
                canvas.stroke(255)
                canvas.strokeWeight(weight)
                canvas.strokeJoin(.round)
                canvas.rect(20.3, 20.4, 44, 30)
            }, shift: SIMD2(0.5, 0.5), skipping: corners
        ) { point in
            let grown = Self.insideRoundedBox(point, center: center, half: half, radius: 0)
                || simd_length(simd_max(simd_abs(point - center) - half, .zero)) <= weight / 2
            let q = simd_abs(point - center)
            let hole = q.x < half.x - weight / 2 && q.y < half.y - weight / 2
            return grown && !hole
        }
        #expect(result.error <= 0.02, "最大の差 \(result.error) — \(result.at)")
    }

    @Test("軸に沿う rect の strokeJoin(.bevel) の削ぎは、画素ごとに厳密な面積と 0.02 以内で一致する")
    func bevelJoinOfAxisAlignedRectMatchesTheExactArea() throws {
        let center = SIMD2<Float>(42.3, 35.4), half = SIMD2<Float>(22, 15), weight: Float = 12
        let h = weight / 2
        // 削ぎの両端と、穴の角は見ない (角の外の距離場は面積の約束の外)
        var skipping: [SIMD2<Float>] = []
        for sx in [Float(-1), 1] {
            for sy in [Float(-1), 1] {
                let sign = SIMD2(sx, sy)
                skipping.append(center + sign * (half - h))
                skipping.append(center + sign * SIMD2(half.x + h, half.y + h - (2 - Float(2).squareRoot()) * h))
                skipping.append(center + sign * SIMD2(half.x + h - (2 - Float(2).squareRoot()) * h, half.y + h))
            }
        }
        let result = try Self.worstEdgeError(
            draw: { canvas in
                canvas.noFill()
                canvas.stroke(255)
                canvas.strokeWeight(weight)
                canvas.strokeJoin(.bevel)
                canvas.rect(20.3, 20.4, 44, 30)
            }, shift: SIMD2(0.5, 0.5), skipping: skipping
        ) { point in
            let q = simd_abs(point - center)
            let outer = q.x <= half.x + h && q.y <= half.y + h
                && q.x + q.y <= half.x + half.y + h * Float(2).squareRoot()
            let hole = q.x < half.x - h && q.y < half.y - h
            return outer && !hole
        }
        #expect(result.error <= 0.02, "最大の差 \(result.error) — \(result.at)")
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
        ("丸い端の線と点・0°・倍率 1.0 × 1.0", "bcc2b24554578596d67e2b32e32dddde8e6b175fae1123d35b04e398f6ac95e9"),
        ("丸い端の線と点・0°・倍率 3.0 × 0.4", "5dd9c14326dab48d8afaf0318b2d22a452b0edf3f0ddd048fed5cb0ac65fd62d"),
        ("丸い端の線と点・0°・倍率 0.7 × 2.5", "1960c025580033d8a55932e1135d32749bea89df97c6ba92ebd3a7b9ac6fd26c"),
        ("丸い端の線と点・90°・倍率 1.0 × 1.0", "6b0acac89cb77411b02ccfcd210de662fc6467e238c3b52d85dab6c1a8b21e30"),
        ("丸い端の線と点・90°・倍率 3.0 × 0.4", "17accd28feb84e5a3c082494d9e461f25f9abd173f8a4610f39d82f301a82e41"),
        ("丸い端の線と点・90°・倍率 0.7 × 2.5", "c7632cb9336ae75a2337de540fc79fc34049254baa66e6b2ff533bdd7c64ae31"),
        ("丸い端の線と点・180°・倍率 1.0 × 1.0", "c19f605cdd2d75f450dc8f8af76892e06228eaec0255ade0adbfc9254b77e197"),
        ("丸い端の線と点・180°・倍率 3.0 × 0.4", "2fd28ae7cc91c46eaf003e984dcff9793d5006b480ec168cf8759a972c4b5cd7"),
        ("丸い端の線と点・180°・倍率 0.7 × 2.5", "f29db39f1e3600f6fe8b0e5681aa8673a47e0a164d45aaefc18c2b6dfd86584f"),
        ("丸い端の線と点・270°・倍率 1.0 × 1.0", "a840be09f120ca156d6e6fd15b76fb716d5b4a86f464acc387b6ab78d118bafc"),
        ("丸い端の線と点・270°・倍率 3.0 × 0.4", "ccc41eb1f7773e61a1c431d1bf3a43c80bf8ff76d53523509d25d5f763292283"),
        ("丸い端の線と点・270°・倍率 0.7 × 2.5", "3f52cb4a617e8acc8323a0a9600a33aac5d8fead67ec33bc49670ff61af27981"),
    ]

    /// 円と同じ列に並べる伴の円 (面の左上の隅・直径 7)。**列は塗り・輪郭の旗で切れる**ので、次に置く形と同じ
    /// 塗り・輪郭の組で描き、同じ列に入れる。円は常に斜めの縁を含むので、同じ列の形は旗が立った組で描かれる。
    /// 隅 (`companionCorner` の内) 以外の絵は、伴の円の有る無しで 1 ビットも違ってはならない。
    static func companion(_ canvas: Canvas, fills: Bool, strokes: Bool) {
        canvas.push()
        canvas.resetMatrix()
        if fills { canvas.fill(255) } else { canvas.noFill() }
        if strokes {
            canvas.stroke(255)
            canvas.strokeWeight(1.3)
        } else {
            canvas.noStroke()
        }
        canvas.circle(10.3, 10.6, 7)
        canvas.pop()
    }

    /// 伴の円が染める隅 (画素)。
    static let companionCorner = 18

    /// 軸に沿う場面。`withCompanion` なら、各形の前に、同じ列へ入る伴の円を置く。
    static func axisAlignedScenes(withCompanion: Bool = false) -> [(name: String, draw: (Canvas) -> Void)] {
        func place(_ canvas: Canvas, turns: Int, scale: SIMD2<Float>) {
            canvas.translate(64.3, 63.7)
            canvas.rotate(Float(turns) * Float.pi / 2)
            canvas.scale(scale.x, scale.y)
        }
        func alongside(_ canvas: Canvas, fills: Bool, strokes: Bool) {
            if withCompanion { companion(canvas, fills: fills, strokes: strokes) }
        }
        var scenes: [(String, (Canvas) -> Void)] = []
        for turns in 0..<4 {
            for scale in [SIMD2<Float>(1, 1), SIMD2<Float>(3, 0.4), SIMD2<Float>(0.7, 2.5)] {
                let label = "\(turns * 90)°・倍率 \(scale.x) × \(scale.y)"
                scenes.append(("rect の塗りと輪郭・\(label)", { canvas in
                    alongside(canvas, fills: true, strokes: true)
                    canvas.push()
                    place(canvas, turns: turns, scale: scale)
                    canvas.fill(200, 120, 60)
                    canvas.stroke(255)
                    canvas.strokeWeight(2.3)
                    canvas.rect(-9.4, -6.2, 18.8, 12.4)
                    canvas.pop()
                }))
                scenes.append(("細い rect と線・\(label)", { canvas in
                    alongside(canvas, fills: true, strokes: false)
                    canvas.push()
                    place(canvas, turns: turns, scale: scale)
                    canvas.noStroke()
                    canvas.fill(255)
                    canvas.rect(-12, -0.31, 24, 0.62)
                    alongside(canvas, fills: false, strokes: true)
                    canvas.stroke(255)
                    canvas.strokeWeight(0.7)
                    canvas.line(-12, 4.4, 12, 4.4)
                    canvas.strokeWeight(1.6)
                    canvas.strokeCap(.square)
                    canvas.line(-12, -4.4, 12, -4.4)
                    canvas.pop()
                }))
                // **既定の丸い端の線と `point()` は、軸に沿っていれば線形の渡しのまま** (説明に例外として
                // 書いた・曲線の縁を持つが、既定の線の列に旗が立って費用が上がるのを避けるため)
                scenes.append(("丸い端の線と点・\(label)", { canvas in
                    alongside(canvas, fills: false, strokes: true)
                    canvas.push()
                    place(canvas, turns: turns, scale: scale)
                    canvas.stroke(255)
                    canvas.strokeCap(.round)
                    canvas.strokeWeight(5)
                    canvas.line(-10, -3.1, 10, -3.1)
                    canvas.strokeWeight(6.3)
                    canvas.point(-6, 4.2)
                    canvas.strokeWeight(1.7)
                    canvas.point(8, 4.4)
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

    /// **円と同じ列に並んだ軸に沿う `rect`・線も、列の外で描いたのと 1 ビットも違わない** (旗が立った組で
    /// 描かれても)。列の旗は列ごとに 1 つで、円 (常に斜めの縁を含む) が 1 つ入ると、同じ列の軸に沿う
    /// 形も面積の枝を残した組で描かれる。軸に沿う直線の縁だけが従来の式のまま (`keepsLinearEdge`) なので、
    /// 旗が立たない列でしか見ていない上の検査では、この取り違えを見逃す。
    @Test("円と同じ列に並んだ軸に沿う rect・線は、列の外で描いたのと 1 ビットも違わない")
    func axisAlignedShapesInAFlaggedColumnDoNotMove() throws {
        let alone = Self.axisAlignedScenes()
        let together = Self.axisAlignedScenes(withCompanion: true)
        var moved: [String] = []
        for (single, mixed) in zip(alone, together) {
            func bytes(_ draw: (Canvas) -> Void) throws -> DisplayImage {
                let canvas = try Self.makeCanvas()
                try canvas.draw {
                    canvas.background(10, 20, 30)
                    draw(canvas)
                }
                return try canvas.output.encodeForDisplay()
            }
            let a = try bytes(single.draw)
            let b = try bytes(mixed.draw)
            var differing = 0
            for y in 0..<a.height {
                for x in 0..<a.width where x >= Self.companionCorner || y >= Self.companionCorner {
                    if a[x, y] != b[x, y] { differing += 1 }
                }
            }
            if differing > 0 { moved.append("\(single.name): \(differing) 画素") }
        }
        #expect(moved.isEmpty, "円と同じ列で動いた絵: \(moved)")
    }
}
