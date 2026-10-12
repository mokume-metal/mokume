// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 性能レビュー (#1744・2026-10-12) の再検証の計測の下書き。群 G3Geometry:
// #2370 (mergeHoles)・#2376 (線の経路の隔離検査と確保)・#2377 (color の sRGB → 線形)・
// #2389 (純粋な関数の nonisolated)・#2369 (pixels[x, y])・#2209 / #1948 (StrokeCarving)。
//
// **いまの費用の大きさ**を測る (前後比較ではない)。出力は 1 行ずつ
// `PERF\t<Issue>\t<場面>\t<指標>\t<値>\t<単位>` で、grep で集める。release で走らせる
// (`make test-release` 相当)。debug の数字を根拠にしない — 特に #2377 の 256³ の照合は
// debug だと 30 秒を越えうる。
//
// CPU だけの計測 (三角形分割・色・隔離・引き算) は GPU の門を付けない suite に、Canvas を
// 使う計測は GPU の門を付けた suite に分けた。

import Foundation
import Metal
import Testing
import simd

@testable import MokumeCore

// MARK: - 計測の道具

private struct G3Stats {
    var median: Double
    var p90: Double
    var minimum: Double
}

private func g3Milliseconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
}

private func g3Summary(_ samples: [Double]) -> G3Stats {
    let sorted = samples.sorted()
    let p90Index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * 0.9).rounded(.up)) - 1))
    return G3Stats(median: sorted[sorted.count / 2], p90: sorted[p90Index], minimum: sorted[0])
}

/// 暖機 `warmup` 回の後に `runs` 回測る (ms)。
private func g3Measure(warmup: Int = 3, runs: Int = 15, _ body: () throws -> Void) rethrows -> G3Stats {
    let clock = ContinuousClock()
    for _ in 0..<warmup { try body() }
    var samples: [Double] = []
    samples.reserveCapacity(runs)
    for _ in 0..<runs {
        let start = clock.now
        try body()
        samples.append(g3Milliseconds(clock.now - start))
    }
    return g3Summary(samples)
}

/// 描く本体 (CPU の組み立てだけ) と、`draw` 全体 (描き切りと決着の待ちを含む壁時計) を分けて測る。
private func g3MeasureDraw(
    _ canvas: Canvas, warmup: Int = 3, runs: Int = 15, _ body: () -> Void
) throws -> (build: G3Stats, whole: G3Stats) {
    let clock = ContinuousClock()
    var builds: [Double] = []
    var wholes: [Double] = []
    for run in 0..<(warmup + runs) {
        var build: Duration = .zero
        let start = clock.now
        try canvas.draw {
            let bodyStart = clock.now
            body()
            build = clock.now - bodyStart
        }
        // draw は投入しても待たない。決着までの待ちも壁時計に入れる
        try canvas.gpu.settle()
        let whole = clock.now - start
        if run >= warmup {
            builds.append(g3Milliseconds(build))
            wholes.append(g3Milliseconds(whole))
        }
    }
    return (g3Summary(builds), g3Summary(wholes))
}

private func g3Report(_ issue: Int, _ scene: String, _ stats: G3Stats, unit: String = "ms") {
    print("PERF\t\(issue)\t\(scene)\tmedian\t\(stats.median)\t\(unit)")
    print("PERF\t\(issue)\t\(scene)\tp90\t\(stats.p90)\t\(unit)")
    print("PERF\t\(issue)\t\(scene)\tmin\t\(stats.minimum)\t\(unit)")
}

private func g3Value(
    _ issue: Int, _ scene: String, _ metric: String, _ value: some CustomStringConvertible,
    _ unit: String
) {
    print("PERF\t\(issue)\t\(scene)\t\(metric)\t\(value)\t\(unit)")
}

/// 中央値 (ms) を 1 回あたりの ns に直す。
private func g3PerCall(_ stats: G3Stats, calls: Int) -> Double {
    stats.median * 1_000_000 / Double(calls)
}

/// 最適化で計算が消えないよう、結果をここへ流す (main actor のグローバル)。
private var g3Checksum: Double = 0

private func g3BitwiseEqual(_ a: LinearRGBA, _ b: LinearRGBA) -> Bool {
    a.red.bitPattern == b.red.bitPattern && a.green.bitPattern == b.green.bitPattern
        && a.blue.bitPattern == b.blue.bitPattern && a.alpha.bitPattern == b.alpha.bitPattern
}

private func g3Sysctl(_ name: String) -> Int {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : -1
}

// MARK: - #2370 の入力

private enum G3Holes {
    /// 外周 1 つ (反時計回り・数学の向き) と、`side` × `side` 個の 4 点の正方形の穴。
    ///
    /// `holesOpposite` が真なら穴は外周と逆に回る (`mergeHoles` が前提にする向き。Canvas の
    /// 経路では、同じ向きの穴は `splitForNonzero` が先に受け取り、`mergeHoles` へ直には来ない)。
    /// `jitter` が 1 なら穴ごとに位置を少しずらし (行・列で座標が揃わない)、2 なら加えて
    /// 正方形を少し回す (穴の右端の点が 1 つに決まる)。0 は揃った格子。
    static func grid(side: Int, holesOpposite: Bool, jitter: Int = 0) -> (
        outer: [Int], holes: [[Int]], points: [SIMD2<Float>]
    ) {
        let pitch: Float = 4
        let size: Float = 1
        let extent = pitch * Float(side + 1)
        var points: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(extent, 0), SIMD2(extent, extent), SIMD2(0, extent),
        ]
        var holes: [[Int]] = []
        holes.reserveCapacity(side * side)
        for column in 0..<side {
            for row in 0..<side {
                let serial = Float(column * side + row)
                let shift = jitter >= 1
                    ? SIMD2<Float>(0.37 * sin(serial * 1.618 + 0.3), 0.37 * cos(serial * 2.414 + 0.7))
                    : .zero
                let x = pitch * Float(column + 1) - size / 2 + shift.x
                let y = pitch * Float(row + 1) - size / 2 + shift.y
                var square: [SIMD2<Float>] = [
                    SIMD2(x, y), SIMD2(x + size, y), SIMD2(x + size, y + size), SIMD2(x, y + size),
                ]
                if jitter >= 2 {
                    let center = SIMD2(x + size / 2, y + size / 2)
                    let angle = 0.1 + 0.05 * sin(serial)
                    let (c, s) = (cos(angle), sin(angle))
                    square = square.map { corner in
                        let d = corner - center
                        return center + SIMD2(c * d.x - s * d.y, s * d.x + c * d.y)
                    }
                }
                if holesOpposite { square.reverse() }
                let base = points.count
                points.append(contentsOf: square)
                holes.append([base, base + 1, base + 2, base + 3])
            }
        }
        return ([0, 1, 2, 3], holes, points)
    }

    static func area(of triangles: [(Int, Int, Int)], points: [SIMD2<Float>]) -> Double {
        var total: Double = 0
        for (a, b, c) in triangles {
            let p = points[a]
            let q = points[b]
            let r = points[c]
            total += Double(abs((q.x - p.x) * (r.y - p.y) - (r.x - p.x) * (q.y - p.y))) / 2
        }
        return total
    }
}

// MARK: - #2377 の候補 (表で引く decode)

/// `color()` の経路を、0〜255 の整数の入力だけ表で引く形に写したもの。**行列は今と同じ
/// `Double` の行の積** (`ColorPrimaries` の係数の写し — 元は private)。
private enum G3ColorCandidate {
    static let table: [Float] = (0...255).map { TransferFunction.decode(Float($0) / 255) }

    // `ColorPrimaries.workingFromSRGBRows` の写し
    static let row0 = SIMD3<Double>(0.822_461_968_714_362_4, 0.177_538_031_285_637_9, 0)
    static let row1 = SIMD3<Double>(0.033_194_198_850_961_7, 0.966_805_801_149_038_6, 0)
    static let row2 = SIMD3<Double>(
        0.017_082_630_721_120_0, 0.072_397_440_663_963_4, 0.910_519_928_614_916_4)

    /// 0〜255 の整数 (負の 0 を除く) なら表、それ以外は今と同じ式。
    @inline(__always)
    static func decode(_ encoded255: Float) -> Float {
        if encoded255 >= 0, encoded255 <= 255, encoded255.sign == .plus,
            encoded255 == encoded255.rounded(.towardZero)
        {
            return table[Int(encoded255)]
        }
        return TransferFunction.decode(encoded255 / 255)
    }

    static func color(_ red: Float, _ green: Float, _ blue: Float, _ alpha: Float = 255) -> LinearRGBA {
        let column = SIMD3<Double>(SIMD3<Float>(decode(red), decode(green), decode(blue)))
        return LinearRGBA(
            straightRed: Float((row0 * column).sum()), green: Float((row1 * column).sum()),
            blue: Float((row2 * column).sum()), alpha: alpha / 255)
    }

    /// Issue の完了条件 1 の後半「行列は定数の float の行列」をそのまま当てた形。ビットが
    /// 今と揃うかを数えるためだけに置く (`ColorPrimaries` は Double を選んだ理由を書いている)。
    static let floatMatrix = simd_float3x3(rows: [
        SIMD3<Float>(row0), SIMD3<Float>(row1), SIMD3<Float>(row2),
    ])

    static func colorFloatMatrix(_ red: Float, _ green: Float, _ blue: Float) -> LinearRGBA {
        let working = floatMatrix * SIMD3<Float>(decode(red), decode(green), decode(blue))
        return LinearRGBA(straightRed: working.x, green: working.y, blue: working.z, alpha: 1)
    }
}

// MARK: - #2389 の写し (nonisolated)

/// ライブラリの `map`・`ValueNoise`・`color` と同じ式を、`nonisolated` で写したもの。
/// ライブラリの関数は main actor 隔離で、`nonisolated` な文脈 (`concurrentPerform` の
/// `@Sendable` の閉包) から呼べないため。式がビット単位で同じことを検査で確かめてから時間を見る。
nonisolated enum G3Pure {
    static func proportion(_ value: Float, _ low: Float, _ high: Float) -> Float {
        let span = high - low
        return span.isFinite ? (value - low) / span : (value / 2 - low / 2) / (high / 2 - low / 2)
    }

    static func interpolate(_ start: Float, _ stop: Float, _ amount: Float) -> Float {
        let span = stop - start
        guard span.isFinite else { return (1 - amount) * start + amount * stop }
        guard span != 0 else { return start }
        return amount == 1 ? stop : start + span * amount
    }

    /// `map` の写し (注意の記録は持たない)。
    static func map(
        _ value: Float, _ inLow: Float, _ inHigh: Float, _ outLow: Float, _ outHigh: Float
    ) -> Float {
        guard value.isFinite, inLow.isFinite, inHigh.isFinite, outLow.isFinite, outHigh.isFinite
        else { return outLow.isFinite ? outLow : 0 }
        guard inHigh != inLow else { return outLow }
        return interpolate(outLow, outHigh, proportion(value, inLow, inHigh))
    }

    // `ValueNoise` の写し (既定の種 0・4 枚・0.5)
    static func hash(_ x: Int32, _ y: Int32, _ z: Int32, _ seed: UInt32) -> UInt32 {
        var h = UInt32(bitPattern: x) &* 0x27D4_EB2D
        h ^= UInt32(bitPattern: y) &* 0x1656_67B1
        h ^= UInt32(bitPattern: z) &* 0x9E37_79B1
        h ^= seed &* 0x85EB_CA6B
        h ^= h >> 15
        h = h &* 0x2C1B_3C6D
        h ^= h >> 12
        h = h &* 0x297A_2D39
        h ^= h >> 15
        return h
    }

    static func corner(_ x: Int32, _ y: Int32, _ z: Int32, _ seed: UInt32) -> Float {
        Float(hash(x, y, z, seed) >> 8) * (1.0 / 16_777_216.0)
    }

    static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

    static func layer(_ x: Float, _ y: Float, _ z: Float, _ seed: UInt32) -> Float {
        let limit: Float = 1_000_000
        let cx = min(max(x, -limit), limit)
        let cy = min(max(y, -limit), limit)
        let cz = min(max(z, -limit), limit)
        let xi = cx.rounded(.down)
        let yi = cy.rounded(.down)
        let zi = cz.rounded(.down)
        let xf = cx - xi
        let yf = cy - yi
        let zf = cz - zi
        let u = xf * xf * (3 - 2 * xf)
        let v = yf * yf * (3 - 2 * yf)
        let w = zf * zf * (3 - 2 * zf)
        let x0 = Int32(xi)
        let y0 = Int32(yi)
        let z0 = Int32(zi)
        let x1 = x0 &+ 1
        let y1 = y0 &+ 1
        let z1 = z0 &+ 1
        let near = mix(
            mix(corner(x0, y0, z0, seed), corner(x1, y0, z0, seed), u),
            mix(corner(x0, y1, z0, seed), corner(x1, y1, z0, seed), u), v)
        let far = mix(
            mix(corner(x0, y0, z1, seed), corner(x1, y0, z1, seed), u),
            mix(corner(x0, y1, z1, seed), corner(x1, y1, z1, seed), u), v)
        return mix(near, far, w)
    }

    /// `ValueNoise.value` の 3 次元の場合 (z ≠ 0)。
    static func noise(
        _ x: Float, _ y: Float, _ z: Float, seed: UInt32 = 0, octaves: Int = 4, falloff: Float = 0.5
    ) -> Float {
        guard x.isFinite, y.isFinite, z.isFinite else { return 0 }
        var sum: Float = 0
        var total: Float = 0
        var amplitude: Float = 1
        var frequency: Float = 1
        for octave in 0..<max(1, octaves) {
            let layerSeed = seed &+ UInt32(octave) &* 0x9E37_79B1
            sum += layer(x * frequency, y * frequency, z * frequency, layerSeed) * amplitude
            total += amplitude
            amplitude *= falloff
            frequency *= 2
        }
        return total > 0 ? sum / total : 0
    }

    // `TransferFunction.decode` と `ColorPrimaries.working` の写し
    static func decode(_ encoded: Float) -> Float {
        if encoded <= 12.92 * 0.003_130_8 { return encoded / 12.92 }
        return min(pow((encoded + 0.055) / 1.055, 2.4), .greatestFiniteMagnitude)
    }

    static let row0 = SIMD3<Double>(0.822_461_968_714_362_4, 0.177_538_031_285_637_9, 0)

    /// `color(r, g, b)` (不透明度 255) の赤の成分。
    static func colorRed(_ red: Float, _ green: Float, _ blue: Float) -> Float {
        guard red.isFinite, green.isFinite, blue.isFinite else { return 0 }
        let column = SIMD3<Double>(
            SIMD3<Float>(decode(red / 255), decode(green / 255), decode(blue / 255)))
        let alpha = min(max(Float(255) / 255, 0), 1)
        return Float((row0 * column).sum()) * alpha
    }

    /// 1 画素ぶん: noise → map → color の赤。ライブラリ版 (`G3Library.pixel`) と同じ式。
    static func pixel(_ x: Int, _ y: Int, z: Float) -> Float {
        let n = noise(Float(x) * 0.01, Float(y) * 0.01, z)
        let v = map(n, 0, 1, 0, 255)
        return colorRed(v, 255 - v, 128)
    }

    static func fillRows(_ base: UnsafeMutablePointer<Float>, width: Int, rows: Range<Int>, z: Float) {
        for y in rows {
            for x in 0..<width { base[y * width + x] = pixel(x, y, z: z) }
        }
    }

    static func fillConcurrently(
        _ output: UnsafeMutableBufferPointer<Float>, width: Int, height: Int, z: Float, chunks: Int
    ) {
        // 生のポインタは Sendable でないので、番地を数で渡す
        let address = Int(bitPattern: output.baseAddress!)
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let base = UnsafeMutablePointer<Float>(bitPattern: address)!
            let lower = height * chunk / chunks
            let upper = height * (chunk + 1) / chunks
            fillRows(base, width: width, rows: lower..<upper, z: z)
        }
    }

    /// 比較用: nonisolated の文脈で `Optional.map` に閉包を渡す (隔離の検査が入らない形)。
    static func sumWithOptionalMap(_ values: [Int?], _ table: [Float]) -> Float {
        var sum: Float = 0
        for value in values { sum += value.map { table[$0 & 255] } ?? 0 }
        return sum
    }
}

/// ライブラリそのもの (main actor) で同じ 1 画素を作る。
private enum G3Library {
    static func pixel(_ x: Int, _ y: Int, z: Float, noise: ValueNoise) -> Float {
        let n = noise.value(Float(x) * 0.01, Float(y) * 0.01, z)
        let v = map(n, 0, 1, 0, 255)
        return color(v, 255 - v, 128).red
    }
}

// MARK: - #2209 / #1948 の入力 (StrokeCarving を直に組む)

private enum G3Carving {
    /// 帯 (4 点) と点ごとの円板 (`discSides` 角形) を `Canvas.makeCarving` と同じ順 (帯を全部・
    /// 続けて点) に積む。開いた周の端も円板にする (丸い端)。
    static func build(
        points: [SIMD2<Float>], isClosed: Bool, weight: Float, wholeOutline: Bool, discSides: Int = 12
    ) -> StrokeCarving {
        var carving = StrokeCarving(
            points: points, isClosed: isClosed, weight: weight, wholeOutline: wholeOutline)
        let half = weight / 2
        let count = points.count
        let segments = isClosed ? count : count - 1
        for index in 0..<segments {
            let a = points[index]
            let b = points[(index + 1) % count]
            carving.addBand(segment: index) { polygon in
                let delta = b - a
                let length = simd_length(delta)
                guard length > 0 else { return }
                let normal = SIMD2(-delta.y, delta.x) / length * half
                polygon.append(a + normal)
                polygon.append(b + normal)
                polygon.append(b - normal)
                polygon.append(a - normal)
            }
        }
        for index in 0..<count {
            let center = points[index]
            carving.addPoint(index) { polygon in
                for side in 0..<discSides {
                    let angle = Float(side) / Float(discSides) * 2 * .pi
                    polygon.append(center + SIMD2(cos(angle), sin(angle)) * half)
                }
            }
        }
        return carving
    }

    /// 円周上の `count` 点 (基本図形の楕円の周に当たる)。
    static func circle(count: Int, radius: Float) -> [SIMD2<Float>] {
        var points: [SIMD2<Float>] = []
        points.reserveCapacity(count)
        for step in 0..<count {
            let angle = Float(step) / Float(count) * 2 * .pi
            points.append(SIMD2(cos(angle), sin(angle)) * radius + SIMD2(radius, radius))
        }
        return points
    }

    /// 揺れながら進む折れ線 (自己交差を含む)。決定的。
    static func wander(count: Int, extent: Float = 800) -> [SIMD2<Float>] {
        var points: [SIMD2<Float>] = []
        points.reserveCapacity(count)
        for index in 0..<count {
            let t = Float(index)
            let x = extent / 2 + extent * 0.45 * sin(t * 0.0137) * cos(t * 0.0031)
            let y = extent / 2 + extent * 0.45 * sin(t * 0.0101 + 1.3) + 3 * sin(t * 1.7)
            points.append(SIMD2(x, y))
        }
        return points
    }

    /// `carved` が返す片の数 (残りの凸多角形の数)。
    static func carve(_ carving: StrokeCarving) -> Int {
        var fragments = 0
        carving.carved { _, _, _, _ in fragments += 1 }
        return fragments
    }
}

// MARK: - CPU だけの計測

@Suite("PerfReview G3Geometry", .serialized)
struct PerfReviewG3Geometry {

    // MARK: #2370

    @Test(
        "#2370 mergeHoles・耳切り・交わりの門の所要 (格子に並べた 4 点の穴 25 / 100 / 400 / 900)",
        arguments: [5, 10, 20, 30])
    func mergeHolesOnAGrid(side: Int) {
      // 揃った格子 (Issue の場面) と、ずらした格子 (耳切りが最後まで通る形) の両方を測る。
      // 揃った格子は三角形が足りない (別件) ので、数と面積の期待はずらした格子にだけ掛ける
      for jitter in [0, 1] {
        let (outer, holes, points) = G3Holes.grid(side: side, holesOpposite: true, jitter: jitter)
        let holeCount = side * side
        let scene = "holes=\(holeCount) jitter=\(jitter)"
        var merged: [Int] = []
        let merging = g3Measure {
            merged = Triangulation.mergeHoles(outer: outer, holes: holes, points: points)
        }
        g3Report(2370, "mergeHoles \(scene)", merging)

        var flattened: [SIMD2<Float>] = []
        flattened.reserveCapacity(merged.count)
        for index in merged { flattened.append(points[index]) }
        var triangles: [(Int, Int, Int)] = []
        let cutting = g3Measure { triangles = Triangulation.triangulate(flattened) }
        g3Report(2370, "triangulate \(scene)", cutting)

        // Canvas の経路は、穴があると先に splitForNonzero (交わり・穴の向きと置き場所) を通る
        var split: Triangulation.Split?
        let gate = g3Measure {
            split = Triangulation.splitForNonzero(rings: [outer] + holes, points: points)
        }
        g3Report(2370, "splitForNonzero gate \(scene)", gate)

        // 穴を畳んだ単純な多角形は、頂点 V・穴 H で V + 2H − 2 枚
        let expected = points.count + 2 * holeCount - 2
        let outerSide = Double(points[1].x - points[0].x)
        let expectedArea = outerSide * outerSide - Double(holeCount)
        let area = G3Holes.area(of: triangles, points: flattened)
        g3Value(2370, scene, "mergedLength", merged.count, "indices")
        g3Value(2370, scene, "triangles", triangles.count, "count")
        g3Value(2370, scene, "expectedTriangles", expected, "count")
        g3Value(2370, scene, "areaRatio", area / expectedArea, "ratio")
        #expect(split == nil, "格子の穴は交わらず逆向きなので、門は素通りする")
        if jitter == 1 {
            #expect(triangles.count == expected)
            #expect(abs(area - expectedArea) < 1e-3 * expectedArea)
        }
      }
    }

    /// 前回のベンチで「穴 25 で三角形が少なく見えた」報告の切り分け。`mergeHoles` は穴が
    /// 外周と逆に回ることを前提にする。同じ向きの穴を直に渡すと畳んだ周が自分と重なり、
    /// 耳切りが途中で止まる (Python の写しでは 152 枚のはずが 122 枚・面積は外周いっぱい)。
    /// Canvas の経路では同じ向きの穴は `splitForNonzero` が受け取り (回り数 2 で塗る)、
    /// `mergeHoles` へ直には来ない。
    @Test("#2370 穴の向きと三角形の数 (穴 25)")
    func holeOrientationDecidesTheCount() {
        for opposite in [true, false] {
            let (outer, holes, points) = G3Holes.grid(side: 5, holesOpposite: opposite)
            let merged = Triangulation.mergeHoles(outer: outer, holes: holes, points: points)
            var flattened: [SIMD2<Float>] = []
            for index in merged { flattened.append(points[index]) }
            let triangles = Triangulation.triangulate(flattened)
            let routed = Triangulation.splitForNonzero(rings: [outer] + holes, points: points) != nil
            let scene = "holes=25 opposite=\(opposite)"
            g3Value(2370, scene, "triangles", triangles.count, "count")
            g3Value(2370, scene, "area", G3Holes.area(of: triangles, points: flattened), "units2")
            g3Value(2370, scene, "canvasRoutesToSplit", routed, "bool")
            // 揃った格子では逆向きでも数が足りない (gridAlignmentDecidesTheCount で切り分け)。値だけ記録する
            g3Value(2370, scene, "expectedTriangles", points.count + 2 * holes.count - 2, "count")
            if !opposite { #expect(routed, "同じ向きの穴は Canvas では mergeHoles に直には来ない") }
        }
    }

    /// 下書きの検査で、逆向きの穴でも三角形が V + 2H − 2 に届かなかった (穴 25 で 63 / 152)。
    /// 揃った格子 (行・列で座標が一致) のせいかを、ずらした格子・回した格子と並べて切り分ける。
    @Test("#2370 切り分け: 揃った格子 / ずらした格子 / 回した格子の三角形の数と面積", arguments: [0, 1, 2])
    func gridAlignmentDecidesTheCount(jitter: Int) {
        for (columns, rows) in [(1, 1), (2, 1), (1, 2), (2, 2), (5, 1), (1, 5), (5, 5), (30, 30)] {
            // 正方形の格子だけを作る道具なので、側の長い方で作って使う分だけ残す
            let side = max(columns, rows)
            let (outer, allHoles, points) = G3Holes.grid(side: side, holesOpposite: true, jitter: jitter)
            var holes: [[Int]] = []
            for column in 0..<columns {
                for row in 0..<rows { holes.append(allHoles[column * side + row]) }
            }
            let merged = Triangulation.mergeHoles(outer: outer, holes: holes, points: points)
            var flattened: [SIMD2<Float>] = []
            for index in merged { flattened.append(points[index]) }
            let triangles = Triangulation.triangulate(flattened)
            let vertexCount = 4 + 4 * holes.count
            let expected = vertexCount + 2 * holes.count - 2
            let holeArea = holes.reduce(Double(0)) {
                $0 + Double(abs(Triangulation.signedArea($1.map { points[$0] })))
            }
            let outerSide = Double(points[1].x - points[0].x)
            let expectedArea = outerSide * outerSide - holeArea
            let area = G3Holes.area(of: triangles, points: flattened)
            let routed = Triangulation.splitForNonzero(rings: [outer] + holes, points: points) != nil
            let scene = "grid \(columns)x\(rows) jitter=\(jitter)"
            g3Value(2370, scene, "triangles/expected", "\(triangles.count)/\(expected)", "count")
            g3Value(2370, scene, "areaRatio", area / expectedArea, "ratio")
            g3Value(2370, scene, "canvasRoutesToSplit", routed, "bool")
        }
    }

    // MARK: #2377

    @Test("#2377 color() 1 回の所要と内訳 (整数の入力・整数でない入力・候補・読み出し)")
    func colorCost() {
        let calls = 2_000_000
        var checksum: Float = 0

        let integral = g3Measure {
            var sum: Float = 0
            for index in 0..<calls {
                let made = color(
                    Float(index & 255), Float((index >> 8) & 255), Float((index >> 16) & 255))
                sum += made.red + made.green + made.blue
            }
            checksum += sum
        }
        g3Report(2377, "color() integral x\(calls)", integral)
        g3Value(2377, "color() integral", "perCall", g3PerCall(integral, calls: calls), "ns")

        let fractional = g3Measure {
            var sum: Float = 0
            for index in 0..<calls {
                let made = color(
                    Float(index & 255) + 0.37, Float((index >> 8) & 255) + 0.5,
                    Float((index >> 16) & 255) + 0.11)
                sum += made.red + made.green + made.blue
            }
            checksum += sum
        }
        g3Report(2377, "color() fractional x\(calls)", fractional)
        g3Value(2377, "color() fractional", "perCall", g3PerCall(fractional, calls: calls), "ns")

        // 内訳: decode × 3 だけ・原色の行列だけ
        let decoding = g3Measure {
            var sum: Float = 0
            for index in 0..<calls {
                sum += TransferFunction.decode(Float(index & 255) / 255)
                    + TransferFunction.decode(Float((index >> 8) & 255) / 255)
                    + TransferFunction.decode(Float((index >> 16) & 255) / 255)
            }
            checksum += sum
        }
        g3Value(2377, "decode x3", "perCall", g3PerCall(decoding, calls: calls), "ns")
        let primaries = g3Measure {
            var sum: Float = 0
            for index in 0..<calls {
                let value = Float(index & 1023) * 0.001
                sum += ColorPrimaries.working(fromSRGB: SIMD3(value, 0.5, 0.25)).x
            }
            checksum += sum
        }
        g3Value(2377, "ColorPrimaries.working", "perCall", g3PerCall(primaries, calls: calls), "ns")

        // 候補: 整数を表で引く (行列は今の Double のまま)
        let table = g3Measure {
            var sum: Float = 0
            for index in 0..<calls {
                let made = G3ColorCandidate.color(
                    Float(index & 255), Float((index >> 8) & 255), Float((index >> 16) & 255))
                sum += made.red + made.green + made.blue
            }
            checksum += sum
        }
        g3Value(2377, "candidate table+Double", "perCall", g3PerCall(table, calls: calls), "ns")

        // 逆向き (red()): 表は使えない (入力は連続した線形の値)。1 成分でも 3 成分ぶん encode する
        var samples: [LinearRGBA] = []
        for index in 0..<1024 { samples.append(color(Float(index & 255), Float((index * 7) & 255), 90)) }
        let reading = g3Measure {
            var sum: Float = 0
            for index in 0..<calls { sum += red(samples[index & 1023]) }
            checksum += sum
        }
        g3Value(2377, "red()", "perCall", g3PerCall(reading, calls: calls), "ns")
        g3Checksum += Double(checksum)
    }

    /// 表で引いた値が今の経路とビット単位で一致するかを、検査の形で確かめる。
    /// 256 段 × 3 チャンネルは decode が成分ごとに独立なので足りるが、行列を変える案も
    /// 見るために 256³ 全部を回す (release で 1 秒前後の見込み)。
    @Test("#2377 表で引いた decode と color() が今とビット単位で一致するか (256 段・256³・負の 0)")
    func tableMatchesBitwise() {
        // 1. 表そのもの: decode と、候補の表と、OutputStage.decodeLinear が一致
        var tableMismatches = 0
        for level in 0...255 {
            let direct = TransferFunction.decode(Float(level) / DisplayScale.maximum)
            if direct.bitPattern != G3ColorCandidate.table[level].bitPattern { tableMismatches += 1 }
            if direct.bitPattern != OutputStage.decodeLinear[level].bitPattern { tableMismatches += 1 }
        }
        g3Value(2377, "table vs decode", "mismatches", tableMismatches, "count")
        #expect(tableMismatches == 0)

        // 2. 256³ の color()。行列を Double のまま (候補) と float にした形 (Issue の案) を数える
        var candidateMismatches = 0
        var floatMatrixMismatches = 0
        for redLevel in 0...255 {
            for greenLevel in 0...255 {
                for blueLevel in 0...255 {
                    let (r, g, b) = (Float(redLevel), Float(greenLevel), Float(blueLevel))
                    let now = color(r, g, b)
                    if !g3BitwiseEqual(now, G3ColorCandidate.color(r, g, b)) { candidateMismatches += 1 }
                    if !g3BitwiseEqual(now, G3ColorCandidate.colorFloatMatrix(r, g, b)) {
                        floatMatrixMismatches += 1
                    }
                }
            }
        }
        g3Value(2377, "256^3 table+Double", "mismatches", candidateMismatches, "count")
        g3Value(2377, "256^3 table+floatMatrix", "mismatches", floatMatrixMismatches, "count")
        #expect(candidateMismatches == 0)

        // 3. 境界: 負の 0。今の式は decode(-0 / 255) = -0 を返す。表へ通すと +0 になるので、
        //    候補は負の 0 を表へ通さない (`sign == .plus`)。通すとここが赤くなる
        let negativeZero = color(-0.0, -0.0, -0.0)
        let candidateNegativeZero = G3ColorCandidate.color(-0.0, -0.0, -0.0)
        g3Value(2377, "color(-0,-0,-0)", "redSignMinus", negativeZero.red.sign == .minus, "bool")
        #expect(g3BitwiseEqual(negativeZero, candidateNegativeZero))
    }

    // MARK: #2389

    /// 1080p の全画素を noise → map → color で埋める。ライブラリ (main actor) で 1 本・
    /// 写した nonisolated の関数で 1 本・`concurrentPerform` で分けた場合を並べる。
    @Test(
        "#2389 1080p を noise・map・color で埋める (main で 1 本 / 写しで 1 本 / 写しを concurrentPerform)",
        arguments: ["library-main", "copy-serial", "copy-concurrent"])
    func fillAFrame(mode: String) {
        let (width, height) = (1920, 1080)
        let z: Float = 0.37
        let output = UnsafeMutableBufferPointer<Float>.allocate(capacity: width * height)
        defer { output.deallocate() }
        let noise = ValueNoise()
        let chunks = max(1, ProcessInfo.processInfo.activeProcessorCount * 4)

        // 写しがライブラリとビット単位で同じ式であること (64×64 の見本)
        var mismatches = 0
        for y in 0..<64 {
            for x in 0..<64 {
                let library = G3Library.pixel(x * 29, y * 17, z: z, noise: noise)
                let copy = G3Pure.pixel(x * 29, y * 17, z: z)
                if library.bitPattern != copy.bitPattern { mismatches += 1 }
            }
        }
        #expect(mismatches == 0, "写しの式がライブラリとずれている")

        let stats = g3Measure(runs: 15) {
            switch mode {
            case "library-main":
                for y in 0..<height {
                    for x in 0..<width { output[y * width + x] = G3Library.pixel(x, y, z: z, noise: noise) }
                }
            case "copy-serial":
                G3Pure.fillRows(output.baseAddress!, width: width, rows: 0..<height, z: z)
            default:
                G3Pure.fillConcurrently(output, width: width, height: height, z: z, chunks: chunks)
            }
        }
        g3Report(2389, "1080p \(mode)", stats)
        g3Value(2389, "1080p \(mode)", "perPixel", g3PerCall(stats, calls: width * height), "ns")
        g3Value(2389, "machine", "activeProcessors", ProcessInfo.processInfo.activeProcessorCount, "count")
        g3Value(2389, "machine", "perflevel0Logical", g3Sysctl("hw.perflevel0.logicalcpu"), "count")
        g3Value(2389, "machine", "perflevel1Logical", g3Sysctl("hw.perflevel1.logicalcpu"), "count")
        g3Value(2389, "1080p \(mode)", "chunks", mode == "copy-concurrent" ? chunks : 1, "count")
        g3Checksum += Double(output[width * height / 2])
    }

    // MARK: #2376

    /// main actor 隔離の閉包を `Optional.map` へ渡す 1 回の費用 (SE-0423 の動的隔離検査)。
    /// テストのターゲットも `.defaultIsolation(MainActor.self)` なので、ここの閉包は隔離される。
    @Test("#2376 Optional.map に閉包を渡す 1 回の所要 (main actor の閉包 / if let / nonisolated)")
    func optionalMapCost() {
        let calls = 1_000_000
        var table = [Float](repeating: 0, count: 256)
        for index in 0..<256 { table[index] = Float(index) }
        var values: [Int?] = []
        values.reserveCapacity(calls)
        for index in 0..<calls { values.append(index % 3 == 0 ? nil : index) }
        var checksum: Float = 0

        let mapped = g3Measure {
            var sum: Float = 0
            for value in values { sum += value.map { table[$0 & 255] } ?? 0 }
            checksum += sum
        }
        g3Value(2376, "Optional.map main-actor closure", "perElement", g3PerCall(mapped, calls: calls), "ns")
        let unwrapped = g3Measure {
            var sum: Float = 0
            for value in values {
                if let value { sum += table[value & 255] }
            }
            checksum += sum
        }
        g3Value(2376, "if let", "perElement", g3PerCall(unwrapped, calls: calls), "ns")
        let detached = g3Measure { checksum += G3Pure.sumWithOptionalMap(values, table) }
        g3Value(
            2376, "Optional.map nonisolated closure", "perElement", g3PerCall(detached, calls: calls), "ns")
        // 仮説の確かめ: `??` の右辺も標準ライブラリへ渡す autoclosure。左が nil の 1/3 の要素で
        // 右辺が評価されるとき、隔離の検査が入るか (strokeNet の `members[groupRoot] ?? [groupRoot]`
        // は 1 点だけの群で毎回右辺を評価する)
        let coalesced = g3Measure {
            var sum: Float = 0
            for (index, value) in values.enumerated() { sum += table[(value ?? (index & 7)) & 255] }
            checksum += sum
        }
        g3Value(2376, "?? autoclosure (1/3 nil)", "perElement", g3PerCall(coalesced, calls: calls), "ns")
        let branched = g3Measure {
            var sum: Float = 0
            for (index, value) in values.enumerated() {
                let picked: Int
                if let value { picked = value } else { picked = index & 7 }
                sum += table[picked & 255]
            }
            checksum += sum
        }
        g3Value(2376, "if let / else (1/3 nil)", "perElement", g3PerCall(branched, calls: calls), "ns")
        g3Checksum += Double(checksum)
    }

    // MARK: #2209 / #1948

    /// 基本図形 (`wholeOutline`) は先に置いた片を全部候補にする (`StrokeCarving.swift:409` の
    /// `for other in 0..<index`)。同じ周を `wholeOutline: false` (線に沿った窓) で引いたときと
    /// 並べ、2 乗の分を見る。点の数は、半径 350 の円 (84)・半径 5000 (≈315)・上限 (1024)。
    @Test("#2209 StrokeCarving: 基本図形の周の相手探し (wholeOutline の 2 乗)", arguments: [84, 315, 1024])
    func wholeOutlineCandidates(pointCount: Int) {
        let points = G3Carving.circle(count: pointCount, radius: 350)
        for whole in [true, false] {
            var fragments = 0
            let stats = g3Measure {
                let carving = G3Carving.build(points: points, isClosed: true, weight: 4, wholeOutline: whole)
                fragments = G3Carving.carve(carving)
            }
            let scene = "circle points=\(pointCount) wholeOutline=\(whole)"
            g3Report(2209, scene, stats)
            g3Value(2209, scene, "fragments", fragments, "count")
        }
    }

    /// 折れ線 (任意多角形は線に沿った窓で相手を探す) の引き算の所要。太さ 2 と 8。
    @Test("#2209 StrokeCarving: 折れ線 1,000 / 10,000 点の引き算", arguments: [1_000, 10_000])
    func polylineCarving(pointCount: Int) {
        let points = G3Carving.wander(count: pointCount)
        for weight: Float in [2, 8] {
            var fragments = 0
            let stats = g3Measure {
                let carving = G3Carving.build(
                    points: points, isClosed: false, weight: weight, wholeOutline: false)
                fragments = G3Carving.carve(carving)
            }
            let scene = "polyline points=\(pointCount) weight=\(weight)"
            g3Report(1948, scene, stats)
            g3Value(1948, scene, "fragments", fragments, "count")
            g3Value(1948, scene, "perPoint", g3PerCall(stats, calls: pointCount), "ns")
        }
    }
}

// MARK: - Canvas を使う計測

@Suite(
    "PerfReview G3Geometry GPU", .serialized,
    .enabled(if: RenderDevice.isAvailable, "GPU が無い"))
struct PerfReviewG3GeometryGPU {

    // MARK: #2369

    /// 1280×720 の全画素を読み書きする。`pixels[x, y] = pixels[x, y]` (文書の作例の形) は
    /// 1 画素ごとに `pixels` の getter を 2 回 (読む・書く) と許可の閉包を 1 回通る。
    /// 窓を 1 度だけ取る形 (`let window = pixels`) と、生のポインタの下限を並べる。
    @Test(
        "#2369 pixels[x, y] の 1 画素あたり (1280×720)",
        arguments: ["subscript-read-write", "subscript-read", "hoisted-read-write", "raw-pointer"])
    func pixelLoop(mode: String) throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 1280, height: 720)
        let (width, height) = (canvas.pixelWidth, canvas.pixelHeight)
        var checksum: Float = 0
        var settleCalls = 0
        var blockingWaits = 0
        let raw = UnsafeMutableBufferPointer<SIMD4<Float16>>.allocate(capacity: width * height)
        raw.initialize(repeating: SIMD4<Float16>(0.25, 0.5, 0.75, 1))
        defer { raw.deallocate() }
        let measured = try g3MeasureDraw(canvas) {
            canvas.background(color(23, 26, 31))
            canvas.loadPixels()  // 待つ時点をここに決める (ループの中で描き切らせない)
            let settleBefore = canvas.gpu.settleCalls
            let waitsBefore = canvas.gpu.blockingWaits
            var sum: Float = 0
            switch mode {
            case "subscript-read-write":
                for y in 0..<height {
                    for x in 0..<width { canvas.pixels[x, y] = canvas.pixels[x, y] }
                }
            case "subscript-read":
                for y in 0..<height {
                    for x in 0..<width { sum += canvas.pixels[x, y].red }
                }
            case "hoisted-read-write":
                let window = canvas.pixels
                for y in 0..<height {
                    for x in 0..<width { window[x, y] = window[x, y] }
                }
            default:
                for index in 0..<(width * height) {
                    let texel = raw[index]
                    let value = LinearRGBA(
                        premultipliedRed: Float(texel.x), green: Float(texel.y), blue: Float(texel.z),
                        alpha: Float(texel.w))
                    raw[index] = HalfSurface.texel(value)
                }
            }
            settleCalls = canvas.gpu.settleCalls - settleBefore
            blockingWaits = canvas.gpu.blockingWaits - waitsBefore
            checksum += sum
        }
        let scene = "1280x720 \(mode)"
        g3Report(2369, "\(scene) build", measured.build)
        g3Report(2369, "\(scene) whole", measured.whole)
        g3Value(2369, scene, "perPixel", g3PerCall(measured.build, calls: width * height), "ns")
        g3Value(2369, scene, "settleCallsInLoop", settleCalls, "count")
        g3Value(2369, scene, "blockingWaitsInLoop", blockingWaits, "count")
        g3Value(
            2369, scene, "estimate1080p",
            measured.build.median * 1920 * 1080 / Double(width * height), "ms")
        g3Checksum += Double(checksum)
    }

    // MARK: #2376

    /// 網の骨 (`strokeNet`) を、形を置く閉包を空にして直に呼ぶ。点ごとの `members` の配列・
    /// `[center] + members.filter`・`allSatisfy`・`first` の分が骨の費用の大半になるはず。
    /// 1 万本の離れた線分 (2 万点・点ごとに群の根) と、1 万点の折れ線 (点ごとに折れ目)。
    @Test("#2376 strokeNet の骨だけの所要 (1 万本の線分・1 万点の折れ線)")
    func strokeNetSkeleton() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 64, height: 64)
        var separate: [(Int, Int)] = []
        for start in stride(from: 0, to: 20_000, by: 2) { separate.append((start, start + 1)) }
        var chain: [(Int, Int)] = []
        for start in 0..<9_999 { chain.append((start, start + 1)) }
        let cases: [(String, Int, [(Int, Int)])] = [
            ("lines10k", 20_000, separate), ("polyline10k", 10_000, chain),
        ]
        for (label, count, edges) in cases {
            var shapes = 0
            let stats = g3Measure {
                canvas.strokeNet(
                    count: count, edges: edges,
                    toward: { a, b in
                        // 折れ線が毎点で曲がるよう、向きを点ごとにずらす
                        let angle = Float(a + b) * 0.7
                        return SIMD2(cos(angle), sin(angle))
                    },
                    endSquare: { _, _ in shapes += 1 }, band: { _, _ in shapes += 1 },
                    disc: { _ in shapes += 1 }, square: { _ in shapes += 1 },
                    corner: { _, _, _ in shapes += 1 })
            }
            g3Report(2376, "strokeNet skeleton \(label)", stats)
            g3Value(2376, "strokeNet skeleton \(label)", "perPoint", g3PerCall(stats, calls: count), "ns")
            g3Value(2376, "strokeNet skeleton \(label)", "shapesPerRun", shapes / 18, "count")
        }
    }

    /// 周の骨 (`strokeRing`) を 2 点の開いた周 1 万本で呼ぶ。端ごとに `neighbor.map` が 1 回。
    @Test("#2376 strokeRing の骨だけの所要 (2 点の開いた周 1 万本)")
    func strokeRingSkeleton() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 64, height: 64)
        var shapes = 0
        let stats = g3Measure {
            for _ in 0..<10_000 {
                canvas.strokeRing(
                    count: 2, isClosed: false, endSquare: { _, _ in shapes += 1 },
                    band: { _, _ in shapes += 1 }, disc: { _ in shapes += 1 },
                    square: { _ in shapes += 1 }, corner: { _, _, _ in shapes += 1 })
            }
        }
        g3Report(2376, "strokeRing skeleton 10k open rings", stats)
        g3Value(2376, "strokeRing skeleton", "perRing", g3PerCall(stats, calls: 10_000), "ns")
    }

    /// 細い線の片を集める (`thinCarving`・引き算の前まで) と、引き算まで。角ごとに
    /// `Optional.map` が 4 回 (`addJoin`)。
    @Test("#2376 thinCarving の所要 (太さ 0.5・1 万点のジグザグ・miter)")
    func thinCarvingCorners() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 800, height: 800)
        var points: [SIMD2<Float>] = []
        for index in 0..<10_000 {
            points.append(SIMD2(Float(index) * 0.07 + 20, index.isMultiple(of: 2) ? 100 : 160))
        }
        let outline = Canvas.Outline(points: points, isClosed: false, fills: false)
        let thin = try #require(
            canvas.thinOutline(outline, weight: 0.5, placedBy: matrix_identity_float4x4),
            "太さ 0.5 は描く画素で 1 未満なので補う")
        canvas.strokeJoin(.miter)
        let gathering = g3Measure {
            let built = canvas.thinCarving(outline, thin: thin)
            g3Checksum += Double(built.offset.x)
        }
        var fragments = 0
        let carving = g3Measure {
            let built = canvas.thinCarving(outline, thin: thin)
            fragments = G3Carving.carve(built.carving)
        }
        g3Report(2376, "thinCarving gather 10k corners", gathering)
        g3Report(2376, "thinCarving gather+carve 10k corners", carving)
        g3Value(2376, "thinCarving gather", "perCorner", g3PerCall(gathering, calls: 10_000), "ns")
        g3Value(2376, "thinCarving gather+carve", "fragments", fragments, "count")
    }

    /// 公開の口から: `beginShape(.lines)` 1 万本を平面と奥行き付きで。描く本体 (CPU) と全体。
    @Test("#2376 beginShape(.lines) 1 万本 (平面 / 奥行き付き)", arguments: [false, true])
    func tenThousandLines(depth: Bool) throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 800, height: 800)
        let measured = try g3MeasureDraw(canvas) {
            canvas.background(color(12))
            canvas.stroke(color(240))
            canvas.strokeWeight(2)
            canvas.beginShape(.lines)
            for index in 0..<10_000 {
                let t = Float(index)
                let (x, y) = (400 + 380 * sin(t * 0.013), 400 + 380 * cos(t * 0.017))
                if depth {
                    canvas.vertex(x, y, Float(0))
                    canvas.vertex(x + 12 * cos(t), y + 12 * sin(t), Float(5))
                } else {
                    canvas.vertex(x, y)
                    canvas.vertex(x + 12 * cos(t), y + 12 * sin(t))
                }
            }
            canvas.endShape()
        }
        let scene = "lines10k depth=\(depth)"
        g3Report(2376, "\(scene) build", measured.build)
        g3Report(2376, "\(scene) whole", measured.whole)
        g3Value(2376, scene, "drawCalls", canvas.drawCallsInLastFrame, "count")
    }

    // MARK: #2370 (別件: 揃った穴の塗り)

    /// 揃った格子の穴を `beginContour` で描くと、公開の口でも塗りが欠けるかを画素で数える。
    /// 外周 240×240 に 10×10 の穴を 40 間隔で並べる (G3Holes.grid を 10 倍した形)。
    @Test("#2370 別件: beginContour で揃えた穴を塗った画素の数 (縦 1 列 5 個 / 5×5 / ずらした 5×5)")
    func alignedContoursFill() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 240, height: 240)
        let scale = Float(canvas.pixelWidth) / 240
        for (label, columns, rows, jitter) in [
            ("column1x5", 1, 5, 0), ("grid5x5", 5, 5, 0), ("grid5x5 jitter", 5, 5, 1), ("row5x1", 5, 1, 0),
        ] {
            let (outer, allHoles, points) = G3Holes.grid(side: 5, holesOpposite: true, jitter: jitter)
            var holes: [[Int]] = []
            for column in 0..<columns {
                for row in 0..<rows { holes.append(allHoles[column * 5 + row]) }
            }
            var filled = 0
            try canvas.draw {
                canvas.background(color(0))
                canvas.noStroke()
                canvas.fill(color(255, 0, 0))
                canvas.beginShape()
                for index in outer { canvas.vertex(points[index].x * 10, points[index].y * 10) }
                for hole in holes {
                    canvas.beginContour()
                    for index in hole { canvas.vertex(points[index].x * 10, points[index].y * 10) }
                    canvas.endContour()
                }
                canvas.endShape(.close)
                canvas.loadPixels()
                let window = canvas.pixels
                for y in 0..<canvas.pixelHeight {
                    for x in 0..<canvas.pixelWidth where window[x, y].red > 0.5 { filled += 1 }
                }
            }
            try canvas.gpu.settle()
            let expected = (240 * 240 - holes.count * 100) * Int(scale * scale)
            g3Value(2370, "fill \(label)", "filledPixels/expected", "\(filled)/\(expected)", "px")
            g3Value(2370, "fill \(label)", "ratio", Double(filled) / Double(expected), "ratio")
        }
    }

    // MARK: #2209 / #1948

    /// 半透明の折れ線 1,000 / 10,000 点を公開の口で描く。不透明 (引かない) と並べる。
    @Test("#2209 半透明の折れ線 1,000 / 10,000 点 (不透明と並べる)", arguments: [1_000, 10_000])
    func translucentPolyline(pointCount: Int) throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 800, height: 800)
        let points = G3Carving.wander(count: pointCount)
        for (label, alpha) in [("opaque", Float(255)), ("translucent", Float(128))] {
            let measured = try g3MeasureDraw(canvas) {
                canvas.background(color(0))
                canvas.noFill()
                canvas.stroke(Float(255), Float(0), Float(0), alpha)
                canvas.strokeWeight(2)
                canvas.beginShape()
                for point in points { canvas.vertex(point.x, point.y) }
                canvas.endShape()
            }
            let scene = "polyline points=\(pointCount) \(label)"
            g3Report(2209, "\(scene) build", measured.build)
            g3Report(2209, "\(scene) whole", measured.whole)
            g3Value(2209, scene, "flatVertices", canvas.flatVerticesInLastFrame, "count")
        }
    }

    /// #2209 の完了条件 5 の場面 (平面の折れ線 50 点 × 1,000 本) を、型板の前の基準として測る。
    @Test("#2209 完了条件 5 の場面: 50 点の折れ線 1,000 本 (不透明 / 半透明)")
    func manyShortPolylines() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 800, height: 800)
        let points = G3Carving.wander(count: 50 * 1_000)
        for (label, alpha) in [("opaque", Float(255)), ("translucent", Float(128))] {
            let measured = try g3MeasureDraw(canvas) {
                canvas.background(color(0))
                canvas.noFill()
                canvas.stroke(Float(255), Float(0), Float(0), alpha)
                canvas.strokeWeight(2)
                for line in 0..<1_000 {
                    canvas.beginShape()
                    for point in points[(line * 50)..<((line + 1) * 50)] { canvas.vertex(point.x, point.y) }
                    canvas.endShape()
                }
            }
            let scene = "polylines 1000x50 \(label)"
            g3Report(2209, "\(scene) build", measured.build)
            g3Report(2209, "\(scene) whole", measured.whole)
        }
    }

    /// 基本図形の線が三角形の経路と引き算を通るのは、距離関数の経路が使えないときだけ
    /// (`shader()`・絵の塗り・畳みの雛形)。半径のばらつく円 1,000 個を `shader()` の下で描き、
    /// `wholeOutline` の 2 乗が 1 フレームでどれだけになるかを見る (`shader()` なしと並べる)。
    @Test("#2209 shader() の下の円 1,000 個 (基本図形の引き算)", arguments: [false, true])
    func ellipsesUnderShader(shaded: Bool) throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 800, height: 800)
        let passThrough = "float4 paint(Fragment in, Values values) { return in.color; }"
        var shader: Shader?
        if shaded { shader = try canvas.makeShader(passThrough) }
        let measured = try g3MeasureDraw(canvas) {
            canvas.background(color(0))
            if let shader { canvas.shader(shader) }
            canvas.noFill()
            canvas.stroke(255, 0, 0, 128)
            canvas.strokeWeight(3)
            for index in 0..<1_000 {
                let t = Float(index)
                // 直径をばらつかせ、畳みの雛形の控えに当たらないようにする
                let diameter = 40 + t * 0.6
                canvas.ellipse(400 + 300 * sin(t * 0.1), 400 + 300 * cos(t * 0.13), diameter, diameter)
            }
        }
        let scene = "circles1000 shader=\(shaded)"
        g3Report(2209, "\(scene) build", measured.build)
        g3Report(2209, "\(scene) whole", measured.whole)
        g3Value(2209, scene, "flatVertices", canvas.flatVerticesInLastFrame, "count")
    }
}
