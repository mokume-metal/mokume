// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 裏 → 表で描く置き場所の連なりを、1 回の描く呼び出しへ畳む描き方の検査 (``SolidSweep``)。GPU を要する。
///
/// 見るのは 2 つ。**絵が置き場所ごとに描いたときと同じ** (違う画素 0 — 置き場所どうしの重なりの順を
/// 含む) ことと、**描く呼び出しの数が置き場所の数に比例しない** ことである
/// ([#1947](https://github.com/mokume-metal/mokume/issues/1947))。「置き場所ごと」と「畳む」は
/// ``Canvas/sweepPolicy`` で切り替えて、同じ場面を両方で描く。
///
/// 画素は線形の値で読む。「違う画素」はどれかの成分の差が 0.02 を超える画素である。
@Suite(
    "裏 → 表の描き方を畳む (描画)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SolidSweepRenderTests {
    private static let size = 160

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: Self.size, height: Self.size)
    }

    /// 黒地に `noStroke()` で描いた 1 フレームの画素と、描く呼び出しの数。
    private func render(
        _ policy: SolidSweepPolicy, capacity: Int? = nil,
        _ body: (Canvas) throws -> Void
    ) throws -> (picture: PixelBuffer, draws: Int, batches: Int) {
        let canvas = try makeCanvas()
        canvas.sweepPolicy = policy
        if let capacity { canvas.instanceCapacity = capacity }
        try canvas.draw {
            canvas.background(.linear(red: 0, green: 0, blue: 0))
            canvas.noStroke()
            try? body(canvas)
        }
        return (
            try canvas.target.readPixels(), canvas.drawsEncodedInLastFrame, canvas.drawCallsInLastFrame
        )
    }

    private func differingPixels(_ a: PixelBuffer, _ b: PixelBuffer) -> Int {
        var count = 0
        for y in 0..<a.height {
            for x in 0..<a.width {
                let (p, q) = (a[x, y], b[x, y])
                if abs(p.red - q.red) > 0.02 || abs(p.green - q.green) > 0.02
                    || abs(p.blue - q.blue) > 0.02 || abs(p.alpha - q.alpha) > 0.02
                {
                    count += 1
                }
            }
        }
        return count
    }

    /// 黒でない画素の数。場面が空でないことを確かめる。
    private func litPixels(_ picture: PixelBuffer) -> Int {
        var count = 0
        for y in 0..<picture.height {
            for x in 0..<picture.width {
                let pixel = picture[x, y]
                if pixel.red > 0.02 || pixel.green > 0.02 || pixel.blue > 0.02 { count += 1 }
            }
        }
        return count
    }

    /// 面の中心から `radius` 画素以内の画素の位置。
    private func disc(radius: Int) -> [(x: Int, y: Int)] {
        var points: [(x: Int, y: Int)] = []
        let c = Self.size / 2
        for y in (c - radius)...(c + radius) {
            for x in (c - radius)...(c + radius)
            where (x - c) * (x - c) + (y - c) * (y - c) <= radius * radius {
                points.append((x, y))
            }
        }
        return points
    }

    // MARK: - 場面

    /// 一辺 36 の立方体の OBJ。**面ごとに法線 (外向き) を書く**ので、頂点の向きは形から求めず
    /// (畳める)、`inward` なら面の巻き方だけを裏返す。
    private static func cubeWithNormals(inward: Bool) -> String {
        var lines: [String] = []
        for (x, y, z) in [
            (-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1),
            (-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1),
        ] {
            lines.append("v \(x * 18) \(y * 18) \(z * 18)")
        }
        // 面の外向きの法線 (面の並びと同じ順)
        for normal in ["0 0 -1", "0 0 1", "-1 0 0", "1 0 0", "0 -1 0", "0 1 0"] {
            lines.append("vn \(normal)")
        }
        let faces = [
            [1, 4, 3, 2], [5, 6, 7, 8], [1, 5, 8, 4], [2, 3, 7, 6], [1, 2, 6, 5], [4, 8, 7, 3],
        ]
        for (index, face) in faces.enumerated() {
            let ordered = inward ? Array(face.reversed()) : face
            lines.append("f " + ordered.map { "\($0)//\(index + 1)" }.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    /// 決まった並びの乱数 (0…1)。
    private struct Dice {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 40) / Float(1 << 24)
        }
    }

    /// 半透明 (α 0.5) の置き場所の色。
    private func veil(_ red: Float, _ green: Float, _ blue: Float) -> LinearRGBA {
        LinearRGBA(
            premultipliedRed: red * 0.5, green: green * 0.5, blue: blue * 0.5, alpha: 0.5)
    }

    /// 半径 14 の保持した球 (不透明の白)。
    private func whiteBall(_ canvas: Canvas) -> Shape {
        canvas.createShape {
            canvas.noStroke()
            canvas.fill(255)
            canvas.sphere(14)
        }
    }

    /// 重なるように散らした置き場所。`z` の昇順なら奥から手前へ並ぶ。
    private func scattered(
        _ count: Int, seed: UInt64, sortedBackToFront: Bool, tinted: Bool = true
    ) -> [Placement] {
        var dice = Dice(state: seed)
        var placements: [Placement] = []
        for _ in 0..<count {
            let tint: LinearRGBA? = tinted ? veil(dice.next(), dice.next(), dice.next()) : nil
            placements.append(
                Placement(
                    x: 40 + dice.next() * 80, y: 40 + dice.next() * 80, z: -50 + dice.next() * 100,
                    fill: tint))
        }
        return sortedBackToFront ? placements.sorted { $0.z < $1.z } : placements
    }

    enum Scene: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// 奥から手前へ並べた、色の透けた置き場所 (保持した不透明の球)。
        case tintedBackToFront
        /// 順を揃えない、色の透けた置き場所。
        case tintedShuffled
        /// 光を当てた、色の透けた置き場所。
        case tintedLit
        /// 記録したときに加算にした球。
        case additive
        /// 記録したときに半透明の絵を貼った球。
        case textured
        /// 1 つの形に奥から記録した 2 つの球 (部品が 2 つ)。
        case twoParts
        /// 色の透けた置き場所と透けない置き場所が混ざる。
        case mixedTints
        /// 保持した形でなく、その場で置いた半透明の球 (組み込みの形の列)。
        case builtInSpheres
        /// 法線を書いた、巻き方が内向きの立方体のモデルを記録した形 (部品が表 → 裏の順になる)。
        case inwardModel

        var testDescription: String { rawValue }
    }

    private func place(_ scene: Scene, on canvas: Canvas) throws {
        switch scene {
        case .inwardModel:
            let model = Model.make(
                name: "cube", parsed: ModelFile.parse(Self.cubeWithNormals(inward: true)), fitting: nil)
            #expect(model.winding == .inward)
            #expect(!model.hasDerivedNormals)
            let box = canvas.createShape {
                canvas.noStroke()
                canvas.fill(255)
                canvas.model(model)
            }
            canvas.shape(box, at: scattered(60, seed: 13, sortedBackToFront: true))
        case .tintedBackToFront:
            canvas.shape(
                whiteBall(canvas), at: scattered(60, seed: 1, sortedBackToFront: true))
        case .tintedShuffled:
            canvas.shape(
                whiteBall(canvas), at: scattered(60, seed: 2, sortedBackToFront: false))
        case .tintedLit:
            canvas.lights()
            canvas.shape(
                whiteBall(canvas), at: scattered(60, seed: 3, sortedBackToFront: true))
        case .additive:
            let ball = canvas.createShape {
                canvas.noStroke()
                canvas.blendMode(.add)
                canvas.fill(96)
                canvas.sphere(14)
            }
            canvas.shape(ball, at: scattered(60, seed: 4, sortedBackToFront: true, tinted: false))
        case .textured:
            let picture = try canvas.createImage(4, 4)
            picture.fill(LinearRGBA(premultipliedRed: 0.5, green: 0.4, blue: 0.3, alpha: 0.5))
            let ball = canvas.createShape {
                canvas.noStroke()
                canvas.fill(255)
                canvas.texture(picture)
                canvas.sphere(14)
            }
            canvas.noTexture()
            canvas.shape(ball, at: scattered(60, seed: 5, sortedBackToFront: true, tinted: false))
        case .twoParts:
            let pair = canvas.createShape {
                canvas.noStroke()
                for (red, blue, z) in [(0, 255, Float(-20)), (255, 0, Float(20))] {
                    canvas.fill(red, 0, blue, 128)
                    canvas.push()
                    canvas.translate(0, 0, z)
                    canvas.sphere(14)
                    canvas.pop()
                }
            }
            canvas.shape(pair, at: scattered(40, seed: 6, sortedBackToFront: true, tinted: false))
        case .mixedTints:
            var dice = Dice(state: 7)
            var placements = scattered(60, seed: 7, sortedBackToFront: true)
            for index in placements.indices where dice.next() < 0.4 { placements[index].fill = nil }
            canvas.shape(whiteBall(canvas), at: placements)
        case .builtInSpheres:
            var dice = Dice(state: 8)
            canvas.fill(255, 200, 120, 128)
            var list: [(Float, Float, Float)] = []
            for _ in 0..<40 {
                list.append((40 + dice.next() * 80, 40 + dice.next() * 80, -50 + dice.next() * 100))
            }
            for (x, y, z) in list.sorted(by: { $0.2 < $1.2 }) {
                canvas.push()
                canvas.translate(x, y, z)
                canvas.sphere(14)
                canvas.pop()
            }
        }
    }

    // MARK: - 絵が置き場所ごとに描いたときと同じ

    @Test("畳んで描いても、置き場所ごとに描いたときと絵が変わらない", arguments: Scene.allCases)
    func sweptPicturesMatchPerPlacementPictures(_ scene: Scene) throws {
        let separate = try render(.never) { try place(scene, on: $0) }
        let swept = try render(.always) { try place(scene, on: $0) }
        #expect(litPixels(separate.picture) > 500, "場面が空 (\(litPixels(separate.picture)) 画素)")
        #expect(
            differingPixels(separate.picture, swept.picture) == 0,
            "畳んだ絵が \(differingPixels(separate.picture, swept.picture)) 画素違う")
        // 畳んだほうが描く呼び出しが少ない (畳めていることの見張り。組み込みの形は列が割れても同じ)
        #expect(swept.draws < separate.draws, "畳めていない: \(swept.draws) / \(separate.draws)")
        #expect(swept.batches == separate.batches)
    }

    // MARK: - 置き場所どうしの重なりの順 (ADR-0021 決定 2)

    /// 奥 (z = −60) に青、手前 (z = 60) に赤の半透明の保持した球。`backFirst` なら奥から置く。
    private func twoRetainedSpheres(
        backFirst: Bool, policy: SolidSweepPolicy
    ) throws -> PixelBuffer {
        try render(policy) { canvas in
            let ball = canvas.createShape {
                canvas.noStroke()
                canvas.fill(255)
                canvas.sphere(40)
            }
            let near = Placement(x: 80, y: 80, z: 60, fill: veil(1, 0, 0))
            let far = Placement(x: 80, y: 80, z: -60, fill: veil(0, 0, 1))
            canvas.shape(ball, at: backFirst ? [far, near] : [near, far])
        }.picture
    }

    @Test("奥から置いた 2 つの半透明の保持した球は、畳んでも正しく重なる (奥の球の手前の面が残る)")
    func sweptSpheresPlacedBackToFrontBlendCorrectly() throws {
        // α 0.5 の 2 層ずつ。奥の青は 2 層で 0.75、その上に手前の赤が 2 層で、赤 0.75・青 0.75 × 0.5² = 0.1875。
        // 置き場所を裏の列と表の列に並べ直すと、奥の球の手前の面が手前の球の裏面に捨てられて、
        // 奥の青が 1 層ぶんになり 0.5 × 0.5² = 0.125
        let swept = try twoRetainedSpheres(backFirst: true, policy: .always)
        let separate = try twoRetainedSpheres(backFirst: true, policy: .never)
        var wrong: [String] = []
        for point in disc(radius: 24) {
            let pixel = swept[point.x, point.y]
            if abs(pixel.red - 0.75) > 0.01 || abs(pixel.blue - 0.1875) > 0.01 {
                wrong.append("(\(point.x), \(point.y)) \(pixel)")
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) 画素が違う。最初: \(wrong.first ?? "")")
        #expect(differingPixels(swept, separate) == 0)
    }

    @Test("手前から置いた 2 つの半透明の保持した球は、畳んでも並べ替えない (奥の青は隠れたまま)")
    func sweptSpheresPlacedFrontToBackAreNotSorted() throws {
        let picture = try twoRetainedSpheres(backFirst: false, policy: .always)
        let shown = disc(radius: 24).filter { picture[$0.x, $0.y].blue > 0.02 }
        #expect(shown.isEmpty, "奥の青が \(shown.count) 画素に出た")
    }

    // MARK: - 巻き方が内向きの形 (表 → 裏の順)

    @Test("巻き方が逆の立方体を記録した形も、畳んで描くと奥の面が透ける (どちらの巻き方でも 2 層)", arguments: [false, true])
    func sweptModelsOfEitherWindingShowTheirBack(inward: Bool) throws {
        // 置き場所ごとの描き方との一致 (上の場面) は、描く順を決める部分が共通なので、順の取り違えを
        // 見つけられない。式の値 (α 0.5 の 2 層 = 0.75) で見る。内向きを外向きの順 (裏 → 表) で描くと、
        // 手前の面が先に奥行きを書いて奥の面が捨てられ、1 層 (0.5) になる
        let result = try render(.always) { canvas in
            let model = Model.make(
                name: "cube", parsed: ModelFile.parse(Self.cubeWithNormals(inward: inward)),
                fitting: nil)
            let box = canvas.createShape {
                canvas.noStroke()
                canvas.fill(255)
                canvas.model(model)
            }
            canvas.shape(
                box,
                at: [Placement(x: 80, y: 80, rotation: SIMD3(0.4, 0, 0.3), fill: self.veil(1, 1, 1))])
        }
        #expect(result.draws == 1, "畳んで描いていない")
        for point in disc(radius: 6) {
            #expect(
                abs(result.picture[point.x, point.y].red - 0.75) <= 0.01,
                "(\(point.x), \(point.y)) \(result.picture[point.x, point.y])")
        }
    }

    // MARK: - 描く呼び出しの数

    /// 色の透けた置き場所を `count` か所に置く。
    private func tintedPlacements(_ count: Int) -> [Placement] {
        scattered(count, seed: 9, sortedBackToFront: true)
    }

    @Test("畳むと、描く呼び出しは置き場所の数によらず列 1 本につき 1 回", arguments: [2, 50, 500, 3000])
    func sweptDrawsDoNotGrowWithPlacements(_ count: Int) throws {
        let result = try render(.always) { canvas in
            canvas.shape(self.whiteBall(canvas), at: self.tintedPlacements(count))
        }
        #expect(result.batches == 1)
        #expect(result.draws == 1)
    }

    @Test("畳まなければ、描く呼び出しは置き場所ごとに 2 回 (比較の基準)", arguments: [2, 50, 500])
    func separateDrawsGrowWithPlacements(_ count: Int) throws {
        let result = try render(.never) { canvas in
            canvas.shape(self.whiteBall(canvas), at: self.tintedPlacements(count))
        }
        #expect(result.batches == 1)
        #expect(result.draws == count * 2)
    }

    @Test("既定 (automatic) は、置き場所が少なければ置き場所ごと、多ければ畳む")
    func automaticSweepsOnlyWhenItPaysOff() throws {
        // 球 (既定の細かさ) を 3 か所: 畳む費用に見合わない
        let few = try render(.automatic) { canvas in
            canvas.shape(self.whiteBall(canvas), at: self.tintedPlacements(3))
        }
        #expect(few.draws == 6)
        // 細かさ 12 の球を 3000 か所: 畳む
        let many = try render(.automatic) { canvas in
            let ball = canvas.createShape {
                canvas.noStroke()
                canvas.fill(255)
                canvas.sphere(3, detail: 12)
            }
            canvas.shape(ball, at: self.tintedPlacements(3000))
        }
        #expect(many.batches == 1)
        #expect(many.draws == 1)
    }

    @Test("置き場所が 0 なら何も描かず、1 か所なら畳んでも畳まなくても同じ絵")
    func zeroAndOnePlacement() throws {
        let none = try render(.always) { canvas in
            canvas.shape(self.whiteBall(canvas), at: [])
        }
        #expect(none.draws == 0)
        #expect(litPixels(none.picture) == 0)

        let one = try render(.always) { canvas in
            canvas.shape(self.whiteBall(canvas), at: self.tintedPlacements(1))
        }
        let single = try render(.never) { canvas in
            canvas.shape(self.whiteBall(canvas), at: self.tintedPlacements(1))
        }
        #expect(one.draws == 1)
        #expect(single.draws == 2)
        #expect(differingPixels(one.picture, single.picture) == 0)
        #expect(litPixels(one.picture) > 0)
    }

    @Test("全部不透明の置き場所は、畳んでも畳まなくても 1 回")
    func opaquePlacementsDrawOnce() throws {
        for policy in [SolidSweepPolicy.never, .automatic, .always] {
            let result = try render(policy) { canvas in
                canvas.shape(
                    self.whiteBall(canvas),
                    at: self.scattered(500, seed: 10, sortedBackToFront: true, tinted: false))
            }
            #expect(result.batches == 1)
            #expect(result.draws == 1, "\(policy)")
        }
    }

    @Test("透ける置き場所と透けない置き場所が続けて並ぶ列は、連なりごとに 1 回")
    func mixedRunsDrawOncePerRun() throws {
        // 透ける 40 か所 → 透けない 40 か所 → 透ける 40 か所
        func placements() -> [Placement] {
            var list = scattered(120, seed: 11, sortedBackToFront: true)
            for index in 40..<80 { list[index].fill = nil }
            return list
        }
        let swept = try render(.always) { canvas in
            canvas.shape(self.whiteBall(canvas), at: placements())
        }
        let separate = try render(.never) { canvas in
            canvas.shape(self.whiteBall(canvas), at: placements())
        }
        #expect(swept.batches == 1)
        #expect(swept.draws == 3)
        #expect(separate.draws == 40 * 2 + 1 + 40 * 2)
        #expect(differingPixels(swept.picture, separate.picture) == 0)
    }

    @Test("印が交互に並ぶ列は、続いた分だけ畳める (置き場所ごとと同じ絵)")
    func alternatingTintsStillRenderTheSame() throws {
        func placements() -> [Placement] {
            var list = scattered(40, seed: 12, sortedBackToFront: true)
            for index in stride(from: 1, to: 40, by: 2) { list[index].fill = nil }
            return list
        }
        let swept = try render(.always) { canvas in
            canvas.shape(self.whiteBall(canvas), at: placements())
        }
        let separate = try render(.never) { canvas in
            canvas.shape(self.whiteBall(canvas), at: placements())
        }
        #expect(differingPixels(swept.picture, separate.picture) == 0)
        // 透ける置き場所 20 は 1 か所ずつ 1 回、透けない 20 は 1 か所ずつ 1 回 (どれも 1 つの連なり)
        #expect(swept.draws == 40)
        #expect(separate.draws == 20 * 2 + 20)
    }

    @Test("列が上限で割れても、列 1 本につき 1 回で、絵は置き場所ごとに描いたときと同じ")
    func splitBatchesDrawOncePerBatch() throws {
        let swept = try render(.always, capacity: 64) { canvas in
            canvas.shape(self.whiteBall(canvas), at: self.tintedPlacements(200))
        }
        let separate = try render(.never, capacity: 64) { canvas in
            canvas.shape(self.whiteBall(canvas), at: self.tintedPlacements(200))
        }
        // 64 + 64 + 64 + 8
        #expect(swept.batches == 4)
        #expect(swept.draws == 4)
        #expect(separate.draws == 200 * 2)
        #expect(differingPixels(swept.picture, separate.picture) == 0)
        #expect(litPixels(swept.picture) > 500)
    }

    @Test("部品が 2 つの形も、置き場所の数によらず 1 回で、置き場所ごとの順を保つ")
    func twoPartShapesSweepAsOne() throws {
        let swept = try render(.always) { try place(.twoParts, on: $0) }
        let separate = try render(.never) { try place(.twoParts, on: $0) }
        #expect(swept.draws == 1)
        // 部品 2 つ × 裏と表 × 40 か所
        #expect(separate.draws == 40 * 4)
        #expect(differingPixels(swept.picture, separate.picture) == 0)
    }

    @Test("形から求めた向きを持つ頂点の形は、畳まずに置き場所ごとに描く (光の当たり方が変わるため)")
    func derivedNormalShapesAreNotSwept() throws {
        // 法線を書いていない OBJ (向きを形から求める) を、保持した形に記録する
        let model = Model.make(
            name: "cube",
            parsed: ModelFile.parse(
                "v -9 -9 -9\nv 9 -9 -9\nv 9 9 -9\nv -9 9 -9\nv -9 -9 9\nv 9 -9 9\nv 9 9 9\nv -9 9 9\n"
                    + "f 1 4 3 2\nf 5 6 7 8\nf 1 5 8 4\nf 2 3 7 6\nf 1 2 6 5\nf 4 8 7 3"),
            fitting: nil)
        func scene(_ canvas: Canvas) {
            let box = canvas.createShape {
                canvas.noStroke()
                canvas.fill(255)
                canvas.model(model)
            }
            canvas.lights()
            canvas.shape(box, at: self.tintedPlacements(20))
        }
        let swept = try render(.always, scene)
        let separate = try render(.never, scene)
        #expect(swept.draws == separate.draws)
        #expect(swept.draws == 40)
        #expect(differingPixels(swept.picture, separate.picture) == 0)
        #expect(litPixels(swept.picture) > 200)
    }
}
