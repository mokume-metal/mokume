// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import simd

// 立体を置く。空間の取り方・重ね順・設定の寿命は [ADR-0021] が定める。
//
// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
extension Canvas {

    // MARK: - 見る位置

    /// 面がちょうど収まる位置から、面の正面を見る視点。
    var defaultCamera: Camera { Camera.fitting(width: width, height: height) }

    // いま効いている視点。何も指定していなければ、面に合わせた既定が返る。
    public var currentCamera: Camera { cameraStorage ?? defaultCamera }

    /// 立体を落とす行列。いま効いている視点から作る。
    ///
    /// これを読むのは ``closeBatch()`` なので、列には**閉じた時点の視点**が入る。
    var viewProjection: simd_float4x4 {
        currentCamera.viewProjection(width: width, height: height)
    }

    /// 断片へ渡す「見ている場所」。
    var viewer: SIMD4<Float> { currentCamera.viewer }

    /// 視線が進む向き。
    var viewForward: SIMD3<Float> { currentCamera.forward }

    /// 画面の横方向。
    var viewRight: SIMD3<Float> { currentCamera.right }

    /// 画面の縦方向 (画面の下へ向かう)。
    var viewDown: SIMD3<Float> { currentCamera.down }

    /// その位置での、画面 1 画素ぶんの世界での長さ。
    func worldPerPixel(at position: SIMD3<Float>) -> Float {
        currentCamera.worldPerPixel(at: position, height: height)
    }

    // MARK: - 基本の形

    // 立方体を置く。
    public func box(_ size: Float) {
        box(size, size, size)
    }

    // 箱を置く。
    public func box(_ width: Float, _ height: Float, _ depth: Float) {
        guard SolidShape.isDrawable(width, height, depth) else { return warnBadSize("box") }
        place(.box(width: width, height: height, depth: depth))
    }

    // 球を置く。
    public func sphere(_ radius: Float, detail: Int = Canvas.defaultSolidDetail) {
        guard SolidShape.isDrawable(radius) else { return warnBadSize("sphere") }
        place(.sphere(radius: radius, detail: SolidShape.clampDetail(detail)))
    }

    // 平らな面を置く。
    public func plane(_ width: Float, _ height: Float) {
        guard SolidShape.isDrawable(width, height) else { return warnBadSize("plane") }
        place(.plane(width: width, height: height))
    }

    // 円柱を置く。
    public func cylinder(_ radius: Float, _ height: Float, detail: Int = Canvas.defaultSolidDetail) {
        guard SolidShape.isDrawable(radius, height) else { return warnBadSize("cylinder") }
        place(.cylinder(radius: radius, height: height, detail: SolidShape.clampDetail(detail)))
    }

    // 円錐を置く。
    public func cone(_ radius: Float, _ height: Float, detail: Int = Canvas.defaultSolidDetail) {
        guard SolidShape.isDrawable(radius, height) else { return warnBadSize("cone") }
        place(.cone(radius: radius, height: height, detail: SolidShape.clampDetail(detail)))
    }

    // 輪を置く。
    public func torus(
        _ radius: Float, _ tubeRadius: Float, detail: Int = Canvas.defaultSolidDetail
    ) {
        guard SolidShape.isDrawable(radius, tubeRadius) else { return warnBadSize("torus") }
        place(
            .torus(
                ringRadius: radius, tubeRadius: tubeRadius, detail: SolidShape.clampDetail(detail)))
    }

    // MARK: - 奥行きを持つ変換

    // 原点を奥行きも含めてずらす。
    public func translate(_ x: Float, _ y: Float, _ z: Float) {
        transform.translate(x: x, y: y, z: z)
    }

    // 横軸まわりに回す。
    public func rotateX(_ radians: Float) { transform.rotateX(by: radians) }

    // 縦軸まわりに回す。
    public func rotateY(_ radians: Float) { transform.rotateY(by: radians) }

    // 奥行きの軸まわりに回す。
    public func rotateZ(_ radians: Float) { transform.rotateZ(by: radians) }

    public func scale(_ x: Float, _ y: Float, _ z: Float) {
        transform.scale(x: x, y: y, z: z)
    }

    // MARK: - 置く

    /// 形を組み立てて (あるいは使い回して)、いまの変換と塗りで置く。
    ///
    /// **同じ形が続く間は、頂点を置き直さない。** 2 個目からは置き場所 (変換と塗り)
    /// だけが増えるので、1 万個置いても頂点は 1 組で済む。
    func place(_ shape: SolidShape) {
        guard hasFill else { return }

        placeMesh(.mesh(shape)) { solidMesh(for: shape) }
    }

    /// 三角形の並びを、いまの変換と塗りで置く。
    ///
    /// **同じ出どころが続く間は頂点を置き直さない。** 組み込みの形も読み込んだモデルも
    /// ここを通るので、まとめ方が 2 通りに割れない。
    func placeMesh(
        _ source: SolidSource, isDerived: Bool = false, mesh build: () -> SolidMesh
    ) {
        beginSolids()
        // **貼る絵が変わったら、ここで列が閉じる。** beginSolids は平面から移るときしか
        // 効かないので、立体を続けて置いている最中の切り替えはここが拾う
        useFillTexture()

        if openSolid?.source != source
            || solidInstances.count - (openSolid?.instanceStart ?? 0) >= instanceCapacity
        {
            // 出どころが変わった (か、1 列に入る上限に達した)。列を閉じて頂点を置き直す
            closeBatch()
            let mesh = build()
            let start = solidVertices.count
            solidVertices.reserveCapacity(start + mesh.points.count)
            let textured = currentPicture != nil
            for point in mesh.points {
                // **形自身の座標のまま置く。** 変換は置き場所が持つ
                solidVertices.append(
                    SolidVertex(
                        position: point.position, normal: point.normal, isDerived: isDerived,
                        // 貼る絵が無ければ焼き場の白い区画を読む。**そのときの頂点は
                        // 貼る口が無かった頃と 1 ビットも変わらない**
                        uv: textured ? point.uv : whiteUV,
                        color: .opaque(red: 1, green: 1, blue: 1)))
            }
            openSolid = OpenSolid(
                source: source, vertexStart: start, vertexCount: mesh.points.count,
                instanceStart: solidInstances.count)
        }

        solidInstances.append(
            SolidInstance(
                matrix: transform.matrix, normalMatrix: transform.normalMatrix,
                color: currentFill))
        // 半透明の塗りが 1 つでも入ったら、この列は裏面を捨てられない (`Batch.cullMode`)
        if currentFill.alpha < 1 { openSolid?.hasTranslucentInstance = true }
    }

    /// 立体を溜める側へ移る。**平面の列はここで閉じる** — 閉じないと、あとから
    /// 置いた立体が先に描かれる。
    func beginSolids() {
        guard openSource != .solid else { return }
        closeBatch()
        useFillTexture()
        openSource = .solid
    }

    /// その場で並べる頂点を溜める区間を開く。
    ///
    /// 置き場所は**何も動かさないもの 1 つ**。単位行列を掛けても値は変わらないので、
    /// 組み込みの形と同じ経路を通しても絵は 1 ビットも動かない。
    func inSolidBatch(_ body: () -> Void) {
        beginSolids()
        openFreeformSolid()
        body()
    }

    /// その場で並べる頂点の列を開く (既に開いていれば何もしない)。
    func openFreeformSolid() {
        if openSolid?.source == .freeform { return }
        closeBatch()
        openSolid = OpenSolid(
            source: .freeform, vertexStart: solidVertices.count, vertexCount: 0,
            instanceStart: solidInstances.count)
        solidInstances.append(.identity)
    }

    /// 立体の頂点を 1 つ溜める。
    ///
    /// **図形は焼き場の白い区画を読む** — 白を掛けても色は変わらないので、平面と同じ
    /// 塗りをそのまま通せる (``SolidVertex/uv``)。
    ///
    /// `uv` を渡すのは**塗り**だけで、線と点・周囲の背景は渡さない側に居続ける。
    /// 渡さなければ白い区画を読むので、貼る絵は塗りにしか効かない。
    func appendSolidVertex(
        position: SIMD3<Float>, shapePosition: SIMD3<Float>? = nil,
        normal: SIMD3<Float>, shapeNormal: SIMD3<Float>? = nil, isDerived: Bool = false,
        uv: SIMD2<Float>? = nil, color: LinearRGBA
    ) {
        // **面の切り替えが先。** 切り替えは列を閉じるので、開いてから切り替えると
        // 開いたばかりの列が閉じられ、この頂点がどの列にも属さなくなる
        if uv != nil { useFillTexture() } else { useGlyphTexture() }
        openFreeformSolid()
        solidVertices.append(
            SolidVertex(
                position: position, shapePosition: shapePosition, normal: normal,
                shapeNormal: shapeNormal, isDerived: isDerived, uv: uv ?? whiteUV,
                color: color))
        openSolid?.vertexCount += 1
    }

    /// 形を使い回す。**同じ寸法なら組み立て直さない。**
    ///
    /// 毎フレーム `box(120)` と書いても、組み立ては最初の 1 回だけになる。使わなく
    /// なったものは、多くなりすぎたときに古い順から捨てる。
    private func solidMesh(for shape: SolidShape) -> SolidMesh {
        if let cached = solidMeshes[shape] {
            solidMeshUse[shape] = solidMeshClock
            solidMeshClock += 1
            return cached
        }
        let mesh = shape.make()
        solidMeshes[shape] = mesh
        solidMeshUse[shape] = solidMeshClock
        solidMeshClock += 1
        solidMeshesBuilt += 1
        if solidMeshes.count > Canvas.solidMeshCacheLimit {
            let oldest = solidMeshUse.sorted { $0.value < $1.value }
                .prefix(solidMeshes.count - Canvas.solidMeshCacheLimit / 2)
            for (key, _) in oldest {
                solidMeshes.removeValue(forKey: key)
                solidMeshUse.removeValue(forKey: key)
            }
        }
        return mesh
    }

    /// 置けない寸法を、初回だけ知らせる。
    ///
    /// 毎フレーム起きうるので繰り返さない (``Diagnostics/warn(_:)`` の但し書き)。
    /// 描画は投げずに、何も置かないという安全な既定へ倒す ([ADR-0020] 決定 5)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    private func warnBadSize(_ name: String) {
        warnOnce(
            .badSolidSize,
            "\(name)(): 寸法に数でない値・無限・負の値が渡されたので、何も置きませんでした")
    }
}

// 立体の線と点。**画面での太さを保つ帯**として世界の座標で組み立てる。
extension Canvas {

    /// 立体の線を、太さのある帯でなぞる。
    ///
    /// 帯は**視線に正対させる** — そうしないと線を回したときに太さが変わり、真横を
    /// 向いた線が消える。太さは画面の画素で測るので、奥にあるものほど世界では広く作る。
    ///
    /// 面の向きは持たせない (ゼロ)。**線と点は光を受けない** — 平面の輪郭が光を受けない
    /// のと同じ扱いで、向きを持たない頂点をそのままの色で出すのは断片の側の約束である。
    ///
    /// **点は世界の座標と形自身の座標を対で受け取る。** 帯は視線に合わせて世界の座標で
    /// 組み立てるが、利用者の断片へ渡すのは形自身の座標のほうなので、両方が要る。
    /// 帯の太さのぶんの広がりは持たない — **帯のどの画素も、元になった点の座標を名乗る**。
    func strokeSolidRing(
        _ points: [SIMD3<Float>], shapePoints: [SIMD3<Float>], isClosed: Bool
    ) {
        let half = currentStrokeWeight / 2
        guard !points.isEmpty, shapePoints.count == points.count else { return }

        // 点が 1 つだけなら、端点の形そのものを置く
        if points.count == 1 {
            appendSolidCap(at: points[0], shape: shapePoints[0], half: half, isolated: true)
            return
        }

        let segmentCount = isClosed ? points.count : points.count - 1
        for index in 0..<segmentCount {
            let next = (index + 1) % points.count
            appendSolidBand(
                points[index], points[next],
                shape: (shapePoints[index], shapePoints[next]), half: half)
        }

        if isClosed {
            for index in points.indices {
                appendSolidJoin(at: points[index], shape: shapePoints[index], half: half)
            }
        } else {
            for index in 1..<(points.count - 1) {
                appendSolidJoin(at: points[index], shape: shapePoints[index], half: half)
            }
            appendSolidCap(at: points[0], shape: shapePoints[0], half: half, isolated: false)
            let last = points.count - 1
            appendSolidCap(at: points[last], shape: shapePoints[last], half: half, isolated: false)
        }
    }

    /// 線分 1 本を帯にする。
    private func appendSolidBand(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>,
        shape: (SIMD3<Float>, SIMD3<Float>), half: Float
    ) {
        let along = b - a
        guard length_squared(along) > 0 else { return }
        var side = cross(along, viewForward)
        // 視線に沿って伸びる線は横向きが決まらない。画面の横方向へ倒す
        if length_squared(side) <= 0 { side = viewRight }
        side = normalize(side)
        let atA = side * (half * worldPerPixel(at: a))
        let atB = side * (half * worldPerPixel(at: b))
        appendSolidStrokeTriangle(
            a + atA, b + atB, b - atB, shape: (shape.0, shape.1, shape.1))
        appendSolidStrokeTriangle(
            a + atA, b - atB, a - atA, shape: (shape.0, shape.1, shape.0))
    }

    /// 折れ目を埋める。帯は線分ごとに独立して置くので、曲がったところに隙間が空く。
    private func appendSolidJoin(at point: SIMD3<Float>, shape: SIMD3<Float>, half: Float) {
        switch currentStrokeJoin {
        case .round: appendSolidDisc(at: point, shape: shape, half: half)
        case .bevel, .miter: appendSolidSquare(at: point, shape: shape, half: half)
        }
    }

    /// 端を仕上げる。
    private func appendSolidCap(
        at point: SIMD3<Float>, shape: SIMD3<Float>, half: Float, isolated: Bool
    ) {
        switch currentStrokeCap {
        case .square where !isolated:
            return  // 線の長さちょうどで切る
        case .round:
            appendSolidDisc(at: point, shape: shape, half: half)
        case .square, .project:
            appendSolidSquare(at: point, shape: shape, half: half)
        }
    }

    /// 視線に正対する円板を置く (丸い端点と丸い角)。
    private func appendSolidDisc(at center: SIMD3<Float>, shape: SIMD3<Float>, half: Float) {
        let radius = half * worldPerPixel(at: center)
        let steps = 16
        var previous = center + viewRight * radius
        for step in 1...steps {
            let angle = 2 * Float.pi * Float(step) / Float(steps)
            let current = center + (viewRight * cos(angle) + viewDown * sin(angle)) * radius
            appendSolidStrokeTriangle(center, previous, current, shape: (shape, shape, shape))
            previous = current
        }
    }

    /// 視線に正対する正方形を置く (四角い端点と削いだ角)。
    private func appendSolidSquare(at center: SIMD3<Float>, shape: SIMD3<Float>, half: Float) {
        let radius = half * worldPerPixel(at: center)
        let a = center + (-viewRight - viewDown) * radius
        let b = center + (viewRight - viewDown) * radius
        let c = center + (viewRight + viewDown) * radius
        let d = center + (-viewRight + viewDown) * radius
        appendSolidStrokeTriangle(a, b, c, shape: (shape, shape, shape))
        appendSolidStrokeTriangle(a, c, d, shape: (shape, shape, shape))
    }

    private func appendSolidStrokeTriangle(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
        shape: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
    ) {
        appendSolidVertex(position: a, shapePosition: shape.0, normal: .zero, color: currentStroke)
        appendSolidVertex(position: b, shapePosition: shape.1, normal: .zero, color: currentStroke)
        appendSolidVertex(position: c, shapePosition: shape.2, normal: .zero, color: currentStroke)
    }
}
