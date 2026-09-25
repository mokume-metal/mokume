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

    /// 断片へ渡す「世界をカメラの側へ移す行列」。
    var viewMatrix: simd_float4x4 { currentCamera.viewMatrix }

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
    public func box(_ size: some ScalarConvertible) {
        let size = size.asFloat
        box(size, size, size)
    }

    // 箱を置く。
    public func box(_ width: some ScalarConvertible, _ height: some ScalarConvertible, _ depth: some ScalarConvertible) {
        let (width, height, depth) = (width.asFloat, height.asFloat, depth.asFloat)
        guard SolidShape.isDrawable(width, height, depth) else { return warnBadSize("box") }
        place(.box(width: width, height: height, depth: depth))
    }

    // 球を置く。
    public func sphere(_ radius: some ScalarConvertible, detail: Int = Canvas.defaultSolidDetail) {
        let radius = radius.asFloat
        guard SolidShape.isDrawable(radius) else { return warnBadSize("sphere") }
        place(.sphere(radius: radius, detail: SolidShape.clampDetail(detail)))
    }

    // 楕円体を置く。
    public func ellipsoid(
        _ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible,
        detail: Int = Canvas.defaultSolidDetail
    ) {
        let (x, y, z) = (x.asFloat, y.asFloat, z.asFloat)
        guard SolidShape.isDrawable(x, y, z) else { return warnBadSize("ellipsoid") }
        place(
            .ellipsoid(
                radiusX: x, radiusY: y, radiusZ: z, detail: SolidShape.clampDetail(detail)))
    }

    // 平らな面を置く。
    public func plane(_ width: some ScalarConvertible, _ height: some ScalarConvertible) {
        let (width, height) = (width.asFloat, height.asFloat)
        guard SolidShape.isDrawable(width, height) else { return warnBadSize("plane") }
        place(.plane(width: width, height: height))
    }

    // 円柱を置く。
    public func cylinder(
        _ radius: some ScalarConvertible, _ height: some ScalarConvertible,
        detail: Int = Canvas.defaultSolidDetail
    ) {
        let (radius, height) = (radius.asFloat, height.asFloat)
        guard SolidShape.isDrawable(radius, height) else { return warnBadSize("cylinder") }
        place(.cylinder(radius: radius, height: height, detail: SolidShape.clampDetail(detail)))
    }

    // 円錐を置く。
    public func cone(
        _ radius: some ScalarConvertible, _ height: some ScalarConvertible,
        detail: Int = Canvas.defaultSolidDetail
    ) {
        let (radius, height) = (radius.asFloat, height.asFloat)
        guard SolidShape.isDrawable(radius, height) else { return warnBadSize("cone") }
        place(.cone(radius: radius, height: height, detail: SolidShape.clampDetail(detail)))
    }

    // 輪を置く。
    public func torus(
        _ radius: some ScalarConvertible, _ tubeRadius: some ScalarConvertible, detail: Int = Canvas.defaultSolidDetail
    ) {
        let (radius, tubeRadius) = (radius.asFloat, tubeRadius.asFloat)
        guard SolidShape.isDrawable(radius, tubeRadius) else { return warnBadSize("torus") }
        place(
            .torus(
                ringRadius: radius, tubeRadius: tubeRadius, detail: SolidShape.clampDetail(detail)))
    }

    // MARK: - 奥行きを持つ変換

    // 原点を奥行きも含めてずらす。
    public func translate(_ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible) {
        let (x, y, z) = (x.asFloat, y.asFloat, z.asFloat)
        guard isShaping else { return warnOutsideFrame(.transform) }
        transform.translate(x: x, y: y, z: z)
    }

    // 横軸まわりに回す。
    public func rotateX(_ radians: some ScalarConvertible) {
        let radians = radians.asFloat
        guard isShaping else { return warnOutsideFrame(.transform) }
        transform.rotateX(by: radians)
    }

    // 縦軸まわりに回す。
    public func rotateY(_ radians: some ScalarConvertible) {
        let radians = radians.asFloat
        guard isShaping else { return warnOutsideFrame(.transform) }
        transform.rotateY(by: radians)
    }

    // 奥行きの軸まわりに回す。
    public func rotateZ(_ radians: some ScalarConvertible) {
        let radians = radians.asFloat
        guard isShaping else { return warnOutsideFrame(.transform) }
        transform.rotateZ(by: radians)
    }

    public func scale(_ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible) {
        let (x, y, z) = (x.asFloat, y.asFloat, z.asFloat)
        guard isShaping else { return warnOutsideFrame(.transform) }
        transform.scale(x: x, y: y, z: z)
    }

    // MARK: - 置く

    /// 形を組み立てて (あるいは使い回して)、いまの変換と塗りと線で置く。
    ///
    /// **同じ形が続く間は、頂点を置き直さない。** 2 個目からは置き場所 (変換と塗り)
    /// だけが増えるので、1 万個置いても頂点は 1 組で済む。
    ///
    /// 線は塗りに重ねて引く。`noFill()` なら線だけになる — 塗りと線は互いに独立した
    /// スタイルで、平面の図形と同じく次元によって作用が変わらない ([ADR-0020] 決定 3)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    func place(_ shape: SolidShape) {
        if style.hasFill { placeMesh(.mesh(shape)) { solidMesh(for: shape) } }
        strokeSolidEdges(of: .mesh(shape)) { solidMesh(for: shape) }
    }

    /// 三角形の並びを、いまの変換と塗りで置く。
    ///
    /// **同じ出どころが続く間は頂点を置き直さない。** 組み込みの形も読み込んだモデルも
    /// ここを通るので、まとめ方が 2 通りに割れない。
    ///
    /// **保持する形を記録している間だけは、置き場所を頂点へ焼く** ([#1297])。記録は置き場所を
    /// 持ち歩かない (``recordingShape``) ので、置き場所に変換と塗りを持たせたままだと、
    /// 置くときに形の原点へ白く落ちる。平面が記録の間は畳まずに頂点へ焼くのと同じ答えで、
    /// 捨てるのは**形の中での**畳みだけである — 組み上げた形を ``shape(_:at:)`` で何か所に
    /// 置いても、頂点 1 組と置き場所の並びで描くことは変わらない。
    ///
    /// [#1297]: https://github.com/mokume-metal/mokume/issues/1297
    func placeMesh(
        _ source: SolidSource, isDerived: Bool = false, mesh build: () -> SolidMesh
    ) {
        beginSolids()
        // **貼る絵が変わったら、ここで列が閉じる。** beginSolids は平面から移るときしか
        // 効かないので、立体を続けて置いている最中の切り替えはここが拾う
        useFillTexture()
        let textured = style.picture != nil
        let placement = SolidInstance(
            matrix: transform.matrix, normalMatrix: transform.normalMatrix,
            color: style.fill)

        if recordingShape {
            // **置き場所で描いたときと同じ頂点を、先に作って焼く。** 焼いた頂点はその場で
            // 並べる列へ積むので、線 (同じ列へ積まれる) と塗りが 1 本の区間に並ぶ
            let vertices = build().points.map {
                meshVertex($0, isDerived: isDerived, textured: textured)
            }
            appendPlacedSolidVertices(vertices[...], indices: nil, placedBy: placement)
            return
        }

        // **鏡映の符号が変わっても列を閉じる** ([#1446])。表の巻き方は列ごとに 1 つなので、
        // 鏡映した置き場所と鏡映していない置き場所は同じ列に並べられない。鏡映していない
        // 置き場所だけが続く間は、いままでどおり 1 列にまとまる
        //
        // [#1446]: https://github.com/mokume-metal/mokume/issues/1446
        if openSolid?.source != source || openSolid?.isMirrored != placement.isMirrored
            || isBatchFull(solidInstances.count, since: openSolid?.instanceStart ?? 0)
        {
            // 出どころか鏡映の符号が変わった (か、1 列に入る上限に達した)。列を閉じて頂点を
            // 置き直す
            closeBatch()
            let mesh = build()
            let start = solidVertices.count
            solidVertices.reserveCapacity(start + mesh.points.count)
            for point in mesh.points {
                solidVertices.append(meshVertex(point, isDerived: isDerived, textured: textured))
            }
            openSolid = OpenSolid(
                source: source, vertexStart: start, vertexCount: mesh.points.count,
                // 組み込みの形も読み込んだモデルも、頂点を並べた順にそのまま描く
                indexStart: nil,
                instanceStart: solidInstances.count, isMirrored: placement.isMirrored)
        }

        solidInstances.append(placement)
        // 裏面が絵に出うるスタイルで 1 つでも置いたら、この列は裏面を捨てられない
        // (`Batch.cullMode`)。**置いたこの時点で記録する** — 列が閉じる時点のスタイルは、
        // 置いた後で外した絵を知らない (#1564)
        if placementMayShowBackFaces { openSolid?.mayShowBackFaces = true }
    }

    /// 組み込みの形・読み込んだモデルの 1 点を頂点にする。
    ///
    /// **形自身の座標のまま、白で作る。** 変換と塗りは置き場所が持つ (記録の間は、置き場所
    /// ごと焼く — ``placeMesh(_:isDerived:mesh:)``)。
    private func meshVertex(
        _ point: SolidMesh.Point, isDerived: Bool, textured: Bool
    ) -> SolidVertex {
        SolidVertex(
            position: point.position, normal: point.normal, isDerived: isDerived,
            // 貼る絵が無ければ焼き場の白い区画を読む。**そのときの頂点は
            // 貼る口が無かった頃と 1 ビットも変わらない**
            uv: textured ? point.uv : whiteUV,
            color: .linear(red: 1, green: 1, blue: 1))
    }

    /// 置き場所を焼いた頂点を、その場で並べる頂点の列へ積む。**記録の間だけ通る。**
    ///
    /// `indices` は `vertices` を読む順で、値は**切り出す前の並びでの番号**である
    /// (``Shape/solidIndices`` と同じ数え方)。`nil` なら並べた順に読む。
    ///
    /// **読む面は切り替えない。** 面は呼ぶ側が決めてある — 組み込みの形なら塗りの面、
    /// 保持した形なら記録した面である。ここで選び直すと、記録した面が置く側の状態で
    /// 上書きされる ([#914])。
    ///
    /// **鏡映する置き場所で焼いたら、三角形の巻き方を戻す** ([#1446])。置いてから描く経路では
    /// 列が表の巻き方を裏返す (``Batch/frontFacing``) が、焼いた頂点は何も動かさない置き場所で
    /// 描くので、その列は裏返らない。巻き方を戻さないと、形から求めた向きの面が「裏を
    /// 向いている」と判定されて、見る側を向いた面が視線と逆の向きで光を受ける。三角形の
    /// 2 点目と 3 点目を入れ替えるだけなので、位置も向きも色も変わらない。
    ///
    /// [#914]: https://github.com/mokume-metal/mokume/issues/914
    /// [#1446]: https://github.com/mokume-metal/mokume/issues/1446
    func appendPlacedSolidVertices(
        _ vertices: ArraySlice<SolidVertex>, indices: ArraySlice<UInt32>?,
        placedBy placement: SolidInstance
    ) {
        if indices != nil { openIndexedFreeformSolid() } else { openFreeformSolid() }
        let base = solidVertices.count
        solidVertices.append(contentsOf: vertices.lazy.map(placement.placing))
        openSolid?.vertexCount += vertices.count
        let rewinds = placement.isMirrored
        if let indices {
            // 写した先までのずれを足す。ずれは負にもなる (切り出した位置より、溜め場の
            // 末尾が手前のことがある)
            let shift = base - vertices.startIndex
            let indexBase = solidIndices.count
            solidIndices.append(contentsOf: indices.lazy.map { UInt32(Int($0) + shift) })
            if rewinds { Self.reverseTriangles(in: &solidIndices, from: indexBase) }
            return
        }
        if rewinds { Self.reverseTriangles(in: &solidVertices, from: base) }
        if openSolid?.indexStart != nil {
            // **添字の列では、並べただけの頂点も自分の番号を名乗る** — 名乗らないと誰からも
            // 参照されず、黙って消える (``appendSolidVertex`` と同じ理由)
            solidIndices.append(contentsOf: (base..<solidVertices.count).lazy.map { UInt32($0) })
        }
    }

    /// `start` から後ろに並んだ三角形の巻き方を、1 枚ずつ裏返す (2 点目と 3 点目を入れ替える)。
    ///
    /// 並びは三角形の列 (3 つずつで 1 枚) で、立体の頂点も読む順もこの形で積まれている。
    /// **3 で割り切れない端は触らない** — 描く側も 3 つ揃わない端は読まない。
    private static func reverseTriangles<Element>(in elements: inout [Element], from start: Int) {
        var first = start
        while first + 2 < elements.count {
            elements.swapAt(first + 1, first + 2)
            first += 3
        }
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
    ///
    /// `indexed` は「この形が添字で読まれるか」。**形ごとに対応表を空にする** —
    /// 点番号は形の中でしか意味を持たないので、前の形の表が残っていると 2 つ目の形の
    /// 点 0 が 1 つ目の点 0 を指す。
    func inSolidBatch(indexed: Bool = false, _ body: () -> Void) {
        beginSolids()
        if indexed {
            openIndexedFreeformSolid()
            openSolid?.sharedSlots.removeAll(keepingCapacity: true)
        } else {
            openFreeformSolid()
        }
        body()
    }

    /// その場で並べる頂点の列を開く (既に開いていれば何もしない)。
    ///
    /// **開いているのが添字の列でも、そのまま使う。** 添字の列に並べただけの頂点が
    /// 来ても ``appendSolidVertex(position:shapePosition:normal:shapeNormal:isDerived:uv:color:)``
    /// が自分の番号を名乗らせるので、列を割らずに済む。
    func openFreeformSolid() {
        if openSolid?.source == .freeform { return }
        closeBatch()
        openSolid = OpenSolid(
            source: .freeform, vertexStart: solidVertices.count, vertexCount: 0,
            indexStart: nil, instanceStart: solidInstances.count)
        solidInstances.append(.identity)
    }

    /// 添字で読む、その場で並べる頂点の列を開く (既に添字の列が開いていれば何もしない)。
    ///
    /// **添字を持たない列が開いていたら閉じる。** 開いたままの列へ添字を積むと、
    /// 描くときに「並べた順」と「添字の順」が 1 つの区間に同居して、どちらで読んでも
    /// 正しくない絵になる。
    func openIndexedFreeformSolid() {
        if openSolid?.source == .freeform, openSolid?.indexStart != nil { return }
        closeBatch()
        openSolid = OpenSolid(
            source: .freeform, vertexStart: solidVertices.count, vertexCount: 0,
            indexStart: solidIndices.count, instanceStart: solidInstances.count)
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
        uv: SIMD2<Float>? = nil, isStroke: Bool = false, color: LinearRGBA
    ) {
        // **面の切り替えが先。** 切り替えは列を閉じるので、開いてから切り替えると
        // 開いたばかりの列が閉じられ、この頂点がどの列にも属さなくなる
        if uv != nil { useWrittenUVTexture() } else { useGlyphTexture() }
        openFreeformSolid()
        solidVertices.append(
            SolidVertex(
                position: position, shapePosition: shapePosition, normal: normal,
                shapeNormal: shapeNormal, isDerived: isDerived, uv: uv ?? whiteUV,
                isStroke: isStroke, color: color))
        openSolid?.vertexCount += 1
        // **添字の列では、並べただけの頂点も自分の番号を名乗る。** 名乗らないと
        // 描くときに誰からも参照されず、その頂点だけが黙って消える (輪郭の帯と
        // 端点は共有できないので、必ずこちらを通る)
        if openSolid?.indexStart != nil { solidIndices.append(UInt32(solidVertices.count - 1)) }
    }

    /// 添字の列へ、形の点番号で頂点を積む。**同じ点は 1 度しか積まない。**
    ///
    /// 手順の順序に意味がある — 面の切り替え (列を閉じうる) → 添字の列を開き直す →
    /// **開き直したあとの列の表を引く**。表は列が持つので、途中で列が閉じても閉じた列の
    /// 頂点を指す添字は作れない (``Canvas/OpenSolid/sharedSlots``)。そのときは共有が
    /// 効かずに積み直すだけで、絵は変わらない。
    func appendSharedSolidVertex(
        slot: Int, position: SIMD3<Float>, shapePosition: SIMD3<Float>,
        normal: SIMD3<Float>, shapeNormal: SIMD3<Float>, isDerived: Bool,
        uv: SIMD2<Float>?, color: LinearRGBA
    ) {
        if uv != nil { useWrittenUVTexture() } else { useGlyphTexture() }
        openIndexedFreeformSolid()
        if let shared = openSolid?.sharedSlots[slot] {
            solidIndices.append(shared)
            return
        }
        let number = UInt32(solidVertices.count)
        solidVertices.append(
            SolidVertex(
                position: position, shapePosition: shapePosition, normal: normal,
                shapeNormal: shapeNormal, isDerived: isDerived, uv: uv ?? whiteUV,
                color: color))
        openSolid?.vertexCount += 1
        openSolid?.sharedSlots[slot] = number
        solidIndices.append(number)
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
            "\(name)(): got a size that is not a number, or an infinite or negative one, so "
                + "nothing was placed")
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
        _ points: [SIMD3<Float>], shapePoints: [SIMD3<Float>], isClosed: Bool,
        curveSteps: [Bool] = []
    ) {
        let half = style.strokeWeight / 2
        guard !points.isEmpty, shapePoints.count == points.count else { return }

        // 端と折れ目の規則は平面と共有する (`strokeRing`)
        strokeRing(
            count: points.count, isClosed: isClosed, curveSteps: curveSteps,
            endSquare: {
                appendSolidSquare(
                    at: points[$0], awayFrom: points[$1], shape: shapePoints[$0], half: half)
            },
            band: {
                appendSolidBand(
                    points[$0], points[$1],
                    shape: (shapePoints[$0], shapePoints[$1]), half: half)
            },
            disc: { appendSolidDisc(at: points[$0], shape: shapePoints[$0], half: half) },
            square: { appendSolidSquare(at: points[$0], shape: shapePoints[$0], half: half) })
    }

    /// 置いた形の稜線を、いまの変換と線で引く (``SolidEdges``)。
    ///
    /// 帯は視線に合わせて**世界の座標で**組み立てるので、置き場所の変換を点へ焼き込む。
    /// 形自身の座標は稜線の点をそのまま渡す — 頂点を並べた形の輪郭と同じ約束で、
    /// 利用者の断片からは線も形の表面に留まって見える。
    func strokeSolidEdges(of source: SolidSource, mesh build: () -> SolidMesh) {
        guard style.hasStroke, style.strokeWeight > 0 else { return }
        let net = solidEdges(of: source, mesh: build)
        guard !net.edges.isEmpty else { return }
        // **塗りを置かなかったときも、立体の側へ移る。** 移らないと平面の列が開いた
        // ままで、線の頂点がどの列にも描かれない (`noFill()` で線だけにしたとき)
        beginSolids()

        let matrix = transform.matrix
        let placed = net.points.map { point in
            let world = matrix * SIMD4(point, 1)
            return SIMD3(world.x, world.y, world.z)
        }
        let half = style.strokeWeight / 2
        strokeNet(
            count: placed.count, edges: net.edges,
            endSquare: {
                appendSolidSquare(
                    at: placed[$0], awayFrom: placed[$1], shape: net.points[$0], half: half)
            },
            band: {
                appendSolidBand(
                    placed[$0], placed[$1], shape: (net.points[$0], net.points[$1]), half: half)
            },
            disc: { appendSolidDisc(at: placed[$0], shape: net.points[$0], half: half) },
            square: { appendSolidSquare(at: placed[$0], shape: net.points[$0], half: half) })
    }

    /// 稜線を使い回す。**線を引いた形にだけ作る。**
    private func solidEdges(of source: SolidSource, mesh build: () -> SolidMesh) -> SolidEdges {
        if let cached = solidEdges[source] { return cached }
        if solidEdges.count >= Canvas.solidMeshCacheLimit { solidEdges.removeAll(keepingCapacity: true) }
        let net = SolidEdges(build())
        solidEdges[source] = net
        return net
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

    /// 視線に正対し、画面の軸に沿った正方形を置く (向きの無い点の四角い端と、丸めない角)。
    /// 線の端の正方形は線の向きに沿って置く (`appendSolidSquare(at:awayFrom:shape:half:)`)。
    private func appendSolidSquare(at center: SIMD3<Float>, shape: SIMD3<Float>, half: Float) {
        appendSolidSquare(at: center, right: viewRight, down: viewDown, shape: shape, half: half)
    }

    /// 視線に正対し、線の向きに沿った正方形を置く (出っ張らせる端 — [#1535])。
    ///
    /// 軸は帯 (`appendSolidBand`) と同じ横向き `cross(along, viewForward)` と、それに直交して
    /// 視線に正対した向きで取る。帯と合わせて、画面で見て線を太さの半分だけ延ばした形に
    /// なる。横向きが決まらない (線が視線に沿う・長さ 0) ときは、画面の軸に沿った正方形へ倒す。
    ///
    /// [#1535]: https://github.com/mokume-metal/mokume/issues/1535
    private func appendSolidSquare(
        at center: SIMD3<Float>, awayFrom from: SIMD3<Float>, shape: SIMD3<Float>, half: Float
    ) {
        let side = cross(center - from, viewForward)
        guard length_squared(side) > 0 else {
            return appendSolidSquare(at: center, shape: shape, half: half)
        }
        let right = normalize(side)
        appendSolidSquare(
            at: center, right: right, down: normalize(cross(viewForward, right)), shape: shape,
            half: half)
    }

    /// 視線に正対する正方形を、`right` / `down` の 2 軸で張る。
    private func appendSolidSquare(
        at center: SIMD3<Float>, right: SIMD3<Float>, down: SIMD3<Float>, shape: SIMD3<Float>,
        half: Float
    ) {
        let radius = half * worldPerPixel(at: center)
        let a = center + (-right - down) * radius
        let b = center + (right - down) * radius
        let c = center + (right + down) * radius
        let d = center + (-right + down) * radius
        appendSolidStrokeTriangle(a, b, c, shape: (shape, shape, shape))
        appendSolidStrokeTriangle(a, c, d, shape: (shape, shape, shape))
    }

    private func appendSolidStrokeTriangle(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
        shape: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
    ) {
        // 輪郭の頂点を名乗る。頂点関数が画面で半画素寄せる (`SolidVertex.stroke`)
        appendSolidVertex(
            position: liftedTowardViewer(a), shapePosition: shape.0, normal: .zero,
            isStroke: true, color: style.stroke)
        appendSolidVertex(
            position: liftedTowardViewer(b), shapePosition: shape.1, normal: .zero,
            isStroke: true, color: style.stroke)
        appendSolidVertex(
            position: liftedTowardViewer(c), shapePosition: shape.2, normal: .zero,
            isStroke: true, color: style.stroke)
    }

    /// 線の頂点を、**見ている側へ視線に沿って**わずかに寄せる。
    ///
    /// 帯は視線に正対するので、面の縁に置くと帯の半分が面と同じ奥行きに載る。面を
    /// 先に描いてあると、その半分が面と奥行きを取り合って**途切れた線**になる
    /// (#850 で組み込みの形に線を効かせたときに、箱の稜が点線になって現れた)。
    ///
    /// **視線に沿って動かすので、画面での位置は変わらない** — 動くのは奥行きだけ
    /// である。寄せる量は**帯の幅に 1 画素を足した世界の長さ**。帯の内側の縁は、
    /// 帯の半分の幅と頂点関数の半画素の寄せのぶん面の内へ入る。視線に対して 60° 余り
    /// まで傾いた面ならその奥行きの差をこの量が上回る (量を帯の半分 + 1 画素にした
    /// ときは、傾いた面の縁で 1 行に 1 画素ずつ線が食われた)。形の裏の稜線は形の
    /// 厚みぶん奥にあるので、塗った形の向こう側が透けて見えるのは画面で数画素の
    /// 形と、稜線が表の縁から出てくる角の数画素だけである。
    private func liftedTowardViewer(_ point: SIMD3<Float>) -> SIMD3<Float> {
        let camera = currentCamera
        let lift = (style.strokeWeight + 1) * worldPerPixel(at: point)
        switch camera.projection {
        case .perspective:
            let toEye = camera.eye - point
            let distance = length(toEye)
            guard distance > 0 else { return point }
            // 目を越えて裏へ回らないよう、目までの半分で止める
            return point + toEye / distance * min(lift, distance / 2)
        case .orthographic:
            return point - camera.forward * lift
        }
    }
}
