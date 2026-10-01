// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import simd

/// GPU で帯と角へ広げる骨。形の数ではなく稜線の数だけを持つ (#1738)。
/// 列が所有するので、控えから外れても投入が読み終わるまで生きる。
@MainActor final class SolidStrokeGeometry {
    /// 片 1 つ。頂点関数 (`solidStrokeVertexMain`) が 6 頂点 (2 枚の三角形) に広げる。
    ///
    /// - 帯 (`a.w` = 0): `a`・`b` が両端
    /// - 点の半分 (`a.w` = 2): `a` が点。`b.x` は点の記録の位置、`b.y` は 2 枚のどちらか (0 と 1)、
    ///   `b.z` は端の円板を置く容量を持つか (1 なら持つ)。網の点ごとに 2 枚を置き、頂点関数が
    ///   点の記録から形を決める (``Canvas/screenCorner(arms:origins:isEnd:join:cap:)``・#1889・#1893)。
    ///   折れ目は二等分線で割った 2 枚で埋める (#1644)。`b.y` は、2 本が同じ向きへ折り返す角でだけ、
    ///   外側の縁を左右へ分けるのにも読む。出っ張らせる端と向きの無い点の正方形は 1 枚目だけが置く
    /// - 円板の 8 分の 1 (`a.w` = 3): `a` が点、`b.x` が点の記録の位置、`b.y` が何番目か (0…7)。
    ///   画面で重なる点の腕を 1 本と数え、丸い端を置く点 (同じ平面に載る 4 点・``Canvas/mayMeetAsOneBand(_:_:_:_:)``)
    ///   にだけ置く。円板は 16 枚の三角形で、CPU の `appendSolidDisc` と同じ角の並びである
    ///
    /// **点の記録は片の後ろに積む** (同じ置き場を `float4` の並びとして読む)。点 i の記録は
    /// `(点 i の位置, 辺の数)` に続けて、隣ごとに `(隣の位置, 隣の記録の位置)` を辺の順に並べる。
    /// 画面で潰れた辺の先の点 (隣) の隣まで引けるので、画面で重なる 2 点を 1 点として形を置ける。
    /// 位置は `float4` の並びでの番号で、片 1 つは 3 つ分を占める。
    struct Piece {
        var a: SIMD4<Float>
        var b: SIMD4<Float>
        var c: SIMD4<Float> = .zero
    }

    let buffer: any MTLBuffer
    let count: Int
    private let gpu: RenderDevice

    /// 網から骨を作る。**作れなければ `nil`** — 呼ぶ側は CPU の帯へ戻る。
    ///
    /// - 開いた端 (辺が 1 本だけ来る点) を持つ網。端の形は CPU の規則へ残す。潰れた組み込みの形も
    ///   ここで戻れる
    /// - 同じ直線に載る 2 本の辺が集まる点を持つ網。視線をその直線に沿わせると、潰れた辺が 2 本
    ///   続いて 3 点が画面で重なる。頂点関数は潰れた辺の先を 1 段しか引かないので、CPU の骨
    ///   (`strokeNet` は群を何段でもまとめる) へ戻す。組み込みの立体の稜線には無い
    init?(net: SolidEdges, gpu: RenderDevice) throws(RenderFailure) {
        let shared = SolidStrokeNet(points: net.points, edges: net.edges)
        let points = net.points.indices
        guard !net.edges.isEmpty, points.allSatisfy({ shared.degree(of: $0) != 1 }),
            !Self.hasStraightPair(shared)
        else { return nil }
        let corners = points.filter { shared.degree(of: $0) > 0 }
        let discs = corners.filter { shared.mayEndAsOneBand($0) }
        let pieceCount = net.edges.count + corners.count * 2 + discs.count * 8
        // 点の記録の位置 (`float4` の並びでの番号)
        var records = [Int](repeating: 0, count: net.points.count)
        var cursor = pieceCount * 3
        for index in corners {
            records[index] = cursor
            cursor += 1 + shared.degree(of: index)
        }
        var pieces: [Piece] = []
        pieces.reserveCapacity(pieceCount)
        for (a, b) in net.edges {
            pieces.append(Piece(a: SIMD4(net.points[a], 0), b: SIMD4(net.points[b], 0)))
        }
        let roundEnds = Set(discs)
        for index in corners {
            let record = Float(records[index])
            let capable: Float = roundEnds.contains(index) ? 1 : 0
            pieces.append(Piece(a: SIMD4(net.points[index], 2), b: SIMD4(record, 0, capable, 0)))
            pieces.append(Piece(a: SIMD4(net.points[index], 2), b: SIMD4(record, 1, capable, 0)))
        }
        for index in discs {
            for part in 0..<8 {
                pieces.append(
                    Piece(a: SIMD4(net.points[index], 3), b: SIMD4(Float(records[index]), Float(part), 0, 0)))
            }
        }
        var words: [SIMD4<Float>] = []
        words.reserveCapacity(cursor - pieceCount * 3)
        for index in corners {
            words.append(SIMD4(net.points[index], Float(shared.degree(of: index))))
            for neighbor in shared.neighbors(of: index) {
                words.append(SIMD4(net.points[neighbor], Float(records[neighbor])))
            }
        }
        self.gpu = gpu
        count = pieces.count * 6
        let pieceBytes = pieces.count * MemoryLayout<Piece>.stride
        buffer = try gpu.makeReadableBuffer(
            byteCount: pieceBytes + words.count * MemoryLayout<SIMD4<Float>>.stride)
        pieces.withUnsafeBytes { bytes in
            buffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        words.withUnsafeBytes { bytes in
            (buffer.contents() + pieceBytes).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }

    /// 同じ直線に載る 2 本の辺が集まる点を持つか。傾きの差は稜線の「同じ平面」と同じ許容差で見る
    /// (``SolidEdges/coplanarAngle``)。
    private static func hasStraightPair(_ net: SolidStrokeNet) -> Bool {
        let threshold = Float(sin(SolidEdges.coplanarAngle))
        for index in net.points.indices {
            let neighbors = net.neighbors(of: index)
            for (offset, first) in neighbors.enumerated() {
                let a = net.points[first] - net.points[index]
                for second in neighbors.dropFirst(offset + 1) {
                    let b = net.points[second] - net.points[index]
                    if length(cross(a, b)) <= threshold * length(a) * length(b) { return true }
                }
            }
        }
        return false
    }

    isolated deinit { gpu.retire(buffer) }
}
/// 形を置いた時点の変換・線・視点。既存の列ごとの256バイトの区画へ収まる。
/// 影も画面と同じ帯を焼くので、光の視点ではなく描いた時点の視点を持つ。
struct SolidStrokePlacement {
    var matrix: simd_float4x4
    var eye: SIMD4<Float>
    var right: SIMD4<Float>
    var down: SIMD4<Float>
    var forward: SIMD4<Float>
    var parameters: SIMD4<Float>  // 太さ、2*tan(fov/2) または世界での幅、near、高さ
    var color: SIMD4<Float>
    var uv: SIMD4<Float>  // xy: 白い区画、z: 球の骨を元の半径へ戻す倍率、w: 端の形 (``capCode(_:)``)

    init(
        matrix: simd_float4x4, camera: Camera, height: Float, weight: Float, cap: StrokeCap,
        color: LinearRGBA, uv: SIMD2<Float>, geometryScale: Float
    ) {
        self.matrix = matrix
        right = SIMD4(camera.right, 0)
        down = SIMD4(camera.down, 0)
        forward = SIMD4(camera.forward, 0)
        switch camera.projection {
        case .perspective(let fov, _, let near, _):
            eye = SIMD4(camera.eye, 1)
            parameters = SIMD4(weight, 2 * tan(fov / 2), near, height)
        case .orthographic(_, _, let bottom, let top, _, _):
            eye = SIMD4(camera.eye, 0)
            parameters = SIMD4(weight, abs(bottom - top), 0, height)
        }
        self.color = SIMD4(color.red, color.green, color.blue, color.alpha)
        self.uv = SIMD4(uv.x, uv.y, geometryScale, Self.capCode(cap))
    }

    /// 端の形の番号。頂点関数 (`solidStrokeCornerShape`) が読む。画面で重なる点の腕を 1 本と
    /// 数えた角 (端) にだけ効く — 組み込みの立体の閉じた稜線は、ほかに端を持たない (#1893)。
    static func capCode(_ cap: StrokeCap) -> Float {
        switch cap {
        case .round: 0
        case .square: 1
        case .project: 2
        }
    }
}

extension Canvas {
    /// 頂点の並びだけを共有する鍵。色と変換は置き場所が持つ。
    struct SolidMeshRangeKey: Hashable {
        var source: SolidSource
        var isDerived: Bool
        var textured: Bool
        var whiteUV: SIMD2<Float>
    }

    /// いまのスタイルが、組み込みの形の線を GPU で広げてよいものか。**記録の間かどうかは見ない**
    /// — その場で描くとき (``placeGPUStroke(of:mesh:)``) と、保持した形に覚えるとき
    /// (`rememberGPUStroke`) の 2 か所が同じ条件を読む。
    func gpuStrokeStyleAllows(_ source: SolidSource) -> Bool {
        guard case .mesh = source else { return false }
        return currentShader == nil && style.stroke.alpha == 1 && style.strokeJoin == .miter
            && style.blendMode == .blend && style.picture == nil
    }

    /// 既定の不透明な線だけを GPU で広げる。列を並べ替えず、既存の列の開閉を通す。
    func placeGPUStroke(of source: SolidSource, mesh: () -> SolidMesh) -> Bool {
        guard !recordingShape, gpuStrokeStyleAllows(source),
            let (geometry, geometryScale) = gpuStrokeGeometry(of: source, mesh: mesh)
        else { return false }
        openGPUStroke(
            of: source, geometry: geometry, matrix: transform.matrix, weight: style.strokeWeight,
            cap: style.strokeCap, color: style.stroke, uv: whiteUV, geometryScale: geometryScale)
        return true
    }

    /// 組み込みの形の稜線を GPU で広げる骨と、骨を元の寸法へ戻す倍率。**作れなければ `nil`**
    /// — 呼ぶ側は CPU の帯へ戻る (開いた端の形・溶接の計算範囲の端にある球・置き場を
    /// 確保できないとき)。
    func gpuStrokeGeometry(
        of source: SolidSource, mesh: () -> SolidMesh
    ) -> (SolidStrokeGeometry, Float)? {
        let key: SolidSource
        let geometryScale: Float
        if case .mesh(.sphere(let radius, let detail)) = source {
            let tolerance = radius * SolidEdges.weldScale
            guard tolerance >= Float.leastNormalMagnitude,
                tolerance <= sqrt(Float.greatestFiniteMagnitude) / 4
            else { return nil }
            key = .mesh(.sphere(radius: 1, detail: detail))
            geometryScale = radius
        } else {
            key = source
            geometryScale = 1
        }
        if let cached = solidStrokeGeometry[key] { return (cached, geometryScale) }
        do {
            let net: SolidEdges
            if key != source, case .mesh(let shape) = key {
                net = solidEdges(of: key) { shape.make() }
            } else {
                net = solidEdges(of: source, mesh: mesh)
            }
            guard let made = try SolidStrokeGeometry(net: net, gpu: gpu) else { return nil }
            solidStrokeGeometry.insert(made, for: key)
            return (made, geometryScale)
        } catch {
            // 控えを確保できなければ従来の組み立てへ戻す。描画自体の失敗は従来側が伝える。
            return nil
        }
    }

    /// GPU で広げる線の列を 1 つ開く。**前の列は閉じる** — 呼んだ順に重ねる。
    ///
    /// 列は次の操作で閉じる (塗りの列を開くときも、この列には足さない)。視点は置く時点の
    /// もので、変換・太さ・色・白い区画は呼ぶ側が決める (その場で描くならいまのスタイル、
    /// 保持した形なら記録したもの)。
    func openGPUStroke(
        of source: SolidSource, geometry: SolidStrokeGeometry, matrix: simd_float4x4,
        weight: Float, cap: StrokeCap, color: LinearRGBA, uv: SIMD2<Float>, geometryScale: Float
    ) {
        beginSolids()
        closeBatch()
        let placement = SolidStrokePlacement(
            matrix: matrix, camera: currentCamera, height: height, weight: weight, cap: cap,
            color: color, uv: uv, geometryScale: geometryScale)
        openSolid = OpenSolid(
            source: source, vertexStart: 0, vertexCount: geometry.count,
            indexStart: nil, instanceStart: solidInstances.count,
            strokeGeometry: geometry, strokePlacement: placement)
        solidInstances.append(.identity)
    }
}
