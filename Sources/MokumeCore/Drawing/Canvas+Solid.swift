// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import MokumeDiagnostics
import simd

// 立体を置く。空間の取り方・重ね順・設定の寿命は [ADR-0021] が定める。
//
// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
extension Canvas {

    // MARK: - 見る位置

    /// 既定の画角 (縦方向・ラジアン)。
    static let defaultFieldOfView: Float = .pi / 3

    /// 面がちょうど収まる距離。
    ///
    /// 既定の視点はここに置く。だから何も指定せずに置いた立体は**画素の大きさで
    /// 見える** — `box(120)` は 120 画素の箱として出る ([ADR-0021] 決定 1)。
    var defaultEyeDistance: Float {
        (height / 2) / tan(Canvas.defaultFieldOfView / 2)
    }

    /// 立体を落とす行列。
    ///
    /// **奥行き 0 の面は、平面の図形とぴったり重なる。** 距離を上のように選び、
    /// 平面と同じ半画素のずらしを掛けているためで、そのことは検査で固定してある。
    var viewProjection: simd_float4x4 {
        let distance = defaultEyeDistance
        let eye = SIMD3<Float>(width / 2, height / 2, distance)
        let center = SIMD3<Float>(width / 2, height / 2, 0)
        let view = Self.lookAt(eye: eye, center: center, up: SIMD3<Float>(0, 1, 0))
        let projection = Self.perspective(
            fieldOfView: Canvas.defaultFieldOfView,
            aspect: width / height,
            near: distance / 10,
            far: distance * 10)
        return Self.clipAdjustment(width: width, height: height) * projection * view
    }

    /// 縦軸を下向きに保ち、平面と同じ半画素のずらしを掛ける。
    ///
    /// 縦軸は 2 度反転する — 投影が持つ「上が +y」と、この行列の反転で、世界の +y が
    /// 画面の下になる。平面の約束をそのまま延長するための補正である ([ADR-0021] 決定 1)。
    static func clipAdjustment(width: Float, height: Float) -> simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, -1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(1 / width, -1 / height, 0, 1))
    }

    /// 見る位置と向きから、世界をカメラの側へ移す行列を作る。
    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let back = normalize(eye - center)
        let right = normalize(cross(up, back))
        let above = cross(back, right)
        return simd_float4x4(
            SIMD4<Float>(right.x, above.x, back.x, 0),
            SIMD4<Float>(right.y, above.y, back.y, 0),
            SIMD4<Float>(right.z, above.z, back.z, 0),
            SIMD4<Float>(-dot(right, eye), -dot(above, eye), -dot(back, eye), 1))
    }

    /// 遠くのものほど小さく写す投影。
    static func perspective(fieldOfView: Float, aspect: Float, near: Float, far: Float)
        -> simd_float4x4
    {
        let y = 1 / tan(fieldOfView / 2)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0))
    }

    /// 既定の視点の置き場所 (世界の座標)。
    var eyePosition: SIMD3<Float> { SIMD3(width / 2, height / 2, defaultEyeDistance) }

    /// 視線が進む向き。**奥行きの正の側が手前** ([ADR-0021] 決定 1)。
    var viewForward: SIMD3<Float> { SIMD3(0, 0, -1) }

    /// 画面の横方向。
    var viewRight: SIMD3<Float> { SIMD3(1, 0, 0) }

    /// 画面の縦方向 (縦軸は下向き)。
    var viewUp: SIMD3<Float> { SIMD3(0, 1, 0) }

    /// その位置での、画面 1 画素ぶんの世界での長さ。
    ///
    /// 線の太さは画面の画素で測る約束なので、奥にあるものほど世界では広く作る。
    /// **視点の情報はここ 1 箇所から取る** — 視点を変える口が来ても式が散らばらない。
    func worldPerPixel(at position: SIMD3<Float>) -> Float {
        let depth = max(dot(position - eyePosition, viewForward), defaultEyeDistance / 10)
        return 2 * tan(Canvas.defaultFieldOfView / 2) * depth / height
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

    // 奥行きも含めて伸ばす・縮める。
    public func scale(_ x: Float, _ y: Float, _ z: Float) {
        transform.scale(x: x, y: y, z: z)
    }

    // MARK: - 置く

    /// 形を組み立てて (あるいは使い回して)、いまの変換と塗りで置く。
    func place(_ shape: SolidShape) {
        guard hasFill else { return }

        let mesh = solidMesh(for: shape)
        let matrix = transform.matrix
        let normalMatrix = transform.normalMatrix
        let color = currentFill

        inSolidBatch {
            solidVertices.reserveCapacity(solidVertices.count + mesh.points.count)
            for point in mesh.points {
                let moved = matrix * SIMD4<Float>(point.position, 1)
                appendSolidVertex(
                    position: SIMD3<Float>(moved.x, moved.y, moved.z),
                    normal: normalMatrix * point.normal,
                    color: color)
            }
        }
    }

    /// 立体の頂点を溜める区間を開く。
    ///
    /// 立体の列は**その場で閉じる**。平面と立体が呼び出し順のまま重なるようにするため
    /// で、続けて置いた立体を 1 つの列へ畳むのはまだしない (畳むこと自体が別の道具の
    /// 仕事なので、ここでは順序だけを守る)。
    func inSolidBatch(_ body: () -> Void) {
        // 平面の列をここで閉じる。閉じないと、あとから置いた立体が先に描かれる
        closeBatch()
        useGlyphTexture()
        openSource = .solid
        body()
        closeBatch()
        openSource = .flat
    }

    /// 立体の頂点を 1 つ溜める。
    ///
    /// **図形は焼き場の白い区画を読む** — 白を掛けても色は変わらないので、平面と同じ
    /// 塗りをそのまま通せる (``SolidVertex/uv``)。
    func appendSolidVertex(
        position: SIMD3<Float>, normal: SIMD3<Float>, isDerived: Bool = false,
        color: LinearRGBA
    ) {
        solidVertices.append(
            SolidVertex(
                position: position, normal: normal, isDerived: isDerived, uv: whiteUV,
                color: color))
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
        guard !warnedBadSolidSize else { return }
        warnedBadSolidSize = true
        Diagnostics.warn(
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
    func strokeSolidRing(_ points: [SIMD3<Float>], isClosed: Bool) {
        let half = currentStrokeWeight / 2
        guard !points.isEmpty else { return }

        // 点が 1 つだけなら、端点の形そのものを置く
        if points.count == 1 {
            appendSolidCap(at: points[0], half: half, isolated: true)
            return
        }

        let segmentCount = isClosed ? points.count : points.count - 1
        for index in 0..<segmentCount {
            appendSolidBand(points[index], points[(index + 1) % points.count], half: half)
        }

        if isClosed {
            for point in points { appendSolidJoin(at: point, half: half) }
        } else {
            for index in 1..<(points.count - 1) {
                appendSolidJoin(at: points[index], half: half)
            }
            appendSolidCap(at: points[0], half: half, isolated: false)
            appendSolidCap(at: points[points.count - 1], half: half, isolated: false)
        }
    }

    /// 線分 1 本を帯にする。
    private func appendSolidBand(_ a: SIMD3<Float>, _ b: SIMD3<Float>, half: Float) {
        let along = b - a
        guard length_squared(along) > 0 else { return }
        var side = cross(along, viewForward)
        // 視線に沿って伸びる線は横向きが決まらない。画面の横方向へ倒す
        if length_squared(side) <= 0 { side = viewRight }
        side = normalize(side)
        let atA = side * (half * worldPerPixel(at: a))
        let atB = side * (half * worldPerPixel(at: b))
        appendSolidStrokeTriangle(a + atA, b + atB, b - atB)
        appendSolidStrokeTriangle(a + atA, b - atB, a - atA)
    }

    /// 折れ目を埋める。帯は線分ごとに独立して置くので、曲がったところに隙間が空く。
    private func appendSolidJoin(at point: SIMD3<Float>, half: Float) {
        switch currentStrokeJoin {
        case .round: appendSolidDisc(at: point, half: half)
        case .bevel, .miter: appendSolidSquare(at: point, half: half)
        }
    }

    /// 端を仕上げる。
    private func appendSolidCap(at point: SIMD3<Float>, half: Float, isolated: Bool) {
        switch currentStrokeCap {
        case .square where !isolated:
            return  // 線の長さちょうどで切る
        case .round:
            appendSolidDisc(at: point, half: half)
        case .square, .project:
            appendSolidSquare(at: point, half: half)
        }
    }

    /// 視線に正対する円板を置く (丸い端点と丸い角)。
    private func appendSolidDisc(at center: SIMD3<Float>, half: Float) {
        let radius = half * worldPerPixel(at: center)
        let steps = 16
        var previous = center + viewRight * radius
        for step in 1...steps {
            let angle = 2 * Float.pi * Float(step) / Float(steps)
            let current = center + (viewRight * cos(angle) + viewUp * sin(angle)) * radius
            appendSolidStrokeTriangle(center, previous, current)
            previous = current
        }
    }

    /// 視線に正対する正方形を置く (四角い端点と削いだ角)。
    private func appendSolidSquare(at center: SIMD3<Float>, half: Float) {
        let radius = half * worldPerPixel(at: center)
        let a = center + (-viewRight - viewUp) * radius
        let b = center + (viewRight - viewUp) * radius
        let c = center + (viewRight + viewUp) * radius
        let d = center + (-viewRight + viewUp) * radius
        appendSolidStrokeTriangle(a, b, c)
        appendSolidStrokeTriangle(a, c, d)
    }

    private func appendSolidStrokeTriangle(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>
    ) {
        appendSolidVertex(position: a, normal: .zero, color: currentStroke)
        appendSolidVertex(position: b, normal: .zero, color: currentStroke)
        appendSolidVertex(position: c, normal: .zero, color: currentStroke)
    }
}
