// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 立体の線の太さは、**投影の縦横比を面と違えても画面の画素で保たれる** ([#2176])。GPU を要する。
///
/// 立体の線は `strokeWeight` を画面の画素で測る約束で ([ADR-0021] 決定 2)、画面のどの向きに測っても
/// 帯の太さ・端と折れ目の形の大きさが `strokeWeight` になる。`perspective(_:_:_:_:)` の `aspect` や
/// `ortho(_:_:_:_:_:_:)` の横幅を面と違えると立体は伸びて写るが、線は伸びない。
///
/// 面はどれも 200×200 の黒地・`noFill()`・`stroke(255)` で、**横が縦の 2 倍に写る投影**(`aspect` 0.5・
/// 範囲の横 100 ÷ 縦 200) と、**半分に写る投影** (`aspect` 2・範囲の横 400 ÷ 縦 200) を当てる。面の
/// 真ん中 (100, 100) が視点の正面で、奥行き 0 の点は横だけ `stretch` 倍離れて写る
/// (x = 100 + (x − 100) × `stretch`)。太さは白 (線形の赤 ≥ 0.5) の画素を、辺を横切る 1 行か 1 列で数える。
/// 描く形は画面での位置で決め、世界の座標へは `Skew.world(_:_:_:)` で直す。
///
/// [#2176]: https://github.com/mokume-metal/mokume/issues/2176
/// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
@Suite(
    "縦横比を違えた投影の立体の線",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SolidStrokeAspectTests {
    private static let size = 200

    /// 縦横比を面と違えた投影。
    nonisolated struct Skew: CustomStringConvertible, Sendable {
        enum Kind: Sendable { case perspective, orthographic }
        let kind: Kind
        /// 画面の横が縦の何倍に写るか (面の縦横比と投影の縦横比の比の逆数)。
        let stretch: Float

        var description: String {
            "\(kind == .perspective ? "透視" : "平行")・横が\(stretch > 1 ? "2 倍" : "半分")に写る"
        }

        nonisolated static let all = [
            Skew(kind: .perspective, stretch: 2), Skew(kind: .orthographic, stretch: 2),
            Skew(kind: .perspective, stretch: 0.5), Skew(kind: .orthographic, stretch: 0.5),
        ]

        /// 投影を当てる。奥行き 0 の面は、どちらでも視点から 173.2 (= 100 / tan(π/6)) 離れる。
        @MainActor
        func apply(to canvas: Canvas) {
            switch kind {
            case .perspective: canvas.perspective(Float.pi / 3, 1 / stretch, 10, 2000)
            case .orthographic: canvas.ortho(-100 / stretch, 100 / stretch, 100, -100, 10, 2000)
            }
        }

        /// 画面の位置 (奥行き 0 の面で) に写る世界の座標。
        func world(_ screenX: Float, _ screenY: Float, _ z: Float = 0) -> SIMD3<Float> {
            SIMD3(100 + (screenX - 100) / stretch, screenY, z)
        }

        /// 世界の点を画面に写した位置 (画素)。
        func screen(_ point: SIMD3<Float>) -> SIMD2<Float> {
            let distance = 100 / tan(Float.pi / 6)
            switch kind {
            case .perspective:
                let scale = distance / (distance - point.z)
                return SIMD2(100 + (point.x - 100) * stretch * scale, 100 + (point.y - 100) * scale)
            case .orthographic:
                return SIMD2(100 + (point.x - 100) * stretch, point.y)
            }
        }
    }

    /// 白 (線形の赤が 0.5 以上) の画素。
    struct Ink {
        let size: Int
        let lit: [Bool]

        subscript(x: Int, y: Int) -> Bool {
            guard x >= 0, y >= 0, x < size, y < size else { return false }
            return lit[y * size + x]
        }

        /// 行 `y` の、画面の位置 `x` の前後 `reach` 列に入る白の数。辺 1 本だけが入る窓で数える。
        func across(row y: Int, near x: Float, reach: Int = 8) -> Int {
            let center = Int(x)
            return ((center - reach)...(center + reach)).filter { self[$0, y] }.count
        }

        /// 列 `x` の、画面の位置 `y` の前後 `reach` 行に入る白の数。
        func down(column x: Int, near y: Float, reach: Int = 8) -> Int {
            let center = Int(y)
            return ((center - reach)...(center + reach)).filter { self[x, $0] }.count
        }

        /// 画素 (x, y) から (dx, dy) の向きへ、白が続く画素の数。
        func run(fromX x: Int, y: Int, stepX dx: Int, stepY dy: Int) -> Int {
            var count = 0
            while self[x + dx * count, y + dy * count] { count += 1 }
            return count
        }
    }

    private func ink(of canvas: Canvas) throws -> Ink {
        let pixels = try canvas.target.readPixels()
        var lit: [Bool] = []
        lit.reserveCapacity(Self.size * Self.size)
        for index in 0..<(Self.size * Self.size) { lit.append(Float(pixels.components[index * 4]) >= 0.5) }
        return Ink(size: Self.size, lit: lit)
    }

    /// 200×200 の黒地に、白い線 (`stroke(255)`・塗り無し) で描く。
    private func render(_ body: (Canvas) -> Void) throws -> Ink {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: Self.size, height: Self.size)
        try canvas.draw {
            canvas.background(0)
            canvas.noFill()
            canvas.stroke(255)
            body(canvas)
        }
        return try ink(of: canvas)
    }

    /// 奥行きを持つ 4 点の閉じた輪郭。奥行き 0 なので、画面の (130, 75)–(180, 125) の正方形に写る。
    private static func outline(_ canvas: Canvas, _ skew: Skew) {
        canvas.beginShape()
        for (x, y) in [(130, 75), (180, 75), (180, 125), (130, 125)] as [(Float, Float)] {
            let point = skew.world(x, y)
            canvas.vertex(point.x, point.y, point.z)
        }
        canvas.endShape(.close)
    }

    /// 画面の (130, 75)–(180, 125) の四つの辺の太さ (左・右・上・下)。縦の辺は行 100、横の辺は列 155 を横切る。
    private static func edges(of ink: Ink) -> [Int] {
        [
            ink.across(row: 100, near: 130), ink.across(row: 100, near: 180),
            ink.down(column: 155, near: 75), ink.down(column: 155, near: 125),
        ]
    }

    private static let sides = ["左", "右", "上", "下"]

    // MARK: - 条件 1・2: 縦の辺と横の辺

    /// 起票時は、縦の辺が 12 画素・横の辺が 6 画素だった (横の倍率が 2 倍なのに、縦の倍率で太さを換算していた)。
    /// 折れ目 (既定は miter) の外側の角は、画面で縦横 3 画素ずつ出る正方形である。
    @Test("縦横比を違えた投影の立体の輪郭は、縦の辺も横の辺も折れ目も平面の同じ形と同じ太さになる", arguments: Skew.all)
    func outlineKeepsItsWeight(_ skew: Skew) throws {
        let flat = try render { canvas in
            canvas.strokeWeight(6)
            canvas.rect(130, 75, 50, 50)
        }
        let solid = try render { canvas in
            skew.apply(to: canvas)
            canvas.strokeWeight(6)
            Self.outline(canvas, skew)
        }
        let (flatEdges, solidEdges) = (Self.edges(of: flat), Self.edges(of: solid))
        for (index, name) in Self.sides.enumerated() {
            let (flatCount, solidCount) = (flatEdges[index], solidEdges[index])
            #expect(abs(solidCount - 6) <= 1, "\(skew)の\(name)の辺が \(solidCount) 画素 (6 のはず)")
            #expect(
                abs(solidCount - flatCount) <= 1, "\(skew)の\(name)の辺 \(solidCount) 画素・平面の同じ辺 \(flatCount) 画素")
        }
        // 左上の角 (130, 75) の外へ出る横の幅。上の辺の行 73 を、角の左 10 画素で数える
        let corner = (120..<130).filter { solid[$0, 73] }.count
        let flatCorner = (120..<130).filter { flat[$0, 73] }.count
        #expect(abs(corner - 3) <= 1, "\(skew)の折れ目が左へ \(corner) 画素出ている (3 のはず)")
        #expect(abs(corner - flatCorner) <= 1, "\(skew)の折れ目 \(corner) 画素・平面の同じ角 \(flatCorner) 画素")
    }

    // MARK: - 条件 3: 端の円板と斜めの帯

    /// 太さ 40 の線 (100, 60)→(100, 140) を、端 `cap` で描く。
    private func renderCapped(_ skew: Skew, cap: StrokeCap) throws -> Ink {
        try render { canvas in
            skew.apply(to: canvas)
            canvas.strokeWeight(40)
            canvas.strokeCap(cap)
            canvas.beginShape()
            canvas.vertex(100, 60, 0)
            canvas.vertex(100, 140, 0)
            canvas.endShape()
        }
    }

    /// 上端 (100, 60) から右・上・斜めに白が続く画素の数を比べる。半径 20 の円なら 20・20・14。
    @Test("縦横比を違えた投影の丸い端は、画面で円になる", arguments: Skew.all)
    func roundEndIsACircle(_ skew: Skew) throws {
        let solid = try renderCapped(skew, cap: .round)
        // 端の点は行 59 と 60 の境・列 99 と 100 の境にある。上端の外側の半円は行 59 から上
        let right = solid.run(fromX: 100, y: 59, stepX: 1, stepY: 0)
        let up = solid.run(fromX: 100, y: 59, stepX: 0, stepY: -1)
        let diagonal = solid.run(fromX: 100, y: 59, stepX: 1, stepY: -1)
        #expect(abs(up - 20) <= 1, "\(skew): 縦の半径 \(up) 画素 (20 のはず)")
        #expect(abs(right - up) <= 1, "\(skew): 横の半径 \(right) 画素・縦の半径 \(up) 画素")
        #expect(abs(diagonal - 14) <= 1, "\(skew): 斜めの半径 \(diagonal) 画素 (14 のはず)")
    }

    /// 出っ張らせる端は、線の向きに沿った正方形で、上端の外側は 40 × 20 の長方形になる (20・20・20)。
    @Test("縦横比を違えた投影の出っ張らせる端は、画面で太さの半分だけ延びた長方形になる", arguments: Skew.all)
    func projectingEndIsARectangle(_ skew: Skew) throws {
        let solid = try renderCapped(skew, cap: .project)
        let right = solid.run(fromX: 100, y: 59, stepX: 1, stepY: 0)
        let up = solid.run(fromX: 100, y: 59, stepX: 0, stepY: -1)
        let diagonal = solid.run(fromX: 100, y: 59, stepX: 1, stepY: -1)
        #expect(abs(up - 20) <= 1, "\(skew): 延びた長さ \(up) 画素 (20 のはず)")
        #expect(abs(right - 20) <= 1, "\(skew): 横の半幅 \(right) 画素 (20 のはず)")
        #expect(abs(diagonal - 20) <= 1, "\(skew): 角まで斜めに \(diagonal) 画素 (20 のはず)")
    }

    @Test("縦横比を違えた投影の点 1 つの四角い端は、画面で一辺が太さの正方形になる", arguments: Skew.all)
    func lonePointIsASquare(_ skew: Skew) throws {
        let solid = try render { canvas in
            skew.apply(to: canvas)
            canvas.strokeWeight(40)
            canvas.strokeCap(.square)
            canvas.beginShape()
            canvas.vertex(100, 100, 0)
            canvas.endShape()
        }
        let wide = solid.across(row: 100, near: 100, reach: 30)
        let tall = solid.down(column: 100, near: 100, reach: 30)
        #expect(abs(wide - 40) <= 1, "\(skew): 横の辺 \(wide) 画素 (40 のはず)")
        #expect(abs(tall - 40) <= 1, "\(skew): 縦の辺 \(tall) 画素 (40 のはず)")
    }

    /// 画面で斜めに写る線 (画面で (60, 80)→(140, 120)) の帯の、画面の垂線方向の太さ。線の真ん中の前後 25 画素 ×
    /// 垂線の前後 14 画素に入る白の面積を、長さ 50 で割る。帯の向きを視点の座標の垂線で取ると、帯は画面の
    /// 垂線から傾き、太さは 12.6 になる (横が 2 倍に写る投影・起票時の見立て)。
    @Test("縦横比を違えた投影で斜めに写る線の帯は、画面の垂線方向の太さが strokeWeight になる", arguments: Skew.all)
    func slantedBandKeepsItsWeight(_ skew: Skew) throws {
        let (a, b) = (skew.world(60, 80), skew.world(140, 120))
        let solid = try render { canvas in
            skew.apply(to: canvas)
            canvas.strokeWeight(10)
            canvas.beginShape()
            canvas.vertex(a.x, a.y, a.z)
            canvas.vertex(b.x, b.y, b.z)
            canvas.endShape()
        }
        let (start, end) = (skew.screen(a), skew.screen(b))
        #expect(abs(start.x - 60) < 1e-3 && abs(end.x - 140) < 1e-3 && start.y == 80 && end.y == 120)
        let along = normalize(end - start)
        let normal = SIMD2(-along.y, along.x)
        let middle = (start + end) / 2
        var area = 0
        for y in 0..<Self.size {
            for x in 0..<Self.size where solid[x, y] {
                let offset = SIMD2(Float(x) + 0.5, Float(y) + 0.5) - middle
                if abs(dot(offset, along)) <= 25 && abs(dot(offset, normal)) <= 14 { area += 1 }
            }
        }
        let thickness = Float(area) / 50
        #expect(abs(thickness - 10) <= 1, "\(skew): 画面の垂線方向の太さ \(thickness) 画素 (10 のはず)")
    }

    // MARK: - 条件 4: GPU の骨

    /// 箱の前の面の四つの稜 (左・右・上・下) の太さ。縦の稜は行 100、横の稜は列 100 を横切る。
    /// 箱の世界の横幅は 60 / `stretch` で、画面では横幅が縦と同じ 60 の前の面の辺に写る。
    private static func boxEdges(of ink: Ink, _ skew: Skew) -> [Int] {
        let half = 30 / skew.stretch
        let left = skew.screen(SIMD3(100 - half, 100, 30))
        let right = skew.screen(SIMD3(100 + half, 100, 30))
        let top = skew.screen(SIMD3(100, 70, 30))
        let bottom = skew.screen(SIMD3(100, 130, 30))
        return [
            ink.across(row: 100, near: left.x, reach: 6), ink.across(row: 100, near: right.x, reach: 6),
            ink.down(column: 100, near: top.y, reach: 6), ink.down(column: 100, near: bottom.y, reach: 6),
        ]
    }

    /// 画面で正方形に近く写る箱 (世界で 60/`stretch` × 60 × 60) の稜線を描く。`throughShader` なら利用者の
    /// 断片に通して、GPU の骨を使わず CPU の帯で組む (`gpuStrokeStyleAllows`)。絵は変わらない。
    /// `tilted` なら、塗りの灰色を足して回す (稜線が面と奥行きを取り合う)。
    private func boxPicture(
        _ skew: Skew, throughShader: Bool, tilted: Bool = false
    ) throws -> (ink: Ink, display: DisplayImage) {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: Self.size, height: Self.size)
        let passThrough = try canvas.makeShader("float4 paint(Fragment in, Values values) { return in.color; }")
        try canvas.draw {
            canvas.background(0)
            if tilted { canvas.fill(90) } else { canvas.noFill() }
            canvas.stroke(255)
            skew.apply(to: canvas)
            canvas.strokeWeight(tilted ? 3 : 6)
            if throughShader { canvas.shader(passThrough) }
            canvas.translate(100, 100, 0)
            if tilted {
                canvas.rotateX(0.45)
                canvas.rotateY(0.7)
            }
            canvas.box(60 / skew.stretch, 60, 60)
            canvas.closeBatch()
            // 断片に通さなければ、稜線は GPU の骨で広げる (この検査が骨を通っていることを見る)
            let skeletons = canvas.batches.compactMap(\.strokeGeometry).count
            #expect(throughShader ? skeletons == 0 : skeletons > 0, "GPU の骨を通った列の数 \(skeletons)")
        }
        return (try ink(of: canvas), try canvas.target.encodeForDisplay())
    }

    @Test("縦横比を違えた投影の箱の稜線は、GPU の骨でも縦の稜も横の稜も strokeWeight の太さになる", arguments: Skew.all)
    func gpuBoxEdgesKeepTheirWeight(_ skew: Skew) throws {
        let (ink, _) = try boxPicture(skew, throughShader: false)
        for (name, count) in zip(Self.sides, Self.boxEdges(of: ink, skew)) {
            #expect(abs(count - 6) <= 1, "\(skew)の\(name)の稜が \(count) 画素 (6 のはず)")
        }
    }

    @Test("縦横比を違えた投影の箱の稜線は、GPU の骨と CPU の帯で同じ絵になる", arguments: Skew.all, [false, true])
    func gpuAndCPUAgree(_ skew: Skew, tilted: Bool) throws {
        let gpu = try boxPicture(skew, throughShader: false, tilted: tilted)
        let cpu = try boxPicture(skew, throughShader: true, tilted: tilted)
        if !tilted {
            for (name, count) in zip(Self.sides, Self.boxEdges(of: cpu.ink, skew)) {
                #expect(abs(count - 6) <= 1, "CPU の帯: \(skew)の\(name)の稜が \(count) 画素 (6 のはず)")
            }
        }
        var different = 0
        for y in 0..<Self.size {
            for x in 0..<Self.size where gpu.display[x, y] != cpu.display[x, y] { different += 1 }
        }
        #expect(different == 0, "\(skew)・回した塗りの箱 \(tilted): GPU と CPU で異なる画素 \(different)")
    }

    // MARK: - 条件 5: 保持した形

    @Test("縦横比を違えた投影の下に置いた保持した箱の稜線も、縦の稜と横の稜が同じ太さになる", arguments: Skew.all)
    func retainedBoxKeepsItsWeight(_ skew: Skew) throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: Self.size, height: Self.size)
        try canvas.draw {
            canvas.background(0)
            canvas.noFill()
            canvas.stroke(255)
            canvas.strokeWeight(6)
            // 投影を当てる前に記録する。線は置くときの視点で組み直される
            let held = canvas.createShape { canvas.box(60 / skew.stretch, 60, 60) }
            skew.apply(to: canvas)
            canvas.translate(100, 100, 0)
            canvas.shape(held)
        }
        for (name, count) in zip(Self.sides, Self.boxEdges(of: try ink(of: canvas), skew)) {
            #expect(abs(count - 6) <= 1, "\(skew): 保持した箱の\(name)の稜が \(count) 画素 (6 のはず)")
        }
    }

    @Test("縦横比を違えた投影の下に置いた保持した輪郭も、縦の辺と横の辺が同じ太さになる", arguments: Skew.all)
    func retainedOutlineKeepsItsWeight(_ skew: Skew) throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: Self.size, height: Self.size)
        try canvas.draw {
            canvas.background(0)
            canvas.noFill()
            canvas.stroke(255)
            canvas.strokeWeight(6)
            let held = canvas.createShape { Self.outline(canvas, skew) }
            skew.apply(to: canvas)
            canvas.shape(held)
        }
        let edges = Self.edges(of: try ink(of: canvas))
        for (name, count) in zip(Self.sides, edges) {
            #expect(abs(count - 6) <= 1, "\(skew): 保持した輪郭の\(name)の辺が \(count) 画素 (6 のはず)")
        }
    }
}
