// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import simd

/// GPU で帯と角へ広げる骨。形の数ではなく稜線の数だけを持つ (#1738)。
/// 列が所有するので、控えから外れても投入が読み終わるまで生きる。
@MainActor final class SolidStrokeGeometry {
    struct Piece {
        var a: SIMD4<Float>  // xyz: 端点 / 中心、w: 0 は帯、1 は正方形
        var b: SIMD4<Float>
    }

    let buffer: any MTLBuffer
    let count: Int
    private let gpu: RenderDevice

    init?(net: SolidEdges, gpu: RenderDevice) throws(RenderFailure) {
        var degrees = [Int](repeating: 0, count: net.points.count)
        var pieces: [Piece] = []
        for (a, b) in net.edges {
            pieces.append(Piece(a: SIMD4(net.points[a], 0), b: SIMD4(net.points[b], 0)))
            degrees[a] += 1
            degrees[b] += 1
        }
        // 開いた端の形は CPU の規則へ残す。潰れた組み込みの形もここで戻れる。
        guard !pieces.isEmpty, !degrees.contains(1) else { return nil }
        for (index, degree) in degrees.enumerated() where degree > 1 {
            pieces.append(Piece(a: SIMD4(net.points[index], 1), b: .zero))
        }
        self.gpu = gpu
        count = pieces.count * 6
        buffer = try gpu.makeReadableBuffer(byteCount: pieces.count * MemoryLayout<Piece>.stride)
        pieces.withUnsafeBytes { bytes in
            buffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
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
    var uv: SIMD4<Float>  // xy: 白い区画、z: 球の骨を元の半径へ戻す倍率

    init(
        matrix: simd_float4x4, camera: Camera, height: Float, weight: Float,
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
        self.uv = SIMD4(uv.x, uv.y, geometryScale, 0)
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

    /// 既定の不透明な線だけを GPU で広げる。列を並べ替えず、既存の列の開閉を通す。
    func placeGPUStroke(of source: SolidSource, mesh: () -> SolidMesh) -> Bool {
        guard case .mesh = source, !recordingShape, currentShader == nil,
            style.stroke.alpha == 1, style.strokeJoin == .miter,
            style.blendMode == .blend, style.picture == nil
        else { return false }
        let key: SolidSource
        let geometryScale: Float
        if case .mesh(.sphere(let radius, let detail)) = source {
            let tolerance = radius * SolidEdges.weldScale
            guard tolerance >= Float.leastNormalMagnitude,
                tolerance <= sqrt(Float.greatestFiniteMagnitude) / 4
            else { return false }
            key = .mesh(.sphere(radius: 1, detail: detail))
            geometryScale = radius
        } else {
            key = source
            geometryScale = 1
        }
        let geometry: SolidStrokeGeometry
        if let cached = solidStrokeGeometry[key] {
            geometry = cached
        } else {
            do {
                let net: SolidEdges
                if key != source, case .mesh(let shape) = key {
                    net = solidEdges(of: key) { shape.make() }
                } else {
                    net = solidEdges(of: source, mesh: mesh)
                }
                guard let made = try SolidStrokeGeometry(net: net, gpu: gpu)
                else { return false }
                solidStrokeGeometry.insert(made, for: key)
                geometry = made
            } catch {
                // 控えを確保できなければ従来の組み立てへ戻す。描画自体の失敗は従来側が伝える。
                return false
            }
        }
        beginSolids()
        closeBatch()
        let camera = currentCamera
        let placement = SolidStrokePlacement(
            matrix: transform.matrix, camera: camera, height: height, weight: style.strokeWeight,
            color: style.stroke, uv: whiteUV, geometryScale: geometryScale)
        openSolid = OpenSolid(
            source: source, vertexStart: 0, vertexCount: geometry.count,
            indexStart: nil, instanceStart: solidInstances.count,
            strokeGeometry: geometry, strokePlacement: placement)
        solidInstances.append(.identity)

        return true
    }
}
