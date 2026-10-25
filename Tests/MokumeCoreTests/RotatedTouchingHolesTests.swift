// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 穴の触れ方を判定する所が、座標の厳密な一致に頼っていないこと ([#2997])。CPU だけで確かめる。
///
/// 穴が頂点で触れ合う・別の穴の辺の途中に頂点が載る (T 字)・外周の辺に重なる形は、格子の座標では
/// 厳密に一致するが、**回した・傾けた・計算で求めた座標では、丸めで厳密には一致しない**。触れ方を
/// 組み直しの道へ送る判定が厳密な一致 (`a == c`・外積が 0) で見ていると、丸めで外れた触れ方は
/// 「交わらない」と判定されて畳む道 (`mergeHoles` → 耳切り) へ落ち、裏返った三角形を出す・形の
/// 半分が抜ける。組み直しの側は許容 (形の大きさ × 2^-16) の中の点を束ねるので、判定の側が食い違っていた。
///
/// 入力は、格子の場面を (100,100) を中心に Float の `cos` / `sin` で回したもの (反証役が測った形)。
/// 外周から穴を引いた面積どおりに塗られ、裏返った三角形が無いことを、`TouchingHoleScene` (本番の道を
/// そのまま通す) で測る。
///
/// [#2997]: https://github.com/mokume-metal/mokume/issues/2997
@Suite("回した座標の穴の触れ方")
nonisolated struct RotatedTouchingHolesTests {
    nonisolated static let outer: [SIMD2<Float>] = [
        SIMD2(0, 0), SIMD2(200, 0), SIMD2(200, 200), SIMD2(0, 200),
    ]
    nonisolated static let arrowhead: [SIMD2<Float>] = [
        SIMD2(60, 100), SIMD2(100, 80), SIMD2(140, 100), SIMD2(100, 60),
    ]
    /// 矢じりの下の 2 つの角が辺の途中に載る (T 字)。
    nonisolated static let beamT: [SIMD2<Float>] = [SIMD2(40, 100), SIMD2(100, 140), SIMD2(160, 100)]
    /// 島の中の穴。
    nonisolated static let small: [SIMD2<Float>] = [SIMD2(95, 96), SIMD2(105, 96), SIMD2(100, 90)]
    /// 斜めの辺の T 字 (角が斜めの辺の途中に載る) と、島の中の小さな穴。
    nonisolated static let slantedArrow: [SIMD2<Float>] = [
        SIMD2(70, 110), SIMD2(100, 40), SIMD2(130, 110), SIMD2(100, 70),
    ]
    nonisolated static let slantedBeam: [SIMD2<Float>] = [SIMD2(40, 140), SIMD2(160, 140), SIMD2(100, 80)]
    nonisolated static let tiny: [SIMD2<Float>] = [SIMD2(96, 78), SIMD2(104, 78), SIMD2(100, 75)]
    /// 外周の辺に 2 つの角が載る矢じりの袋と、袋の中の穴。
    nonisolated static let dart: [SIMD2<Float>] = [
        SIMD2(60, 200), SIMD2(100, 150), SIMD2(140, 200), SIMD2(100, 170),
    ]
    nonisolated static let pocketHole: [SIMD2<Float>] = [SIMD2(95, 190), SIMD2(105, 190), SIMD2(100, 182)]

    /// `degrees` だけ (100,100) のまわりに回す。**Float の `cos` / `sin` で、行列の積のまま**
    /// (利用者が計算で求める座標と同じ丸め方)。
    nonisolated static func rotated(_ ring: [SIMD2<Float>], by degrees: Float) -> [SIMD2<Float>] {
        let angle = degrees * .pi / 180
        let (c, s) = (cos(angle), sin(angle))
        return ring.map { point in
            let q = point - SIMD2(100, 100)
            return SIMD2(c * q.x - s * q.y, s * q.x + c * q.y) + SIMD2(100, 100)
        }
    }

    /// 回した場面が、面積どおりに塗られ、三角形が裏返らないか。誤りがあれば、その文面。
    ///
    /// `sampled` なら、標本点の被覆 (`measure()`) も見る。**角度を大量に振る検査は標本を省く** — 標本の
    /// 被覆は費用の大半を占め、面積の誤差と裏返りだけで、塗り漏れ・はみ出し・重なりの大きいものは
    /// 捕まる (誤りの形は面積に出る)。
    nonisolated static func problem(
        outer: [SIMD2<Float>], holes: [[SIMD2<Float>]], by degrees: Float, sampled: Bool = true
    ) -> String? {
        let scene = TouchingHoleScene(
            index: 0, outer: rotated(outer, by: degrees), holes: holes.map { rotated($0, by: degrees) })
        var painted: Float = 0
        for t in scene.triangles() {
            let signed = Triangulation.cross(t.1 - t.0, t.2 - t.0) / 2
            if signed < -0.01 { return "\(degrees)°: 裏返った三角形 (面積 \(signed))" }
            painted += abs(signed)
        }
        let areaError = abs(painted - scene.expectedArea)
        if areaError > 0.5 { return "\(degrees)°: 面積の誤差 \(areaError)" }
        if sampled {
            let result = scene.measure()
            if result.mismatches > 0 { return "\(degrees)°: 標本点の食い違い \(result.mismatches)" }
        }
        return nil
    }

    // MARK: - 失敗が見つかった角度

    /// 反証役が測って失敗した (場面・角度)。**回さない (0°) と、すべて正しく塗れる。**
    struct Failing: Sendable, CustomTestStringConvertible {
        let name: String
        let outer: [SIMD2<Float>]
        let holes: [[SIMD2<Float>]]
        let degrees: [Float]
        var testDescription: String { name }
    }

    nonisolated static let failing: [Failing] = {
        let mixed = TouchingHoleScenes.mixedLattice(count: 350)
        let vertex = TouchingHoleScenes.make(.vertexToVertex, count: 400)
        return [
            Failing(
                name: "(a) T 字 2 点が島を囲む", outer: outer, holes: [arrowhead, beamT], degrees: [43.3]),
            Failing(
                name: "(a) と島の中の穴", outer: outer, holes: [arrowhead, beamT, small],
                degrees: [43.3, 222.1, 223.0, 227.7]),
            Failing(
                name: "斜めの T 字と島の中の穴", outer: outer,
                holes: [slantedArrow, slantedBeam, tiny], degrees: [295.7, 336.0]),
            Failing(
                name: "外周の辺に触れる矢じりの袋と、袋の中の穴", outer: outer, holes: [dart, pocketHole],
                degrees: (0..<3600).map { Float($0) / 10 }),
            Failing(
                name: "外周の辺に重なる穴 (mixedLattice 84)", outer: mixed[84].outer, holes: mixed[84].holes,
                degrees: [133]),
            Failing(
                name: "外周の辺に重なる穴 (mixedLattice 73)", outer: mixed[73].outer, holes: mixed[73].holes,
                degrees: [145]),
            Failing(
                name: "外周の辺に重なる穴 (mixedLattice 349)", outer: mixed[349].outer,
                holes: mixed[349].holes, degrees: [333]),
            Failing(
                name: "触れ合わないが頂点が一直線に並ぶ 2 つの穴 (make(.vertexToVertex) 168)",
                outer: vertex[168].outer, holes: vertex[168].holes, degrees: [1]),
            // 触れ合わない穴でも、橋が回した座標の頂点をちょうど通る形。厳密に 0 で見る遮りの判定は、
            // 橋が頂点を通り抜けて耳切りを止めた (畳む道・反証役が測った角度)
            Failing(
                name: "橋が頂点を通る (make(.vertexToVertex) 95)", outer: vertex[95].outer,
                holes: vertex[95].holes, degrees: [286.0, 356.5, 359.5]),
            Failing(
                name: "橋が頂点を通る (make(.vertexToVertex) 207)", outer: vertex[207].outer,
                holes: vertex[207].holes, degrees: [214.26, 232.29465]),
            Failing(
                name: "橋が頂点を通る (make(.vertexToVertex) 214)", outer: vertex[214].outer,
                holes: vertex[214].holes, degrees: [65.300735]),
        ]
    }()

    @Test("回した座標でも、穴が触れ合う場面は外周から穴を引いた面積どおりに塗られ、三角形は裏返らない (#2997)", arguments: failing)
    func rotatedScenesArePaintedWhole(_ item: Failing) {
        var problems: [String] = []
        for degrees in item.degrees {
            if let message = Self.problem(
                outer: item.outer, holes: item.holes, by: degrees, sampled: item.degrees.count < 20)
            {
                problems.append(message)
            }
        }
        #expect(problems.isEmpty, "\(item.name): 誤る角度 \(problems.count) 個 \(problems.prefix(6))")
    }

    // MARK: - 角度を振る

    /// 0.1° 刻みで 3600 の角度を振る。標本の数は、手元で数秒に収まる範囲で選んだ。
    @Test("(a) を 0.1° 刻みで回しても、どの角度でも面積どおりに塗られる (#2997)")
    func sweepOfTheIslandScene() {
        var bad: [String] = []
        for step in 0..<3600 {
            let degrees = Float(step) / 10
            if let message = Self.problem(
                outer: Self.outer, holes: [Self.arrowhead, Self.beamT], by: degrees, sampled: false)
            {
                bad.append(message)
            }
        }
        #expect(bad.isEmpty, "誤る角度 \(bad.count) 個 \(bad.prefix(6))")
    }

    @Test("mixedLattice の 84 番を 0.1° 刻みで回しても、どの角度でも面積どおりに塗られる (#2997)")
    func sweepOfAMixedLatticeScene() {
        let scene = TouchingHoleScenes.mixedLattice(count: 85)[84]
        var bad: [String] = []
        for step in 0..<3600 {
            let degrees = Float(step) / 10
            if let message = Self.problem(
                outer: scene.outer, holes: scene.holes, by: degrees, sampled: false)
            {
                bad.append(message)
            }
        }
        #expect(bad.isEmpty, "誤る角度 \(bad.count) 個 \(bad.prefix(6))")
    }

    /// 触れ合わない穴を回して、橋が頂点をちょうど通る角度を拾う。**0.1° 刻みの 3600 角度**で、誤る角度が
    /// (95 番は 14 個・207 番は 18 個) あった。
    @Test(
        "橋が頂点を通りうる場面を 0.1° 刻みで回しても、どの角度でも面積どおりに塗られる (#2997)",
        arguments: [95, 207, 214])
    func sweepOfScenesWhereABridgeMeetsAVertex(_ index: Int) {
        let scene = TouchingHoleScenes.make(.vertexToVertex, count: 400)[index]
        var bad: [String] = []
        for step in 0..<3600 {
            let degrees = Float(step) / 10
            if let message = Self.problem(
                outer: scene.outer, holes: scene.holes, by: degrees, sampled: false)
            {
                bad.append(message)
            }
        }
        #expect(bad.isEmpty, "場面 \(index): 誤る角度 \(bad.count) 個 \(bad.prefix(6))")
    }

    // MARK: - 許容の中まで近い穴・ちょうど触れる穴の並び

    /// 外周の左の辺に頂点が載る (または許容の半分だけ離れる) 細い三角の穴を `count` 個、縦に並べる。
    /// 外周の高さが穴の数に比例するので、許容 (形の大きさ × 2^-16) も穴の数に比例して広がる。
    nonisolated static func comb(count: Int, gapFactor: Float) -> (rings: [[SIMD2<Float>]], height: Float) {
        let step: Float = 5
        let height = step * Float(count) + 2
        let gap = gapFactor * height * 0x1p-16
        var rings: [[SIMD2<Float>]] = [[SIMD2(0, 0), SIMD2(100, 0), SIMD2(100, height), SIMD2(0, height)]]
        for i in 0..<count {
            let y = Float(i) * step + 1
            rings.append([SIMD2(gap, y + 1.5), SIMD2(30, y), SIMD2(30, y + 3)])
        }
        return (rings, height)
    }

    nonisolated static func painted(_ rings: [[SIMD2<Float>]]) -> (painted: Float, expected: Float) {
        let scene = TouchingHoleScene(index: 0, outer: rings[0], holes: Array(rings.dropFirst()))
        var painted: Float = 0
        for t in scene.triangles() { painted += abs(Triangulation.cross(t.1 - t.0, t.2 - t.0) / 2) }
        return (painted, scene.expectedArea)
    }

    @Test("外周の辺にちょうど触れる細い穴が 700 個並んでも、穴を引いた面積どおりに塗られる (#2997)")
    func aCombOfTouchingHolesIsPaintedWhole() {
        let (rings, _) = Self.comb(count: 700, gapFactor: 0)
        let (painted, expected) = Self.painted(rings)
        #expect(abs(painted - expected) < 1, "塗り \(painted) (期待 \(expected))")
    }

    @Test("角が離れて縦に並ぶひし形 1500 個は、触れていないので隙間は閉じず、面積どおりに塗られる (#2997)")
    func aColumnOfNearlyTouchingDiamondsIsPaintedWhole() {
        let count = 1500
        let height = Float(count) * 4 + 4
        let gap = 0.5 * height * 0x1p-16
        var rings: [[SIMD2<Float>]] = [
            [SIMD2(0, 0), SIMD2(100, 0), SIMD2(100, height), SIMD2(0, height)]
        ]
        for i in 0..<count {
            let y = Float(i) * 4 + 2
            rings.append([
                SIMD2(50, y + gap / 2), SIMD2(52, y + 2), SIMD2(50, y + 4 - gap / 2), SIMD2(48, y + 2),
            ])
        }
        let (painted, expected) = Self.paintedInDouble(outer: rings[0], holes: Array(rings.dropFirst()))
        #expect(abs(painted - expected) < 1, "塗り \(painted) (期待 \(expected))")
    }

    // MARK: - 回さない座標の形を、これまでどおりに塗る

    /// 外周と穴を、Double の面積で測る。外周が大きい (1e5) 形は、Float の面積の和では誤差が穴の面積を越える。
    nonisolated static func paintedInDouble(
        outer: [SIMD2<Float>], holes: [[SIMD2<Float>]]
    ) -> (painted: Double, expected: Double) {
        func area(_ ring: [SIMD2<Float>]) -> Double {
            var sum = 0.0
            for index in ring.indices {
                let a = ring[index]
                let b = ring[(index + 1) % ring.count]
                sum += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
            }
            return abs(sum) / 2
        }
        let scene = TouchingHoleScene(index: 0, outer: outer, holes: holes)
        var painted = 0.0
        for t in scene.triangles() {
            let ax = Double(t.1.x) - Double(t.0.x)
            let ay = Double(t.1.y) - Double(t.0.y)
            let bx = Double(t.2.x) - Double(t.0.x)
            let by = Double(t.2.y) - Double(t.0.y)
            painted += abs(ax * by - ay * bx) / 2
        }
        return (painted, holes.reduce(area(outer)) { $0 - area($1) })
    }

    /// 触れも交わりもしない細部は、**形の大きさや座標の大きさに引きずられて組み直しへ送られない**。
    /// 触れているかの判定は、回した座標の丸めのずれだけを拾う幅で見る。形全体の大きさから出した幅で見ると、
    /// 遠い頂点が 1 つあるだけ・外周が大きいだけで幅が広がり、隙間や壁が束ねられて塗られる・抜ける。
    @Test("遠い頂点が 1 つある櫛の周は、歯の隙間が閉じず、面積どおりに塗られる (#2997)", arguments: [0.5 as Float, 1, 2, 4])
    func aFarVertexDoesNotWidenTheTouchDistance(_ gap: Float) {
        var ring: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(100_000, 50), SIMD2(200, 20)]
        var x: Float = 200
        while x - 2 - gap > 0 {
            ring += [SIMD2(x, 100), SIMD2(x - 2, 100), SIMD2(x - 2, 20), SIMD2(x - 2 - gap, 20)]
            x -= 2 + gap
        }
        ring += [SIMD2(x, 100), SIMD2(0, 100)]
        let (painted, expected) = Self.paintedInDouble(outer: ring, holes: [])
        #expect(abs(painted - expected) < 0.5, "隙間 \(gap): 塗り \(painted) (期待 \(expected))")
    }

    @Test("一辺 1e5 の外周に、壁の厚さ 1 や 0.5 で穴が並んでも、壁は抜けず、面積どおりに塗られる (#2997)", arguments: [0.5 as Float, 1, 2])
    func aBigOuterRingDoesNotWidenTheTouchDistance(_ wall: Float) {
        let outer: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(100_000, 0), SIMD2(100_000, 100_000), SIMD2(0, 100_000)]
        let holes: [[SIMD2<Float>]] = (0..<10).map { k in
            let x = 10 + Float(k) * (5 + wall)
            return [SIMD2(x, 10), SIMD2(x + 5, 10), SIMD2(x + 5, 15), SIMD2(x, 15)]
        }
        let (painted, expected) = Self.paintedInDouble(outer: outer, holes: holes)
        #expect(abs(painted - expected) < 1, "壁 \(wall): 塗り \(painted) (期待 \(expected))")
    }

    @Test("座標が大きい所にある小さな形の細い針は、座標の大きさでは消えず、面積どおりに塗られる (#2997)",
        arguments: [(0.025 as Float, 30_000 as Float), (0.02, 100_000), (0.01, 10_000)])
    func aSmallShapeFarFromTheOriginKeepsItsNeedles(_ width: Float, _ offset: Float) {
        // 土台 (2 × 1) の上に、幅 width・高さ 1 の針を 5 本立てる。座標は offset だけずれている
        let origin = SIMD2<Float>(repeating: offset)
        var ring: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(2, 0), SIMD2(2, 1)].map { $0 + origin }
        let step: Float = 2 / 6
        for j in (1...5).reversed() {
            let x = Float(j) * step
            ring += [
                SIMD2(x + width, 1), SIMD2(x + width, 2), SIMD2(x, 2), SIMD2(x, 1),
            ].map { $0 + origin }
        }
        ring.append(SIMD2<Float>(0, 1) + origin)
        let (painted, expected) = Self.paintedInDouble(outer: ring, holes: [])
        #expect(abs(painted - expected) < 0.005, "幅 \(width)・座標 \(offset): 塗り \(painted) (期待 \(expected))")
    }

    // MARK: - 触れた点をまとめる手間

    /// 触れた点をまとめる所が、x の揃った触れ方で二乗にならない。縦の辺に頂点が載る三角の穴を 4 倍に
    /// 増やして、点を舐めた数 (`comparisons`) が 8 倍を越えないこと (線形なら 4 倍・二乗なら 16 倍に近づく)。
    /// 経過時間は見ない。
    @Test("縦の辺に触れる穴が 4 倍に増えても、触れた点をまとめる手間は二乗にならない (#2997)")
    func contactsAreGroupedInLinearTime() {
        func scans(_ count: Int) -> Int {
            let height = Float(count) * 4
            var rings: [[SIMD2<Float>]] = [
                [SIMD2(0, 0), SIMD2(100, 0), SIMD2(100, height), SIMD2(0, height)]
            ]
            for i in 0..<count {
                let y = Float(i) * 4 + 2
                rings.append([SIMD2(0, y), SIMD2(2, y + 1), SIMD2(2, y - 1)])
            }
            let points = rings.flatMap { $0 }
            var next = 0
            let indices = rings.map { ring -> [Int] in
                defer { next += ring.count }
                return Array(next..<(next + ring.count))
            }
            var comparisons = 0
            let split = Triangulation.splitForNonzero(
                rings: indices, points: points, comparisons: &comparisons)
            #expect(split != nil)
            return comparisons
        }
        let small = scans(2000)
        let large = scans(8000)
        #expect(large < small * 8, "2000 個 \(small) 回・8000 個 \(large) 回")
    }

    // MARK: - 傾いた平面

    /// 立体の経路が、周を外周のなす平面の基底との内積で平らな座標に落とす手順の写し
    /// (`Canvas+Vertices.swift` の `flatBasis(of:points:)` と `FlatBasis.flatten(_:)`。外周が平らで、
    /// Newell 法の向きが十分大きい形だけを写している)。
    nonisolated static func flattened(_ rings: [[SIMD3<Float>]]) -> [[SIMD2<Float>]] {
        var normal = SIMD3<Float>.zero
        let ring = rings[0]
        for index in ring.indices {
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            normal += SIMD3(
                (a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
        }
        normal = normalize(normal)
        let seed = abs(normal.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        let across = normalize(cross(seed, normal))
        let along = cross(normal, across)
        return rings.map { $0.map { SIMD2(dot($0, across), dot($0, along)) } }
    }

    /// 平面 z = 傾き × y に載せた立体の頂点を、外周の平面へ落として測る。誤りがあれば、その文面。
    nonisolated static func tiltedProblem(
        _ rings: [[SIMD2<Float>]], degrees: Float, slope: Float
    ) -> String? {
        let placed = rings.map { rotated($0, by: degrees).map { SIMD3($0.x, $0.y, slope * $0.y) } }
        let flat = flattened(placed)
        let scene = TouchingHoleScene(index: 0, outer: flat[0], holes: Array(flat.dropFirst()))
        var painted: Float = 0
        for t in scene.triangles() {
            let signed = Triangulation.cross(t.1 - t.0, t.2 - t.0) / 2
            if signed < -0.01 { return "\(degrees)° 傾き \(slope): 裏返った三角形 (面積 \(signed))" }
            painted += abs(signed)
        }
        let areaError = abs(painted - scene.expectedArea)
        return areaError > 0.5 ? "\(degrees)° 傾き \(slope): 面積の誤差 \(areaError)" : nil
    }

    @Test("傾いた平面へ落とした座標でも、回した島を囲む穴は面積どおりに塗られる (#2997)")
    func tiltedPlaneScenesArePaintedWhole() {
        let cases: [(String, [[SIMD2<Float>]])] = [
            ("(a)", [Self.outer, Self.arrowhead, Self.beamT]),
            ("(a) と島の中の穴", [Self.outer, Self.arrowhead, Self.beamT, Self.small]),
            ("袋と袋の中の穴", [Self.outer, Self.dart, Self.pocketHole]),
        ]
        var bad: [String] = []
        for (name, rings) in cases {
            for degrees in stride(from: Float(0), to: 360, by: 1) {
                for slope: Float in [0.3, 0.7, 1.3] {
                    if let message = Self.tiltedProblem(rings, degrees: degrees, slope: slope) {
                        bad.append("\(name) \(message)")
                    }
                }
            }
        }
        #expect(bad.isEmpty, "誤る場面 \(bad.count) 個 \(bad.prefix(5))")
    }
}
