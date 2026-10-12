// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 性能レビュー (#1744) の再検証 G1Drawing の計測の下書き。**コンパイルされない場所に置く。**
// 対象: #2364 #2366 #2380 #2384 #2385 #2386 と、#939 材料 2 の再開条件。
//
// 測るのは「いまの費用の大きさ」で、前後比較ではない。1 フレームを次の 3 つに分けて測る:
//
// - place  : `draw {}` の閉包の中 (図形を置く・列を閉じる CPU)
// - submit : 閉包を抜けてから `draw` が返るまで (写し・列ごとの値・エンコード・投入の CPU)
// - wall   : 置き始めから GPU の決着 (`settle()`) まで
//
// `wall − place − submit` を GPU の仕事の目安 (gpuish) として併記する (GPU 時間の口は無い)。
// 各フレームの前に `settle()` するので、環の待ち (slot / ring) は入らない想定 — 入ったら
// `slotWaits` / `ringWaits` の差分が 0 でなくなるので、それも出す。
//
// 出力は `PERF\t<Issue>\t<場面>\t<指標>\t<値>\t<単位>` の 1 行形式。

import Foundation
import Metal
import Testing

@testable import MokumeCore

@Suite("PerfReview G1Drawing", .serialized, .enabled(if: RenderDevice.isAvailable, "GPU が無い"))
struct PerfReviewG1Drawing {

    // MARK: - 計測の道具

    struct Sample {
        var place: Duration
        var submit: Duration
        var wall: Duration
    }

    static func ms(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1_000 + Double(c.attoseconds) / 1e15
    }

    static func stats(_ values: [Double]) -> (median: Double, p90: Double, min: Double) {
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        let p90 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.9).rounded(.up)) - 1)]
        return (median, p90, sorted.first ?? .nan)
    }

    static func emit(_ issue: Int, _ scene: String, _ metric: String, _ value: Double, _ unit: String) {
        print("PERF\t\(issue)\t\(scene)\t\(metric)\t\(String(format: "%.4f", value))\t\(unit)")
    }

    static func emit(_ issue: Int, _ scene: String, _ metric: String, _ value: Int, _ unit: String) {
        print("PERF\t\(issue)\t\(scene)\t\(metric)\t\(value)\t\(unit)")
    }

    /// 1 フレームを測る。前のフレームの GPU を待ってから始める。
    static func frame(
        _ canvas: Canvas, _ gpu: RenderDevice, _ body: (Canvas) -> Void
    ) throws -> Sample {
        let clock = ContinuousClock()
        try gpu.settle()
        let start = clock.now
        var bodyEnd = start
        try canvas.draw {
            body(canvas)
            bodyEnd = clock.now
        }
        let submitted = clock.now
        try gpu.settle()
        let settled = clock.now
        return Sample(place: bodyEnd - start, submit: submitted - bodyEnd, wall: settled - start)
    }

    /// 暖機 3 回の後に `runs` 回測り、中央値・p90・最小と、最後のフレームの計数を出す。
    /// 閉包の 2 つめの引数はフレームの通し番号 (寸法を毎フレーム動かす場面が使う)。
    static func run(
        issue: Int, scene: String, canvas: Canvas, gpu: RenderDevice, runs: Int = 20,
        _ body: @escaping (Canvas, Int) -> Void
    ) throws {
        var frameIndex = 0
        for _ in 0..<3 {
            _ = try frame(canvas, gpu) { body($0, frameIndex) }
            frameIndex += 1
        }
        let slotBefore = gpu.slotWaits
        let ringBefore = gpu.ringWaits
        let meshesBefore = canvas.solidMeshesBuilt
        let strokeBefore = canvas.solidStrokeGeometry.made
        let edgesBefore = canvas.solidEdges.made
        var samples: [Sample] = []
        for _ in 0..<runs {
            samples.append(try frame(canvas, gpu) { body($0, frameIndex) })
            frameIndex += 1
        }
        let place = stats(samples.map { ms($0.place) })
        let submit = stats(samples.map { ms($0.submit) })
        let wall = stats(samples.map { ms($0.wall) })
        let gpuish = stats(samples.map { ms($0.wall - $0.place - $0.submit) })
        for (name, s) in [("place", place), ("submit", submit), ("wall", wall), ("gpuish", gpuish)] {
            emit(issue, scene, "\(name).median", s.median, "ms")
            emit(issue, scene, "\(name).p90", s.p90, "ms")
            emit(issue, scene, "\(name).min", s.min, "ms")
        }
        emit(issue, scene, "batches", canvas.drawCallsInLastFrame, "count")
        emit(issue, scene, "drawsEncoded", canvas.drawsEncodedInLastFrame, "count")
        emit(issue, scene, "flatVertices", canvas.flatVerticesInLastFrame, "count")
        emit(issue, scene, "slotWaits", gpu.slotWaits - slotBefore, "count")
        emit(issue, scene, "ringWaits", gpu.ringWaits - ringBefore, "count")
        emit(
            issue, scene, "solidMeshesBuilt.perFrame",
            Double(canvas.solidMeshesBuilt - meshesBefore) / Double(runs), "count")
        emit(
            issue, scene, "strokeGeometryMade.perFrame",
            Double(canvas.solidStrokeGeometry.made - strokeBefore) / Double(runs), "count")
        emit(
            issue, scene, "solidEdgesMade.perFrame",
            Double(canvas.solidEdges.made - edgesBefore) / Double(runs), "count")
    }

    static func device() -> String { MTLCreateSystemDefaultDevice()?.name ?? "?" }

    // MARK: - #2364 列ごとの固定費

    /// 列 1 本あたりの固定費 (CPU) を、列の数だけを変えて差で測る。
    ///
    /// 同じ数の矩形を (a) 全部同じ旗 (塗りだけ) で置く = 列 1 本、(b) 塗りだけと輪郭だけを交互に置く
    /// = 列 N 本 (`beginForm` が旗の違いで閉じる)。図形 1 つあたりの費用はほぼ同じなので、
    /// `(b − a) / (N − 1)` が列 1 本の固定費 (閉じる・列ごとの値の 5 本・エンコード約 20 回・
    /// 走査ごとの `Batch` の写し) の目安になる。N を 3 段に振って線形かを見る。
    /// 輪郭の図形は塗りより断片が重いので、gpuish の差は固定費ではなく断片の差を含む (CPU だけを読む)。
    @Test("2364: 列 1 本あたりの CPU の固定費 (基本図形の列を N 本)")
    func perBatchFixedCost() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 1024, height: 768)
        Self.emit(2364, "env", "device:\(Self.device())", 0, "-")
        Self.emit(2364, "env", "Batch.size", MemoryLayout<Canvas.Batch>.size, "B")
        Self.emit(2364, "env", "Batch.stride", MemoryLayout<Canvas.Batch>.stride, "B")
        Self.emit(2364, "env", "SolidStrokePlacement.stride", MemoryLayout<SolidStrokePlacement>.stride, "B")
        Self.emit(2364, "env", "FlatFrame.stride", MemoryLayout<FlatFrame>.stride, "B")
        Self.emit(2364, "env", "Lighting.stride", MemoryLayout<Lighting>.stride, "B")
        Self.emit(2364, "env", "PackedMaterial.stride", MemoryLayout<PackedMaterial>.stride, "B")
        Self.emit(2364, "env", "PackedSurroundings.stride", MemoryLayout<PackedSurroundings>.stride, "B")
        for count in [1_000, 5_000, 20_000] {
            // (a) 列 1 本
            try Self.run(issue: 2364, scene: "rects\(count).oneBatch", canvas: canvas, gpu: gpu) { c, _ in
                c.background(0)
                c.fill(200)
                c.noStroke()
                for i in 0..<count {
                    c.rect(Float(i % 100) * 10, Float(i / 100 % 76) * 10, 4, 4)
                }
            }
            // (b) 列 N 本 (塗りだけ ↔ 輪郭だけ を交互)
            try Self.run(issue: 2364, scene: "rects\(count).alternating", canvas: canvas, gpu: gpu) { c, _ in
                c.background(0)
                for i in 0..<count {
                    if i.isMultiple(of: 2) {
                        c.fill(200)
                        c.noStroke()
                    } else {
                        c.noFill()
                        c.stroke(200)
                    }
                    c.rect(Float(i % 100) * 10, Float(i / 100 % 76) * 10, 4, 4)
                }
            }
        }
    }

    // MARK: - #2385 塗り + 線の立体が図形ごとに列 2 本

    /// `box()` 1 万個を 3 つのスタイルで置き、列の数・CPU・決着までを並べる。
    /// 光あり (列ごとに光の配列を追記する `bakeActiveLights`) も足す。#1796 の noFill の基準にもなる。
    @Test("2385: box() 1 万個 (塗り+線 / noFill / noStroke、光なし・あり)")
    func tenThousandBoxes() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 1024, height: 768)
        enum Style: String, CaseIterable { case fillAndStroke, noFill, noStroke }
        for lit in [false, true] {
            for style in Style.allCases {
                try Self.run(
                    issue: 2385, scene: "box10k.\(style.rawValue).\(lit ? "lit" : "unlit")",
                    canvas: canvas, gpu: gpu, runs: 15
                ) { c, _ in
                    c.background(0)
                    if lit { c.lights() }
                    c.fill(200)
                    c.stroke(30)
                    c.strokeWeight(1)
                    switch style {
                    case .fillAndStroke: break
                    case .noFill: c.noFill()
                    case .noStroke: c.noStroke()
                    }
                    for i in 0..<10_000 {
                        c.push()
                        c.translate(12 + Float(i % 100) * 10, 12 + Float(i / 100) * 7.5, 0)
                        c.box(5)
                        c.pop()
                    }
                }
            }
        }
    }

    // MARK: - #2386 寸法がメッシュの鍵

    /// 箱 1,000 個を (a) 同じ寸法 (b) 寸法が全部違うが毎フレーム同じ (c) 寸法が毎フレーム動く、で置く。
    /// 塗りだけと塗り + 線の両方。球 (線の骨だけは半径を鍵から外してある・#1606) を参照に並べる。
    ///
    /// (c) の塗り + 線は、線の骨 (`SolidStrokeGeometry`・GPU の置き場を確保する) と稜線の溶接
    /// (`solidEdges`) も寸法ごとに作り直す見込み — `strokeGeometryMade.perFrame` と
    /// `solidEdgesMade.perFrame` で数える。
    @Test("2386: 寸法の違う box() 1,000 個 (固定・毎フレーム変化、塗りだけ・線あり)")
    func thousandBoxesOfDifferentSizes() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 1024, height: 768)
        enum Sizing: String, CaseIterable { case same, distinctStatic, distinctAnimated }
        for stroked in [false, true] {
            for sizing in Sizing.allCases {
                try Self.run(
                    issue: 2386, scene: "box1k.\(sizing.rawValue).\(stroked ? "stroked" : "noStroke")",
                    canvas: canvas, gpu: gpu, runs: 15
                ) { c, frameIndex in
                    c.background(0)
                    c.lights()
                    c.fill(200)
                    if stroked { c.stroke(30) } else { c.noStroke() }
                    for i in 0..<1_000 {
                        let size: Float =
                            switch sizing {
                            case .same: 12
                            case .distinctStatic: 8 + Float(i) * 0.01
                            case .distinctAnimated: 8 + Float(i) * 0.01 + Float(frameIndex) * 0.001
                            }
                        c.push()
                        c.translate(20 + Float(i % 40) * 25, 20 + Float(i / 40) * 28, 0)
                        c.box(size, size * 0.8, size * 1.2)
                        c.pop()
                    }
                }
            }
            // 参照: 半径の違う球 (塗りは寸法ごとに頂点、線は単位球の骨を共有する)
            try Self.run(
                issue: 2386, scene: "sphere1k.distinctStatic.\(stroked ? "stroked" : "noStroke")",
                canvas: canvas, gpu: gpu, runs: 15
            ) { c, _ in
                c.background(0)
                c.lights()
                c.fill(200)
                if stroked { c.stroke(30) } else { c.noStroke() }
                for i in 0..<1_000 {
                    c.push()
                    c.translate(20 + Float(i % 40) * 25, 20 + Float(i / 40) * 28, 0)
                    c.sphere(6 + Float(i) * 0.005, detail: 12)
                    c.pop()
                }
            }
        }
    }

    // MARK: - #2366 不透明な立体がブレンド有効のパイプライン

    /// 光を当てた不透明な箱の格子を奥行き方向に重ね、**奥から手前**と**手前から奥**の 2 つの順で描く。
    ///
    /// 隠面除去 (HSR) が効いていれば、描く順によらず見える層だけが断片を走らせるので 2 つは
    /// ほぼ同じになる。ブレンド有効のパイプラインでは早期の奥行き判定 (描いた順) しか効かないので、
    /// 奥から手前の順で層の数だけ断片が増える。**2 つの差が、不透明なパイプラインで取り戻せる量の
    /// 目安**になる (手前から奥の順は既に early-Z でほぼ最小)。層 1 枚だけの場面も並べ、層 1 枚あたりの
    /// 断片の費用を出す。
    ///
    /// 塗りだけ・同じ寸法なので 1 列 (インスタンスの順 = 置いた順) に畳まれる。影ありも足す
    /// (断片の PCF が重くなり、差が開く見込み)。
    @Test("2366: 光を当てた重なりの多い箱の格子 (奥→手前 / 手前→奥 / 層 1 枚)")
    func overlappingLitGrid() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 1920, height: 1080)
        let layers = 12
        enum Order: String, CaseIterable { case backToFront, frontToBack, nearestOnly }
        for shadowed in [false, true] {
            for order in Order.allCases {
                try Self.run(
                    issue: 2366,
                    scene: "grid16x9x\(layers).\(order.rawValue).\(shadowed ? "shadows" : "noShadows")",
                    canvas: canvas, gpu: gpu
                ) { c, _ in
                    c.background(0)
                    if shadowed { c.shadows(true) }
                    c.lights()
                    c.pointLight(120, 100, 80, 400, 300, 300)
                    c.pointLight(80, 100, 120, 1500, 800, 300)
                    c.noStroke()
                    c.fill(200, 180, 160)
                    let layerOrder: [Int] =
                        switch order {
                        case .backToFront: Array(0..<layers)  // 奥 (z が小さい) から
                        case .frontToBack: Array((0..<layers).reversed())
                        case .nearestOnly: [layers - 1]
                        }
                    for layer in layerOrder {
                        let z = -Float(layers - 1 - layer) * 150
                        for row in 0..<9 {
                            for column in 0..<16 {
                                c.push()
                                c.translate(60 + Float(column) * 120, 60 + Float(row) * 120, z)
                                c.box(110)
                                c.pop()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - #2380 GPU で広げる立体の線の頂点段

    /// 細かい球のワイヤーフレーム。**画面に小さく置いて断片をほぼ消し、頂点段を律速にする。**
    /// 細かさを振って、頂点の数 (骨の `count` = 片 × 6) に比例するかを見る。大きく置いた場面も並べる。
    /// 骨の内訳 (円板の片を持つか) も出す — 円板を持つ点は 1 点の角の形を 60 頂点で解き直す。
    @Test("2380: 細かい球のワイヤーフレーム (細かさ 16 / 48 / 128、小さく・大きく)")
    func fineSphereWireframes() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 1024, height: 768)
        for detail in [16, 48, 128] {
            for radius: Float in [3, 120] {
                let count = 20
                try Self.run(
                    issue: 2380, scene: "sphereWire.d\(detail).r\(Int(radius)).x\(count)",
                    canvas: canvas, gpu: gpu, runs: 15
                ) { c, _ in
                    c.background(0)
                    c.noFill()
                    c.stroke(255)
                    c.strokeWeight(1)
                    for i in 0..<count {
                        c.push()
                        c.translate(100 + Float(i % 5) * 200, 120 + Float(i / 5) * 160, 0)
                        c.sphere(radius, detail: detail)
                        c.pop()
                    }
                }
            }
            if let geometry = canvas.solidStrokeGeometry[.mesh(.sphere(radius: 1, detail: detail))] {
                Self.emit(2380, "sphereWire.d\(detail)", "verticesPerSphere", geometry.count, "count")
                Self.emit(2380, "sphereWire.d\(detail)", "placesRoundEnds", geometry.placesRoundEnds ? 1 : 0, "bool")
                Self.emit(2380, "sphereWire.d\(detail)", "bufferBytes", geometry.buffer.length, "B")
            } else {
                Self.emit(2380, "sphereWire.d\(detail)", "gpuStrokeGeometry", 0, "missing")
            }
            // 参照: 同じ球の塗り (solidVertexMain・1 列に畳まれる)
            try Self.run(
                issue: 2380, scene: "sphereFill.d\(detail).r3.x20", canvas: canvas, gpu: gpu, runs: 15
            ) { c, _ in
                c.background(0)
                c.noStroke()
                c.fill(200)
                for i in 0..<20 {
                    c.push()
                    c.translate(100 + Float(i % 5) * 200, 120 + Float(i / 5) * 160, 0)
                    c.sphere(3, detail: detail)
                    c.pop()
                }
            }
        }
    }

    // MARK: - #939 材料 2 (頂点の帯域が律速か)

    /// 同じ頂点の形式 (`SolidVertex` 96 B) で、(a) キャッシュに載る大きさの頂点を何度も読む場面と、
    /// (b) キャッシュに載らない大きさの頂点を読む場面で、頂点 1 つあたりの GPU の目安時間を比べる。
    /// どちらも画面に小さく置いて断片を消す。(b) が (a) より頂点あたり明らかに遅ければ、頂点の
    /// 取り込みが DRAM の帯域で律速している = 材料 2 (頂点を縮める) の再開条件に当たる。
    ///
    /// (a) 細かさ 128 の球 (1 個 ≒ 49k 頂点 ≒ 4.7 MB) を 100 個 (同じ半径 = 1 列のインスタンス)
    /// (b) 読み込んだモデル (約 60 万頂点 ≒ 58 MB・`modelFills` の GPU 置き場) を 8 回置く
    @Test("939: 立体の頂点の取り込みが帯域で律速か (球のインスタンス / 大きなモデル)")
    func vertexBandwidth() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 1024, height: 768)
        Self.emit(939, "env", "SolidVertex.stride", MemoryLayout<SolidVertex>.stride, "B")
        try Self.run(issue: 939, scene: "sphereFill.d128.r2.x100", canvas: canvas, gpu: gpu, runs: 15) { c, _ in
            c.background(0)
            c.noStroke()
            c.fill(200)
            for i in 0..<100 {
                c.push()
                c.translate(40 + Float(i % 10) * 90, 40 + Float(i / 10) * 70, 0)
                c.sphere(2, detail: 128)
                c.pop()
            }
        }
        if let mesh = canvas.solidMeshes[.sphere(radius: 2, detail: 128)] {
            Self.emit(939, "sphereFill.d128.r2.x100", "vertexInvocations", 100 * mesh.points.count, "count")
        }

        // 大きなモデル: 400 × 250 の格子 = 20 万三角形 = 60 万頂点 (溜め場ではなく GPU の置き場へ)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf-g1-grid.obj")
        var text = "# perf grid\n"
        let (nx, ny) = (401, 251)
        for y in 0..<ny {
            for x in 0..<nx {
                let fx = Float(x) / Float(nx - 1)
                let fy = Float(y) / Float(ny - 1)
                text += "v \(fx) \(fy) \(0.05 * sin(fx * 40) * cos(fy * 30))\n"
            }
        }
        for y in 0..<(ny - 1) {
            for x in 0..<(nx - 1) {
                let a = y * nx + x + 1
                text += "f \(a) \(a + 1) \(a + nx + 1)\nf \(a) \(a + nx + 1) \(a + nx)\n"
            }
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        let model = try canvas.loadModel(url.path)
        try Self.run(issue: 939, scene: "model600k.r4.x8", canvas: canvas, gpu: gpu, runs: 15) { c, _ in
            c.background(0)
            c.noStroke()
            c.fill(200)
            for i in 0..<8 {
                c.push()
                c.translate(100 + Float(i) * 110, 380, 0)
                c.scale(4, 4, 4)
                c.model(model)
                c.pop()
            }
        }
        Self.emit(939, "model600k.r4.x8", "vertexInvocations(est)", 8 * 400 * 250 * 6, "count")
        Self.emit(939, "model600k", "modelFillsTotal", canvas.modelFills.total, "B")
    }

    // MARK: - #2384 扇形

    /// 扇形 1 万個と、同じ大きさの楕円 1 万個・矩形 1 万個を同じ場面で描き、決着までを比べる。
    /// 扇形と楕円の差が「扇形の距離場 (毎画素の cos / sin 4 回・線分 2 本)」の上限の目安。
    /// 塗りだけと塗り + 輪郭 (扇の距離場を 2 回 = 三角関数 8 回) の両方。
    /// 大きく重ねて断片律速にする (直径 80・1920×1080)。
    @Test("2384: 扇形 1 万個 (対 楕円・矩形、塗りだけ / 塗り+輪郭)")
    func tenThousandArcs() throws {
        let gpu = try RenderDevice()
        let canvas = try CanvasFixture.make(gpu: gpu, width: 1920, height: 1080)
        enum Kind: String, CaseIterable { case arc, ellipse, rect }
        for stroked in [false, true] {
            for kind in Kind.allCases {
                try Self.run(
                    issue: 2384, scene: "\(kind.rawValue)10k.d80.\(stroked ? "fillStroke" : "fill")",
                    canvas: canvas, gpu: gpu
                ) { c, _ in
                    c.background(0)
                    c.fill(200, 120, 60)
                    if stroked {
                        c.stroke(255)
                        c.strokeWeight(3)
                    } else {
                        c.noStroke()
                    }
                    for i in 0..<10_000 {
                        let x = Float(i % 125) * 15.3
                        let y = Float(i / 125) * 13.4
                        switch kind {
                        case .arc:
                            let start = Float(i % 17) * 0.37
                            c.arc(x, y, 80, 80, start, start + 4.2)
                        case .ellipse: c.ellipse(x, y, 80, 80)
                        case .rect: c.rect(x - 40, y - 40, 80, 80)
                        }
                    }
                }
            }
        }
    }
}
