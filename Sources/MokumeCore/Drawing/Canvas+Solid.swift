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
        place(.sphere(radius: radius, detail: admittedDetail(detail, for: "sphere", .badSphereDetail)))
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
                radiusX: x, radiusY: y, radiusZ: z, detail: admittedDetail(detail, for: "ellipsoid", .badEllipsoidDetail)))
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
        place(.cylinder(radius: radius, height: height, detail: admittedDetail(detail, for: "cylinder", .badCylinderDetail)))
    }

    // 円錐を置く。
    public func cone(
        _ radius: some ScalarConvertible, _ height: some ScalarConvertible,
        detail: Int = Canvas.defaultSolidDetail
    ) {
        let (radius, height) = (radius.asFloat, height.asFloat)
        guard SolidShape.isDrawable(radius, height) else { return warnBadSize("cone") }
        place(.cone(radius: radius, height: height, detail: admittedDetail(detail, for: "cone", .badConeDetail)))
    }

    // 輪を置く。
    public func torus(
        _ radius: some ScalarConvertible, _ tubeRadius: some ScalarConvertible, detail: Int = Canvas.defaultSolidDetail
    ) {
        let (radius, tubeRadius) = (radius.asFloat, tubeRadius.asFloat)
        guard SolidShape.isDrawable(radius, tubeRadius) else { return warnBadSize("torus") }
        place(
            .torus(
                ringRadius: radius, tubeRadius: tubeRadius, detail: admittedDetail(detail, for: "torus", .badTorusDetail)))
    }

    // MARK: - 奥行きを持つ変換

    // 原点を奥行きも含めてずらす。
    public func translate(_ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible) {
        let (x, y, z) = (x.asFloat, y.asFloat, z.asFloat)
        guard admitsTransform else { return warnOutsideFrame(.transform) }
        transform.translate(x: x, y: y, z: z)
        noteTransformWritten()
    }

    // 横軸まわりに回す。
    public func rotateX(_ radians: some ScalarConvertible) {
        let radians = radians.asFloat
        guard admitsTransform else { return warnOutsideFrame(.transform) }
        transform.rotateX(by: radians)
        noteTransformWritten()
    }

    // 縦軸まわりに回す。
    public func rotateY(_ radians: some ScalarConvertible) {
        let radians = radians.asFloat
        guard admitsTransform else { return warnOutsideFrame(.transform) }
        transform.rotateY(by: radians)
        noteTransformWritten()
    }

    // 奥行きの軸まわりに回す。
    public func rotateZ(_ radians: some ScalarConvertible) {
        let radians = radians.asFloat
        guard admitsTransform else { return warnOutsideFrame(.transform) }
        transform.rotateZ(by: radians)
        noteTransformWritten()
    }

    public func scale(_ x: some ScalarConvertible, _ y: some ScalarConvertible, _ z: some ScalarConvertible) {
        let (x, y, z) = (x.asFloat, y.asFloat, z.asFloat)
        guard admitsTransform else { return warnOutsideFrame(.transform) }
        transform.scale(x: x, y: y, z: z)
        noteTransformWritten()
    }

    /// 縦横と奥行きを同じ倍率で伸ばす (`scale(s, s, s)`)。
    public func scale(_ s: some ScalarConvertible) {
        let s = s.asFloat
        guard admitsTransform else { return warnOutsideFrame(.transform) }
        transform.scale(x: s, y: s, z: s)
        noteTransformWritten()
    }

    // MARK: - 置く

    /// 形を組み立てて (あるいは使い回して)、いまの変換と塗りと線で置く。
    ///
    /// **同じ形の頂点は、描き切るまで 1 組を共有する。** 線で列が分かれても、塗りの
    /// 頂点を置き直さない。描く列は呼び出し順のまま、置き場所 (変換と塗り) を持つ。
    ///
    /// 線は塗りに重ねて引く。`noFill()` なら線だけになる — 塗りと線は互いに独立した
    /// スタイルで、平面の図形と同じく次元によって作用が変わらない ([ADR-0020] 決定 3)。
    ///
    /// **正の寸法の球・箱・平面・円柱の塗りは、単位の形の頂点 1 組を共有する** ([#1862]・[#2386])。
    /// 軸ごとの寸法は置き場所が持ち (``SolidInstance/normal0``〜`normal2` の `w`)、頂点関数が
    /// 単位の形の位置 × 寸法で位置を作る。寸法の違う形を幾つ置いても形を組まず、1 列で描く。絵と、
    /// 利用者の断片が読む `shapePosition`・`shapeNormal` は、寸法ごとに頂点を組む経路と 1 ビットも
    /// 違わない (`UnitShapeTests`)。どの形が乗るかは ``SolidShape/unitScaling`` が決める。保持する
    /// 形の記録は寸法ごとの形のまま置く — 記録は置き場所を頂点へ焼く。線は稜線を単位の形から
    /// 広げる (``solidEdges(of:mesh:)``)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [#1862]: https://github.com/mokume-metal/mokume/issues/1862
    /// [#2386]: https://github.com/mokume-metal/mokume/issues/2386
    func place(_ shape: SolidShape) {
        // 立体はベクターへ書けない (#3139)
        noteVectorDrop(.solid)
        if style.hasFill {
            if sharesUnitShapes, !recordingShape, let (unit, scale) = shape.unitScaling {
                placeMesh(.mesh(unit), unitScale: scale) { solidMesh(for: unit) }
            } else {
                placeMesh(.mesh(shape)) { solidMesh(for: shape) }
            }
        }
        strokeSolidEdges(of: .mesh(shape)) { solidMesh(for: shape) }
    }

    /// 三角形の並びを、いまの変換と塗りで置く。
    ///
    /// **同じ入力の頂点は、列をまたいで共有する。** 組み込みの形も読み込んだモデルも
    /// ここを通る。続く同じ出どころは配置をまとめ、離れた列は同じ頂点範囲を指す。
    ///
    /// **保持する形を記録している間だけは、置き場所を頂点へ焼く** ([#1297])。記録は置き場所を
    /// 持ち歩かない (``recordingShape``) ので、置き場所に変換と塗りを持たせたままだと、
    /// 置くときに形の原点へ白く落ちる。平面が記録の間は畳まずに頂点へ焼くのと同じ答えで、
    /// 捨てるのは**形の中での**畳みだけである — 組み上げた形を ``shape(_:at:)`` で何か所に
    /// 置いても、頂点 1 組と置き場所の並びで描くことは変わらない。
    ///
    /// `unitScale` があれば、`source` は単位の形で、置き場所がその軸ごとの倍率で広げて描く
    /// (``place(_:)``)。単位の形の列は、頂点の溜め場も共有の区間も寸法ごとの形と同じものを使う —
    /// 裏 → 表のまとめ描き (#1947) が溜め場の頂点を読むためである。
    ///
    /// [#1297]: https://github.com/mokume-metal/mokume/issues/1297
    func placeMesh(
        _ source: SolidSource, unitScale: SIMD3<Float>? = nil,
        winding: () -> SolidWinding = { .outward },
        mesh build: () -> SolidMesh
    ) {
        // 区間の外では、立体の側へも移らない (``Canvas/canPlace``・#1672)
        guard canPlace else { return warnOutsideFrame(.placing) }
        beginSolids()
        // **貼る絵が変わったら、ここで列が閉じる。** beginSolids は平面から移るときしか
        // 効かないので、立体を続けて置いている最中の切り替えはここが拾う。頂点がメッシュの読み取り位置を
        // 持つかは、束ねた面に合わせる (貼る絵か、利用者の断片だけのときの白い 1×1・#3797)
        let textured = useFillTexture()
        var placement = SolidInstance(
            matrix: transform.matrix, normalMatrix: transform.normalMatrix,
            color: style.fill)
        let usesUnitShape = unitScale != nil
        if let unitScale {
            placement.normal0.w = unitScale.x
            placement.normal1.w = unitScale.y
            placement.normal2.w = unitScale.z
        }

        if recordingShape {
            // **置き場所で描いたときと同じ頂点を、先に作って焼く。** 焼いた頂点はその場で
            // 並べる列へ積むので、線 (同じ列へ積まれる) と塗りが 1 本の区間に並ぶ
            let points = build().points
            var vertices: [SolidVertex] = []
            vertices.reserveCapacity(points.count)
            for point in points {
                vertices.append(meshVertex(point, textured: textured))
            }
            // 記録した形 1 つが部品 1 つ (``SolidPart``)。置いたときのスタイルを部品へ残す —
            // 保持した形を置くときは、記録したときのスタイルで裏 → 表に描くかが決まる。記録した
            // 形は後で半透明の色で置かれうるので、向きはここで求める (モデルなら 1 度だけ・控える)
            let found = winding()
            let parts =
                found == .unknown
                ? []
                : [
                    SolidPart(
                        range: 0..<vertices.count, isIndexed: false,
                        showsBackFaces: placementShowsBackFaces(placement, styled: placementMayShowBackFaces),
                        insideOut: found == .inward)
                ]
            appendPlacedSolidVertices(vertices[...], indices: nil, placedBy: placement, parts: parts)
            return
        }

        // **鏡映の符号が変わっても列を閉じる** ([#1446])。表の巻き方は列ごとに 1 つなので、
        // 鏡映した置き場所と鏡映していない置き場所は同じ列に並べられない。鏡映していない
        // 置き場所だけが続く間は、いままでどおり 1 列にまとまる
        //
        // [#1446]: https://github.com/mokume-metal/mokume/issues/1446
        //
        // 単位球の列と半径ごとの形の列も分ける (頂点関数が違う)
        if openSolid?.source != source || openSolid?.strokeGeometry != nil
            || openSolid?.usesUnitShape != usesUnitShape
            || openSolid?.isMirrored != placement.isMirrored
            || isBatchFull(solidInstances.count, since: openSolid?.instanceStart ?? 0)
        {
            // 列は分けても、描く順序と頂点の所有は別である。同じ入力なら既に積んだ範囲を指す。
            closeBatch()
            let key = SolidMeshRangeKey(source: source, textured: textured, whiteUV: whiteUV)
            // **読み込んだモデルは、頂点を GPU の置き場に持って使い回す** (#1749)。溜め場へ
            // 積まないので、列はその置き場の先頭から数える
            if case .model = source,
                let geometry = modelFill(for: key, textured: textured, mesh: build)
            {
                openSolid = OpenSolid(
                    source: source, vertexStart: 0, vertexCount: geometry.count,
                    indexStart: nil, instanceStart: solidInstances.count,
                    isMirrored: placement.isMirrored, fillGeometry: geometry)
                solidInstances.append(placement)
                noteMeshPlacement(placement, winding: winding)
                return
            }
            let range: Range<Int>
            if let shared = solidMeshRanges[key] {
                range = shared
            } else {
                let mesh = build()
                let start = solidVertices.count
                solidVertices.reserveCapacity(start + mesh.points.count)
                for point in mesh.points {
                    solidVertices.append(meshVertex(point, textured: textured))
                }
                range = start..<solidVertices.count
                solidMeshRanges[key] = range
            }
            openSolid = OpenSolid(
                source: source, vertexStart: range.lowerBound, vertexCount: range.count,
                // 組み込みの形も読み込んだモデルも、頂点を並べた順にそのまま描く
                indexStart: nil,
                instanceStart: solidInstances.count, isMirrored: placement.isMirrored,
                usesUnitShape: usesUnitShape)
        }

        solidInstances.append(placement)
        noteMeshPlacement(placement, winding: winding)
    }

    /// いま置いた組み込みの形・モデルの置き場所 (溜め場の末尾) に、裏面が絵に出うるかの印を付ける。
    ///
    /// 裏面が絵に出うるスタイルで 1 つでも置いたら、この列は裏面を捨てられない (`Batch.cullMode`)。
    /// **置いたこの時点で記録する** — 列が閉じる時点のスタイルは、置いた後で外した絵を知らない
    /// (#1564)。印の付いた置き場所だけを裏 → 表の 2 回で描く (``OpenSolid/backFaceInstances``)。
    /// 巻き方の向きは、初めて印が付いたときに求める (モデルなら控えを読む)。
    private func noteMeshPlacement(_ placement: SolidInstance, winding: () -> SolidWinding) {
        guard let open = openSolid,
            placementShowsBackFaces(placement, styled: placementMayShowBackFaces)
        else { return }
        openSolid?.mayShowBackFaces = true
        openSolid?.backFaceInstances.append(solidInstances.count - 1 - open.instanceStart)
        if open.meshWinding == nil { openSolid?.meshWinding = winding() }
    }

    /// 読み込んだモデルの塗りの頂点を持つ GPU の置き場。控えに無ければ詰めて作る。
    ///
    /// **持たないときは `nil`** — 呼ぶ側は溜め場へ積む (以前の経路)。持たないのは、1 つで
    /// 予算の半分を超えるとき (追い出し合って毎フレーム作り直すのを避ける) と、置き場を
    /// 確保できないとき (描けなくするより溜め場で描く)。
    private func modelFill(
        for key: SolidMeshRangeKey, textured: Bool, mesh build: () -> SolidMesh
    ) -> SolidFillGeometry? {
        if let cached = modelFills[key] { return cached }
        let points = build().points
        guard points.count * MemoryLayout<SolidVertex>.stride <= modelFills.budget / 2 else {
            return nil
        }
        var vertices: [SolidVertex] = []
        vertices.reserveCapacity(points.count)
        for point in points {
            vertices.append(meshVertex(point, textured: textured))
        }
        guard let made = try? SolidFillGeometry(vertices: vertices, gpu: gpu) else { return nil }
        modelFills.insert(made, for: key)
        return made
    }

    /// 組み込みの形・読み込んだモデルの 1 点を頂点にする。
    ///
    /// **形自身の座標のまま、白で作る。** 変換と塗りは置き場所が持つ (記録の間は、置き場所
    /// ごと焼く — ``placeMesh(_:winding:mesh:)``)。**向きを形から求めたかは点が持つ**
    /// (``SolidMesh/Point/isDerivedNormal``) — 読み込んだモデルは角ごとに違いうる (#2342)。
    private func meshVertex(_ point: SolidMesh.Point, textured: Bool) -> SolidVertex {
        SolidVertex(
            position: point.position, normal: point.normal, isDerived: point.isDerivedNormal,
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
        placedBy placement: SolidInstance, parts: [SolidPart] = [],
        showsBackFaces: Bool? = nil, mirrored: Bool? = nil, strokeSections: [Range<Int>] = []
    ) {
        // `showsBackFaces` と `mirrored` は、置き場所を先に掛けた頂点 (`placement` は単位) を積む
        // ときに、元の置き場所の判定を渡す口 (保持した形の線を組み直して差し込む・#1893)。
        // `strokeSections` も同じ口で、組み直した線のうち 1 回だけ混ぜるものの区間を、`parts` と同じ
        // 数え方 (添字を持つなら読む順の並び、持たなければ頂点の並び) で渡す
        if indices != nil { openIndexedFreeformSolid() } else { openFreeformSolid() }
        let base = solidVertices.count
        notePlacedParts(
            parts, vertices: vertices, indices: indices, base: base,
            tinted: showsBackFaces ?? placementShowsBackFaces(placement, styled: false))
        notePlacedStrokeSections(strokeSections, vertices: vertices, indices: indices, base: base)
        // 閉包を標準ライブラリの高階関数へ渡さずにループで回す。main actor の文脈の閉包は
        // 要素ごとに隔離の実行時検査を払う (#1779)
        solidVertices.reserveCapacity(base + vertices.count)
        for vertex in vertices { solidVertices.append(placement.placing(vertex)) }
        openSolid?.vertexCount += vertices.count
        let rewinds = mirrored ?? placement.isMirrored
        if let indices {
            // 写した先までのずれを足す。ずれは負にもなる (切り出した位置より、溜め場の
            // 末尾が手前のことがある)
            let shift = base - vertices.startIndex
            let indexBase = solidIndices.count
            solidIndices.reserveCapacity(indexBase + indices.count)
            for index in indices { solidIndices.append(UInt32(Int(index) + shift)) }
            if rewinds { Self.reverseTriangles(in: &solidIndices, from: indexBase) }
            return
        }
        if rewinds { Self.reverseTriangles(in: &solidVertices, from: base) }
        if openSolid?.indexStart != nil {
            // **添字の列では、並べただけの頂点も自分の番号を名乗る** — 名乗らないと誰からも
            // 参照されず、黙って消える (``appendSolidVertex`` と同じ理由)
            solidIndices.reserveCapacity(solidIndices.count + solidVertices.count - base)
            for index in base..<solidVertices.count { solidIndices.append(UInt32(index)) }
        }
    }

    /// 焼いて積む頂点の部品を、開いている列の描く単位へ写して足す (``OpenSolid/parts``)。
    ///
    /// `parts` は切り出す前の並びの番号で、添字を持つ区間なら読む順の並び、持たなければ頂点の
    /// 並びで数える (``Shape/solidParts`` と同じ)。写した先は列の描く単位で、添字を持たない頂点を
    /// 添字の列へ積むときは、頂点が名乗る番号の位置になる (下の積み方と同じ順)。`tinted` は置き場所の
    /// 色が透けているか — 透けていれば、記録したときのスタイルによらず裏面が絵に出うる。
    ///
    /// **積む前に呼ぶ** (`base` と添字の並びの末尾が、写す先の始まり)。
    private func notePlacedParts(
        _ parts: [SolidPart], vertices: ArraySlice<SolidVertex>, indices: ArraySlice<UInt32>?,
        base: Int, tinted: Bool
    ) {
        guard !parts.isEmpty, let open = openSolid else { return }
        let columnIndexed = open.indexStart != nil
        let indexBase = solidIndices.count
        // 列の部品へその場で足す (写してから戻すと、焼く置き場所の数の 2 乗で効く)
        for part in parts {
            var moved = part
            if let indices {
                guard part.isIndexed, indices.indices.contains(part.range.lowerBound),
                    part.range.upperBound <= indices.endIndex
                else { continue }
                moved = part.shifted(by: indexBase - indices.startIndex)
            } else {
                guard !part.isIndexed, vertices.indices.contains(part.range.lowerBound),
                    part.range.upperBound <= vertices.endIndex
                else { continue }
                moved = part.shifted(by: (columnIndexed ? indexBase : base) - vertices.startIndex)
                moved.isIndexed = columnIndexed
            }
            if tinted { moved.showsBackFaces = true }
            openSolid?.parts.append(moved)
        }
    }

    /// 焼いて積む頂点の、1 回だけ混ぜる線の区間を、開いている列の描く単位へ写して足す
    /// (``OpenSolid/strokeStencilSections``)。写し方は ``notePlacedParts(_:vertices:indices:base:tinted:)`` と同じで、
    /// **積む前に呼ぶ**。鏡映の置き場所で巻き方を戻すのは三角形の中の入れ替えだけなので、区間は動かない。
    private func notePlacedStrokeSections(
        _ sections: [Range<Int>], vertices: ArraySlice<SolidVertex>, indices: ArraySlice<UInt32>?, base: Int
    ) {
        guard !sections.isEmpty, let open = openSolid else { return }
        let shift =
            indices.map { solidIndices.count - $0.startIndex }
            ?? ((open.indexStart != nil ? solidIndices.count : base) - vertices.startIndex)
        for section in sections { appendStrokeStencilSection((section.lowerBound + shift)..<(section.upperBound + shift)) }
    }

    /// `start` から後ろに並んだ三角形の巻き方を、1 枚ずつ裏返す (2 点目と 3 点目を入れ替える)。
    ///
    /// 並びは三角形の列 (3 つずつで 1 枚) で、立体の頂点も読む順もこの形で積まれている。
    /// **3 で割り切れない端は触らない** — 描く側も 3 つ揃わない端は読まない。
    static func reverseTriangles<Element>(in elements: inout [Element], from start: Int) {
        var first = start
        while first + 2 < elements.count {
            elements.swapAt(first + 1, first + 2)
            first += 3
        }
    }

    /// 立体を溜める側へ移る。**平面の列はここで閉じる** — 閉じないと、あとから
    /// 置いた立体が先に描かれる。
    func beginSolids() {
        // **立体を置く口はどれもここを通る。** 列が開いていても記録は置くたびに取る
        notePaintPlacement()
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
        // 区間の外では区間を開かず、`body` も走らせない (``Canvas/canPlace``・#1672)。奥行きの
        // ある形の輪郭 (`strokeSolidRing`) も、ここを通って塞がる。周囲の背景はここを通らず、
        // 口が自分で区間の外を断る (``Canvas/replaceSurface(with:)``・#1685)
        guard canPlace else { return warnOutsideFrame(.placing) }
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
    /// `uv` を渡すのは**塗り**だけで、線と点は渡さない側に居続ける。
    /// 渡さなければ白い区画を指すので、貼る絵は塗りにしか効かない (利用者の断片だけを当てているときは
    /// 塗りと同じ白い 1×1 を読む。どこを指しても白なので色は同じ — ``Canvas/useUnwrittenUVTexture()``)。
    func appendSolidVertex(
        position: SIMD3<Float>, shapePosition: SIMD3<Float>? = nil,
        normal: SIMD3<Float>, shapeNormal: SIMD3<Float>? = nil, isDerived: Bool = false,
        uv: SIMD2<Float>? = nil, isStroke: Bool = false, strokeCoverage: Float = 1,
        color: LinearRGBA
    ) {
        // **面の切り替えが先。** 切り替えは列を閉じるので、開いてから切り替えると
        // 開いたばかりの列が閉じられ、この頂点がどの列にも属さなくなる
        if uv != nil { useWrittenUVTexture() } else { useUnwrittenUVTexture() }
        openFreeformSolid()
        solidVertices.append(
            SolidVertex(
                position: position, shapePosition: shapePosition, normal: normal,
                shapeNormal: shapeNormal, isDerived: isDerived, uv: uv ?? whiteUV,
                isStroke: isStroke, strokeCoverage: strokeCoverage, color: color))
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
        if uv != nil { useWrittenUVTexture() } else { useUnwrittenUVTexture() }
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
    /// なったものは、多くなりすぎたときに古い順から 1 件ずつ捨てる (``Canvas/solidMeshes``)。
    private func solidMesh(for shape: SolidShape) -> SolidMesh {
        if let cached = solidMeshes[shape] { return cached }
        let mesh: SolidMesh
        if case .sphere(let radius, let detail) = shape, radius != 1 {
            // **向きは半径に依らない** ので、同じ細かさの単位球から位置だけを作る (#1751)。
            // 組み立て (``SolidMeshBuilder/sphere(radius:detail:)``) と同じく位置は
            // `向き * 半径` で、単位球の位置は `向き * 1` = 向きそのものなので、1 ビットも
            // 変わらない。寸法が毎フレーム動く球が、三角関数を点ごとに引き直さずに済む
            // 閉包を標準ライブラリへ渡さずに回す — 渡すと点ごとに隔離の実行時検査を払う (#1779)
            let unit = solidMesh(for: .sphere(radius: 1, detail: detail))
            var points: [SolidMesh.Point] = []
            points.reserveCapacity(unit.points.count)
            for point in unit.points {
                points.append(
                    SolidMesh.Point(
                        position: point.normal * radius, normal: point.normal, uv: point.uv))
            }
            mesh = SolidMesh(points: points)
            spheresFromUnit += 1
        } else {
            mesh = shape.make()
        }
        solidMeshes.insert(mesh, for: shape)
        return mesh
    }

    /// 分け方を範囲 (``SolidShape/detailRange``) へ丸め、丸めたら 1 度知らせる ([#1698])。
    ///
    /// 丸め先は ``SolidShape/clampDetail(_:)`` のまま。鍵は立体ごとに分ける — 共有すると、
    /// 先に言った立体が後の立体の書き間違いを黙らせる (#1698 の反証 9)。
    ///
    /// **置けない所 (フレームの外) では知らせない** (#1698 の反証 10)。そこでは形を置かず、
    /// 置く側 (`placeMesh`) が「フレームの外」を言う。置かない形のために 1 度きりの鍵を使い
    /// 切らない。
    ///
    /// [#1698]: https://github.com/mokume-metal/mokume/issues/1698
    private func admittedDetail(_ detail: Int, for name: String, _ warning: Warning) -> Int {
        let used = SolidShape.clampDetail(detail)
        if used != detail, canPlace {
            let range = SolidShape.detailRange
            warnRounded(
                warning, name, "detail",
                takes: "\(range.lowerBound) to \(range.upperBound)", passed: detail, used: used)
        }
        return used
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
    /// 帯は**画面に写した線に正対させる** — 横向きを画面上の線の垂線に取る。そう
    /// しないと線を回したときに太さが変わり、真横を向いた線が消える。透視投影で
    /// 正対させる相手はカメラ全体の軸ではなく、目から線の各点へ向かう視線である
    /// (画面の中心から外れた奥行きのある線が細った・#1546)。太さは画面の画素で測る
    /// ので、奥にあるものほど世界では広く作る。
    ///
    /// 面の向きは持たせない (ゼロ)。**線と点は光を受けない** — 平面の輪郭が光を受けない
    /// のと同じ扱いで、向きを持たない頂点をそのままの色で出すのは断片の側の約束である。
    ///
    /// **点は世界の座標と形自身の座標を対で受け取る。** 帯は視線に合わせて世界の座標で
    /// 組み立てるが、利用者の断片へ渡すのは形自身の座標のほうなので、両方が要る。
    /// 帯の太さのぶんの広がりは持たない — **帯のどの画素も、元になった点の座標を名乗る**。
    ///
    /// **周は、隣り合う点を辺で結んだ網として、立体の稜線と同じ骨で組む** ([#1893])。端と
    /// 折れ目の規則は平面と同じだが、画面で重なる点 (視線に沿う辺の両端) を何段でも 1 つの
    /// 群にまとめ、群に 1 度だけ形を置く決まりは網の骨 (`strokeNet`) が持つ。周と網で写して
    /// 持つと、まとめる段数と置く回数が経路ごとに食い違う。
    ///
    /// **描く画素で 1 画素より細い線は、描く画素 1 つの太さへ広げて被覆を下げる**
    /// (#1637・``ThinStroke``)。太さは出す画素なので、細さは置く面の細かさだけで決まる。
    /// 記録の間は判断せず、置くときに置く面で組み直す (``rebuiltSolidStroke(_:)``)。
    ///
    /// **半透明の線は、1 つの図形の線全体を 1 回だけ混ぜる** ([ADR-0046])。帯・折れ目・端の形・曲線の
    /// 刻みの円板は重ねたまま積み、型板が同じ画素の 2 つ目以降の片を落とす。画面で折れ目が重なる所・
    /// 奥行きの違う辺が画面で交わる所も 1 回で、別々の図形の線どうしは 2 回混ぜる。`shader()` を付けた線と、
    /// 保持した形を置くときに組み直す線 (``rebuiltSolidStroke(_:)``) も同じで、断片の出力が場所で違う線の
    /// 重なりは先に積んだ片の色になる。どの線が入るかは ``solidStrokeOverlapsShow(alpha:)`` にあり、描く画素で
    /// 1 画素より細い線 (被覆 < 1) は、色によらず入る (#2185 の決定 D)。
    ///
    /// [ADR-0046]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0046-stroke-stencil.md
    /// [#1893]: https://github.com/mokume-metal/mokume/issues/1893
    func strokeSolidRing(
        _ points: [SIMD3<Float>], shapePoints: [SIMD3<Float>], isClosed: Bool,
        curveSteps: [Bool] = []
    ) {
        let isPoint = points.count == 1
        let thin = thinSolidStroke(weight: style.strokeWeight, isPoint: isPoint)
        solidStrokeIsLonePoint = isPoint
        defer { solidStrokeIsLonePoint = false }
        withThinSolidStroke(thin, isPoint: isPoint) {
            strokeSolidRingAsStyled(
                points, shapePoints: shapePoints, isClosed: isClosed, curveSteps: curveSteps)
        }
    }

    /// いまの線の設定のまま、立体の線を帯でなぞる (細い線の補いは ``strokeSolidRing`` が当てる)。
    private func strokeSolidRingAsStyled(
        _ points: [SIMD3<Float>], shapePoints: [SIMD3<Float>], isClosed: Bool,
        curveSteps: [Bool]
    ) {
        guard !points.isEmpty, shapePoints.count == points.count else { return }
        let source = SolidStrokePiece.Source.ring(
            points: points, shapePoints: shapePoints, isClosed: isClosed, curveSteps: curveSteps)
        recordingSolidStroke(source) { buildSolidStroke(source) }
    }

    /// 置いた形の稜線を、いまの変換と線で引く (``SolidEdges``)。
    ///
    /// 帯は視線に合わせて**世界の座標で**組み立てるので、置き場所の変換を点へ焼き込む。
    /// 形自身の座標は稜線の点をそのまま渡す — 頂点を並べた形の輪郭と同じ約束で、
    /// 利用者の断片からは線も形の表面に留まって見える。
    ///
    /// **半透明の稜線は、形 1 つの稜線全体を 1 回だけ混ぜる** ([ADR-0046])。稜が集まる角も、奥行きの違う
    /// 稜が画面で交わる所も 1 回で、別々に置いた形どうしは 2 回混ぜる。`shader()` を付けた稜線と、保持した
    /// 形に記録して置く稜線も同じである。色と混ぜ方で重なりが絵に出る線は GPU の骨 (``placeGPUStroke(of:mesh:)``・
    /// 不透明の `blend` で断片なしだけ) を通らず、CPU の帯で組んで型板を通る。描く画素で 1 画素より細い不透明の
    /// 線は骨のまま、骨の列全体を区間にして型板を通る (``openGPUStroke``)。
    ///
    /// [ADR-0046]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0046-stroke-stencil.md
    func strokeSolidEdges(of source: SolidSource, mesh build: () -> SolidMesh) {
        // 区間の外では引かない。`noFill()` の立体はここだけを通る (``Canvas/canPlace``・#1672)
        guard canPlace else { return warnOutsideFrame(.placing) }
        guard style.hasStroke, style.strokeWeight > 0 else { return }
        // **描く画素で 1 画素より細い稜線も補う** (#1637)。GPU で広げる経路は、置く時点で
        // 自分で補う (``openGPUStroke``) ので、ここで太さを変えるのは CPU の帯だけである
        if placeGPUStroke(of: source, mesh: build) { return }
        let thin = thinSolidStroke(weight: style.strokeWeight, isPoint: false)
        withThinSolidStroke(thin, isPoint: false) { strokeSolidEdgesAsStyled(of: source, mesh: build) }
    }

    /// いまの線の設定のまま、置いた形の稜線を引く。
    private func strokeSolidEdgesAsStyled(of source: SolidSource, mesh build: () -> SolidMesh) {
        let net = solidEdges(of: source, mesh: build)
        guard !net.edges.isEmpty else { return }
        // **塗りを置かなかったときも、立体の側へ移る。** 移らないと平面の列が開いた
        // ままで、線の頂点がどの列にも描かれない (`noFill()` で線だけにしたとき)
        beginSolids()
        let strokeStart = solidVertices.count
        defer { rememberGPUStroke(of: source, from: strokeStart) }
        let stroke = SolidStrokePiece.Source.net(net, matrix: transform.matrix)
        recordingSolidStroke(stroke) { buildSolidStroke(stroke) }
    }

    /// 線 1 本 (周か網) を積む。**記録の間は、置くときに組み直せるよう元を覚える** ([#1547])。
    ///
    /// 帯は視点に合わせて組むので、記録したときの視点で組んだ帯は置いた先で合わない
    /// (``SolidStrokePiece``)。頂点はいまの視点で組んで積み、その区間と元 (点と繋がり・線の
    /// スタイル) を ``recordedSolidStrokes`` に残す。置くときは、元を置いた後の点と置く時点の
    /// 視点で、その場の線と同じ手順で組み直す。
    ///
    /// **記録した視点で何も積まない線は覚えない** (線の全体が画面の 1 点に潰れて `.square` で
    /// 切った線など)。区間は添字の列の中で組み直した頂点を差し込む位置の印でもあり、空の区間は
    /// 位置を持たない。印のために面積 0 の三角形を積むと、公開の ``Shape/vertexCount`` が増え、
    /// GPU で組む線としても覚えてしまう。main の部品の記録 (何も積まない部品は覚えない) と同じ。
    ///
    /// [#1547]: https://github.com/mokume-metal/mokume/issues/1547
    private func recordingSolidStroke(_ source: SolidStrokePiece.Source, _ build: () -> Void) {
        let stenciled =
            !recordingShape
            && solidStrokeTakesSection(
                alpha: style.stroke.alpha, coverage: solidStrokeCoverage, isLonePoint: solidStrokeIsLonePoint)
        let start = solidVertices.count
        let indexStart = solidIndices.count
        build()
        if stenciled { noteStrokeStencilSection(vertexStart: start, indexStart: indexStart) }
        guard recordingShape, solidVertices.count > start else { return }
        recordedSolidStrokes.append(
            SolidStrokePiece(
                source: source, weight: style.strokeWeight, join: style.strokeJoin, cap: style.strokeCap,
                vertexStart: start, vertexCount: solidVertices.count - start,
                isLonePoint: solidStrokeIsLonePoint))
    }

    /// 立体の線 1 本を、1 回だけ混ぜる区間に入れるか ([ADR-0046])。**立体の線を積む口はどれもここで決める** —
    /// その場の線 (``recordingSolidStroke(_:_:)``)・保持した形の組み直し (``rebuiltSolidStroke(_:)``)・GPU で広げる
    /// 骨 (``openGPUStroke``)。
    ///
    /// - 描く画素で 1 画素より細い線 (被覆 < 1) は、色によらず入れる (#2185 の決定 D)。被覆の残りに下地を読む
    ///   ので、不透明の色でも片が重なると濃くなる
    /// - ただし点 1 つの線 (端の形だけ) は入れない。細い点は画面の軸に沿った正方形 1 枚 (対角線を共有する
    ///   三角形 2 枚) で組むので片が重ならず、区間にしても描く呼び出しが増えるだけである (``ThinStroke``)
    /// - それ以外は、重なりが色と混ぜ方で絵に出るか (``solidStrokeOverlapsShow(alpha:)``)
    ///
    /// - Parameters:
    ///   - alpha: 線の不透明度。保持した形なら置き場所の色を掛けたもの。
    ///   - coverage: 描く画素での被覆 (細い線の補い・#1637)。
    ///   - isLonePoint: 点 1 つの線か (``SolidStrokePiece/isLonePoint``)。
    ///
    /// [ADR-0046]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0046-stroke-stencil.md
    func solidStrokeTakesSection(alpha: Float, coverage: Float, isLonePoint: Bool) -> Bool {
        if coverage < 1, !isLonePoint { return true }
        return solidStrokeOverlapsShow(alpha: alpha)
    }

    /// 立体の線の片の重なりが絵に出るか — 出るなら、1 つの図形の線全体を型板で 1 回だけ混ぜる
    /// ([ADR-0046]・``Batch/strokeStencilSections``)。いまの線の色で判定する
    /// (``solidStrokeOverlapsShow(alpha:)``)。
    ///
    /// [ADR-0046]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0046-stroke-stencil.md
    var solidStrokeOverlapsShow: Bool { solidStrokeOverlapsShow(alpha: style.stroke.alpha) }

    /// 不透明度 `alpha` の立体の線の片の重なりが、いまの混ぜ方と塗りで絵に出るか ([ADR-0046])。
    ///
    /// 出るのは次の線である:
    ///
    /// - `shader()` が効いている線 ([#2184])。断片が出す不透明度は分からない (平面の線の ``strokeOverlapsShow`` と
    ///   同じ)。断片の出力が場所で違う線の重なりは、先に積んだ片の色になる。`replace` で置いても同じく入る。
    ///   勾配の塗り (`fill(Gradient)`) も面が持つ断片で塗るが、線は色のまま出すので数えない
    /// - 半透明の色を `blend` / `lightest` / `darkest` で置く線
    /// - 下地を読む混ぜ方 (`add` ほか) で置く線
    ///
    /// `replace` の線と不透明の色の線は、重ねて混ぜても同じ色になるので型板を通さない。`replace` の縁が
    /// 下地を読むのは被覆が 1 未満の画素 (細い線の帯・[#3111]) だけで、ここに来る線 (被覆 1) は下地を読まない。
    ///
    /// 塗りと混ぜ方は ``effectivePaint``・`style.blendMode` から読む。保持した形を置く間は記録したものが
    /// 当たっている (``replaying(_:_:)``) ので、置き場所の色を掛けた不透明度を渡せば、組み直す線
    /// (``rebuiltSolidStroke(_:)``) も同じ判定になる ([#3577])。色と混ぜ方だけを見る判定で、描く画素で 1 画素より
    /// 細い線 (被覆 < 1・[#3578]) を色によらず入れるのは、区間に入れるかの判定 (``solidStrokeTakesSection(alpha:coverage:isLonePoint:)``) である。
    ///
    /// [ADR-0046]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0046-stroke-stencil.md
    /// [#2184]: https://github.com/mokume-metal/mokume/issues/2184
    /// [#3111]: https://github.com/mokume-metal/mokume/issues/3111
    /// [#3577]: https://github.com/mokume-metal/mokume/issues/3577
    /// [#3578]: https://github.com/mokume-metal/mokume/issues/3578
    func solidStrokeOverlapsShow(alpha: Float) -> Bool {
        // 勾配の断片 (``paintsWithGradient``) は塗りにだけ効き、線は色のまま出す
        if let shader = effectivePaint.shader, shader !== gradientShaderStorage { return true }
        switch style.blendMode {
        case .replace: return false
        case .blend, .lightest, .darkest: return alpha < 1
        case .add, .subtract, .difference, .exclusion, .multiply, .screen: return true
        }
    }

    /// 組み終えた線 1 本の区間を、開いている列に 1 回だけ混ぜる区間として覚える (``OpenSolid/strokeStencilSections``)。
    ///
    /// 区間は列の描く単位で持つ — 添字の列 (奥行きのある `beginShape` の列など) では読む順の並び、
    /// そうでなければ頂点の並び。添字の列に並べた線の頂点も自分の番号を名乗る
    /// (``appendSolidVertex(position:shapePosition:normal:shapeNormal:isDerived:uv:isStroke:strokeCoverage:color:)``)
    /// ので、読む順の並びの中で連なる。組む途中で列が閉じたら、いまの列に入った分だけを覚える。
    private func noteStrokeStencilSection(vertexStart: Int, indexStart: Int) {
        guard let open = openSolid else { return }
        appendStrokeStencilSection(
            open.indexStart.map { max(indexStart, $0)..<solidIndices.count }
                ?? max(vertexStart, open.vertexStart)..<solidVertices.count)
    }

    /// 列の描く単位で数えた区間を、開いている列の 1 回だけ混ぜる区間に足す。外の置き場から読む列と
    /// GPU の骨の列には足さない — 骨の列は、開くときに列全体を 1 つの区間にする (``openGPUStroke``) ので、
    /// 頂点の並びで数えた区間を混ぜられない。
    private func appendStrokeStencilSection(_ section: Range<Int>) {
        guard let open = openSolid, open.external == nil, open.strokeGeometry == nil, !section.isEmpty else { return }
        openSolid?.strokeStencilSections.append(section)
    }

    /// 線 1 本を、いまのスタイルといまの視点で組む。積むか位置だけを受け取るかは
    /// ``solidStrokeCapture`` が決める。
    ///
    /// 周も網も、点と辺の網として 1 つの骨 (`strokeNet`) を通る。周の辺は隣り合う点を結んだ
    /// もの (閉じていれば最後の点から最初の点へも) で、点 1 つだけの周は端点の形そのものを置く。
    private func buildSolidStroke(_ source: SolidStrokePiece.Source) {
        let world: [SIMD3<Float>]
        let shape: [SIMD3<Float>]
        let edges: [(Int, Int)]
        var curveSteps: [Bool] = []
        let half = style.strokeWeight / 2
        let camera = StrokeCamera(currentCamera, width: width, height: height)
        // 円板の周の点は線 1 本で 1 度だけ求める (太さは線の中で変わらない・#2011)
        let discUnits = Self.solidDiscUnits(half: half)
        switch source {
        case let .ring(points, shapePoints, isClosed, steps):
            world = points
            shape = shapePoints
            curveSteps = steps
            let count = points.count
            if count == 1 {
                // 点が 1 つだけなら、向きの無い端点の形そのものを置く (平面の周と同じ)
                if style.strokeCap == .round {
                    appendSolidDisc(
                        at: world[0], shape: shape[0], half: half, units: discUnits, camera: camera)
                } else {
                    appendSolidSquare(at: world[0], shape: shape[0], half: half, camera: camera)
                }
                return
            }
            var ring: [(Int, Int)] = []
            ring.reserveCapacity(count)
            for index in 0..<(isClosed ? count : count - 1) { ring.append((index, (index + 1) % count)) }
            edges = ring
        case let .net(net, matrix):
            var placed: [SIMD3<Float>] = []
            placed.reserveCapacity(net.points.count)
            for point in net.points {
                let moved = matrix * SIMD4(point, 1)
                placed.append(SIMD3(moved.x, moved.y, moved.z))
            }
            world = placed
            shape = net.points
            edges = net.edges
        }
        // 細い線の帯は、帯ごとに画面の向きで広げ直す (``SolidThinBand``・#3734)。帯を持たない片 (円板・点の
        // 正方形) は、線に垂直に 1 へ広げた太さと被覆のまま
        let thin = solidThinBand
        func thinBand(_ from: Int, _ to: Int) -> (half: Float, coverage: Float)? {
            guard let thin, let toward = screenToward(world[from], world[to], camera: camera) else { return nil }
            return thin.band(along: toward)
        }
        // 細い線の円板 (丸い端・丸い折れ目・曲線の刻みの継ぎ目) が載る帯。点ごとに、その点から出る辺を控える
        // (細くない線では求めない)
        var incident: [[Int]] = []
        if thin != nil {
            incident = Array(repeating: [], count: world.count)
            for (number, (a, b)) in edges.enumerated() {
                incident[a].append(number)
                incident[b].append(number)
            }
        }
        func covering(_ coverage: Float?, _ body: () -> Void) {
            guard let coverage else { return body() }
            let saved = solidStrokeCoverage
            solidStrokeCoverage = coverage
            body()
            solidStrokeCoverage = saved
        }
        // 細い線の開いた端は、画面の描く画素の列 (行) の境目で切る (#3745・平面の ``thinCarving(_:thin:)`` と同じ
        // ``ThinEndCut``)。端の列の片は、ほかの片より先に積む (型板で先の片が勝つ・平面と同じ)
        var ends: SolidEndCuts?
        if let thin {
            ends = solidEndCuts(world: world, edges: edges, curveSteps: curveSteps, thin: thin, camera: camera)
        }
        if let ends {
            for piece in ends.pieces {
                covering(piece.coverage * piece.cut.fraction) {
                    appendSolidCutPolygon(
                        piece.cut.piece, along: (piece.point, piece.far), world: world, shape: shape, ends: ends,
                        camera: camera)
                }
            }
        }
        strokeNet(
            count: world.count, edges: edges, curveSteps: curveSteps,
            samePoint: { world[$0] == world[$1] },
            depth: { dot(world[$0] - camera.eye, camera.forward) },
            toward: { screenToward(world[$0], world[$1], camera: camera) },
            endSquare: { end, far in
                // 列の境目で切った端は、延ばした端点で切ってある (端の長方形は置かない・#3745)
                if ends?.cuts[end] != nil { return }
                // 端は線に沿って元の太さの半分だけ出し、横は帯と同じ幅・同じ被覆にする
                let band = thinBand(far, end)
                covering(band?.coverage) {
                    appendSolidSquare(
                        at: world[end], awayFrom: world[far], shape: shape[end], half: band?.half ?? half,
                        along: thin?.alongHalf, camera: camera)
                }
            },
            band: { from, to in
                let band = thinBand(from, to)
                // 列の境目で切る端の帯は、端の外まで延ばしてから境目で切る (端の列とその外は端の列の片が持つ)
                if let ends, let band, ends.cuts[from] != nil || ends.cuts[to] != nil,
                    let start = ends.screen.locate(world[from]), let end = ends.screen.locate(world[to])
                {
                    var (a, b) = (start, end)
                    if let cut = ends.cuts[from] { a = cut.tip - cut.inward * 4 }
                    if let cut = ends.cuts[to] { b = cut.tip - cut.inward * 4 }
                    let delta = b - a
                    let length = simd_length(delta)
                    guard length > 0 else { return }
                    let normal = SIMD2(-delta.y, delta.x) / length * (band.half / ends.outputPerDrawn)
                    var corners = [a + normal, b + normal, b - normal, a - normal]
                    if let cut = ends.cuts[from] { corners = cut.trimmed(corners) }
                    if let cut = ends.cuts[to] { corners = cut.trimmed(corners) }
                    return covering(band.coverage) {
                        appendSolidCutPolygon(
                            corners, along: (from, to), world: world, shape: shape, ends: ends, camera: camera)
                    }
                }
                covering(band?.coverage) {
                    appendSolidBand(
                        world[from], world[to], shape: (shape[from], shape[to]), half: band?.half ?? half,
                        camera: camera)
                }
            },
            disc: { index in
                // 細い線の円板は、載る帯に合わせる (#3734 の反証 #1)。線に垂直に 1 へ広げたままだと、斜めの細い帯から
                // はみ出して光が足される。端 (帯 1 本) は線に沿って元の太さの半分・横は帯と同じ幅の楕円、折れ目と
                // 刻みの継ぎ目は帯の半幅と被覆の小さいほうの円板 (平面の ``thinCarving(_:thin:)`` と同じ)
                //
                // 列の境目で切った丸い端は、面積の等しい平らな延長で切ってある (丸い片は置かない・#3748)
                if ends?.cuts[index] != nil { return }
                var bands: [(half: Float, coverage: Float, far: Int)] = []
                if !incident.isEmpty {
                    for number in incident[index] {
                        let (a, b) = edges[number]
                        let far = a == index ? b : a
                        if let band = thinBand(index, far) { bands.append((band.half, band.coverage, far)) }
                    }
                }
                guard let thin, let first = bands.first else {
                    return appendSolidDisc(
                        at: world[index], shape: shape[index], half: half, units: discUnits, camera: camera)
                }
                if bands.count == 1 {
                    return covering(first.coverage) {
                        appendSolidEllipse(
                            at: world[index], awayFrom: world[first.far], shape: shape[index], across: first.half,
                            along: thin.alongHalf, units: discUnits, camera: camera)
                    }
                }
                covering(bands.map(\.coverage).min()) {
                    appendSolidDisc(
                        at: world[index], shape: shape[index], half: bands.map(\.half).min() ?? half, units: discUnits,
                        camera: camera)
                }
            },
            square: { appendSolidSquare(at: world[$0], shape: shape[$0], half: half, camera: camera) },
            corner: { index, first, second in
                // 細い線の折れ目は、2 本の帯の半幅と被覆の小さいほうで組む (細い帯の外へはみ出さない・#3734 の反証 #3)
                var joinHalf = half
                var coverage: Float?
                if let one = thinBand(first.0, first.1), let other = thinBand(second.0, second.1) {
                    joinHalf = min(one.half, other.half)
                    coverage = min(one.coverage, other.coverage)
                }
                covering(coverage) {
                    buildSolidJoin(
                        at: world[index], (world[first.0], world[first.1]), (world[second.0], world[second.1]),
                        join: style.strokeJoin, shape: shape[index], half: joinHalf, camera: camera)
                }
            })
    }

    /// 細い立体の線の開いた端を、画面の描く画素の列 (行) の境目で切る切り方 (#3745・``ThinEndCut``)。
    ///
    /// 端とみなすのは、辺が 1 本だけ来て、その辺が画面で長さを持つ点だけである。画面で重なる点の群 (``strokeNet``
    /// の群) の点は、群の中の潰れた辺も数えるので辺が 2 本以上来て、ここでは端にならず今までどおり線に垂直に切る。
    /// 曲線の刻みの点も切らない。端の形はどれも切る (`.round` は面積の等しい平らな延長にする・#3748・
    /// ``ThinEndCut/extent(of:weight:)``)。
    ///
    /// - 1 本の辺の両端が同じ列に入る (画面で短い線) なら、1 つの片にして割合は両端の差にする
    /// - 端の辺が端の列より短いときは、辺が 2 本だけ来る点をたどって、列の中で線が端の辺の向きからそれないときだけ
    ///   切る (``ThinEndCut/staysStraight(_:)``・平面と同じ)
    /// - 別の辺の端どうしの列の片が重なる (端点の重なる開いた周など) なら、その 2 つの端は切らない。片の割合が
    ///   同じ列を 2 度数えるからである。1 つにまとめた端の相方も、一緒に切らない (#3745 の反証 2)
    func solidEndCuts(
        world: [SIMD3<Float>], edges: [(Int, Int)], curveSteps: [Bool], thin: SolidThinBand, camera: StrokeCamera
    ) -> SolidEndCuts {
        let screen = SolidDrawnScreen(
            viewProjection: viewProjection, width: width, height: height, units: unitsPerDrawnPixel)
        var ends = SolidEndCuts(screen: screen, outputPerDrawn: thin.outputPerDrawn)
        let extend = ThinEndCut.extent(of: style.strokeCap, weight: thin.drawn)
        // 点ごとに来る辺の数と、最大 2 本の隣 (端の列の中をたどるのに使う)
        var degree = [Int](repeating: 0, count: world.count)
        var neighbors = [SIMD2<Int32>](repeating: SIMD2(-1, -1), count: world.count)
        var edgeOf = [Int](repeating: -1, count: world.count)
        for (number, (a, b)) in edges.enumerated() {
            for (point, other) in [(a, b), (b, a)] {
                if degree[point] < 2 { neighbors[point][degree[point]] = Int32(other) }
                degree[point] += 1
                edgeOf[point] = number
            }
        }
        var found: [SolidEndCuts.Piece] = []
        var firstOnEdge: [Int: Int] = [:]
        for point in world.indices where degree[point] == 1 {
            if point < curveSteps.count, curveSteps[point] { continue }
            let far = Int(neighbors[point][0])
            guard far != point, let toward = screenToward(world[point], world[far], camera: camera),
                let end = screen.locate(world[point]), let other = screen.locate(world[far])
            else { continue }
            let band = thin.band(along: toward)
            // 同じ辺の両端は、軸を揃える (45° ちょうどで向きの丸めにより軸が割れないように)
            let partner = firstOnEdge[edgeOf[point]]
            guard
                let cut = ThinEndCut(
                    end: end, far: other, extend: extend,
                    half: band.half / thin.outputPerDrawn, base: .zero, axis: partner.map { found[$0].cut.axis })
            else { continue }
            // 辺が 1 本の網 (2 点の線) でなければ、端の列の中で線がそれないかを見る
            if degree[far] != 1 {
                var (previous, current) = (point, far)
                var ended = false
                let straight = cut.staysStraight {
                    guard !ended else { return nil }
                    let here = current
                    if degree[here] == 2 {
                        let next = neighbors[here][0] == Int32(previous) ? neighbors[here][1] : neighbors[here][0]
                        (previous, current) = (here, Int(next))
                    } else {
                        ended = true
                    }
                    return screen.locate(world[here])
                }
                if !straight { continue }
            }
            if partner == nil { firstOnEdge[edgeOf[point]] = found.count }
            found.append(
                SolidEndCuts.Piece(point: point, far: far, edge: edgeOf[point], cut: cut, coverage: band.coverage))
        }
        // 同じ辺の両端が同じ列に入るなら 1 つにまとめる
        var merged: [Int: ThinEndCut] = [:]
        var mates: [Int: Int] = [:]
        for (second, piece) in found.enumerated() {
            guard let first = firstOnEdge[piece.edge], first != second,
                let one = ThinEndCut.merged(found[first].cut, piece.cut)
            else { continue }
            merged[first] = one
            mates[first] = second
            mates[second] = first
        }
        // 別の辺の端どうしで列の片が重なれば、両方とも切らない。囲みの箱は 1 度だけ組み、x の下端の順に並べて、
        // x で重なりうる相手 (下端が自分の上端より左) だけを比べる。既定の丸い端も切るので、開いた端を多く持つ網
        // (稜の途切れる点の多いモデルなど) でも端どうしを総当たりにしない (#3748 の反証 7。端 2 万の網で、総当たりの
        // 267 ms が 17 ms になる)
        var boxes: [(low: SIMD2<Float>, high: SIMD2<Float>)?] = []
        boxes.reserveCapacity(found.count)
        for (index, piece) in found.enumerated() { boxes.append((merged[index] ?? piece.cut).box) }
        var order: [(index: Int, low: Float, high: Float)] = []
        order.reserveCapacity(found.count)
        for (index, box) in boxes.enumerated() {
            if let box { order.append((index, box.low.x, box.high.x)) }
        }
        order.sort { $0.low < $1.low }
        var dropped = Set<Int>()
        for rank in order.indices {
            let first = order[rank].index
            guard let one = boxes[first] else { continue }
            for next in order[(rank + 1)...] {
                // x で重なるには、相手の下端が自分の上端より左にある (``ThinEndCut/overlap(_:_:)`` は隔たり 1/1000 画素を
                // 越えて重なるときだけ真)。並べてあるので、以後の相手も重ならない
                if next.low >= order[rank].high { break }
                let second = next.index
                guard found[second].edge != found[first].edge, let other = boxes[second],
                    ThinEndCut.overlap(one, other)
                else { continue }
                dropped.insert(first)
                dropped.insert(second)
            }
        }
        for index in Array(dropped) { if let mate = mates[index] { dropped.insert(mate) } }
        for (index, piece) in found.enumerated() where !dropped.contains(index) {
            // 1 つにまとめた片の相方も、端の帯を境目で切る (帯は空になる)
            ends.cuts[piece.point] = piece.cut
            if mates[index] != nil, merged[index] == nil { continue }
            var placed = piece
            if let one = merged[index] { placed.cut = one }
            ends.pieces.append(placed)
        }
        return ends
    }

    /// 画面の描く画素で組んだ凸多角形 `polygon` (辺 `along` の帯の上にある) を、世界の点へ戻して積む (#3745)。
    ///
    /// 頂点ごとに、画面の線の上の点と、線に垂直なずれ (描く画素) に分ける。線の上の点は、辺の上で画面の位置が
    /// そこへ写る点を射影の式で解いて世界へ戻し (``SolidDrawnScreen/parameter(_:_:axis:value:)``)、ずれは帯と同じく
    /// 画面に正対した横向き (``screenAcross(_:_:camera:)``) に `ずれ × その点の 1 画素の世界での長さ` だけ動かす。
    /// 画面ではちょうど組んだ頂点に写る。
    private func appendSolidCutPolygon(
        _ polygon: [SIMD2<Float>], along edge: (Int, Int), world: [SIMD3<Float>], shape: [SIMD3<Float>],
        ends: SolidEndCuts, camera: StrokeCamera
    ) {
        guard polygon.count >= 3 else { return }
        let (a, b) = (world[edge.0], world[edge.1])
        guard let start = ends.screen.locate(a), let end = ends.screen.locate(b),
            let across = screenAcross(a, b, camera: camera), let normal = camera.screenNormal(a, b)
        else { return }
        let delta = end - start
        let length = simd_length(delta)
        guard length > 0 else { return }
        let direction = delta / length
        let side = SIMD2(-direction.y, direction.x)
        // 画面の垂線 (世界の横向きが写る向き) と、描く画素で組んだ垂線の向きを揃える
        let flip: Float = dot(normal, side) >= 0 ? 1 : -1
        let axis = abs(direction.x) >= abs(direction.y) ? 0 : 1
        var lifted: [(position: SIMD3<Float>, shape: SIMD3<Float>)] = []
        lifted.reserveCapacity(polygon.count)
        for vertex in polygon {
            let offset = dot(vertex - start, side)
            let onLine = vertex - side * offset
            guard let parameter = ends.screen.parameter(a, b, axis: axis, value: onLine[axis]) else { return }
            let point = a + (b - a) * parameter
            let pixel = camera.worldPerPixel(at: point, height: height)
            let clamped = min(max(parameter, 0), 1)
            lifted.append(
                (
                    point + across * (flip * offset * ends.outputPerDrawn * pixel),
                    shape[edge.0] + (shape[edge.1] - shape[edge.0]) * clamped
                ))
        }
        for index in 2..<lifted.count {
            appendSolidStrokeTriangle(
                lifted[0].position, lifted[index - 1].position, lifted[index].position,
                shape: (lifted[0].shape, lifted[index - 1].shape, lifted[index].shape), camera: camera)
        }
    }

    /// 記録の間に CPU で積んだ組み込み立体の線を、**置くときに GPU で組める**ものなら覚える
    /// (``RetainedGPUStroke``・#1756)。
    ///
    /// 条件は、その場で描くときの ``placeGPUStroke(of:mesh:)`` と同じ (記録していないことを
    /// 除く) で、**記録した時点のスタイルで**判じる。骨 (``SolidStrokeGeometry``) はここでは
    /// 作らない — 置かれずに捨てられる形のために GPU の置き場を確保しない。骨が作れない
    /// 稜線 (開いた端) は、置くときに CPU の帯へ戻る。
    private func rememberGPUStroke(of source: SolidSource, from start: Int) {
        guard recordingShape, case .mesh = source, gpuStrokeStyleAllows(source),
            solidVertices.count > start
        else { return }
        recordedGPUStrokes.append(
            RetainedGPUStroke(
                source: source, matrix: transform.matrix, weight: style.strokeWeight,
                cap: style.strokeCap, color: style.stroke, uv: whiteUV,
                vertices: start..<solidVertices.count))
    }

    /// 記録した線 1 本を、**いまの視点で**組み直した頂点 (位置と形自身の座標)。
    ///
    /// 保持した形を置くときに、置いた後の点へ移した線を渡す (`placeSolid(_:of:instances:)`)。
    /// 組むのはその場の線と同じ手順 (``buildSolidStroke(_:)``) で、太さ・折れ目・端は記録した
    /// ときのものを使う — 輪郭の形は形の中で決まり、置くときのスタイルは効かない
    /// (`Sketch/createShape(_:)`)。頂点の数は記録と違ってよい。置く側が区間ごと差し替える。
    ///
    /// **細さは置く面で判断する** (#1637)。線は記録したときの太さを持ち、置く面の細かさで
    /// 描く画素で 1 画素より細くなるなら、広げた太さで組んで被覆を返す (呼ぶ側が頂点の
    /// ``SolidVertex/stroke`` に書く)。記録した面と置く面の細かさが違っても、その場で描いた
    /// 線と同じになる。点 1 つの線 (``SolidStrokePiece/isLonePoint``) は、細ければ画面の軸に
    /// 沿った正方形にする (その場の線の ``withThinSolidStroke(_:isPoint:_:)`` と同じ)。
    func rebuiltSolidStroke(
        _ piece: SolidStrokePiece
    ) -> (corners: [(position: SIMD3<Float>, shape: SIMD3<Float>, coverage: Float)], coverage: Float) {
        let thin = ThinStroke(drawnWeight: drawnSolidWeight(piece.weight), isPoint: piece.isLonePoint)
        // 寄せる量は線の太さから決まる (`liftedTowardViewer`)。組む太さで組む。細い線の帯は帯ごとに
        // 画面の向きで広げ直すので、片ごとの被覆も受け取る (``SolidThinBand``・#3734)
        let saved = (style.strokeWeight, style.strokeJoin, style.strokeCap, solidStrokeCoverage, solidThinBand)
        solidThinBand = thin != nil && !piece.isLonePoint ? solidThinBand(weight: piece.weight) : nil
        style.strokeWeight = piece.weight * (thin?.widen ?? 1)
        style.strokeJoin = piece.join
        style.strokeCap = thin != nil && piece.isLonePoint ? .square : piece.cap
        solidStrokeCoverage = thin?.coverage ?? 1
        solidStrokeCapture = []
        buildSolidStroke(piece.source)
        var built = solidStrokeCapture ?? []
        solidStrokeCapture = nil
        (style.strokeWeight, style.strokeJoin, style.strokeCap, solidStrokeCoverage, solidThinBand) = saved
        if piece.isReversed { Self.reverseTriangles(in: &built, from: 0) }
        return (built, thin?.coverage ?? 1)
    }

    /// 稜線を使い回す。**線を引いた形にだけ作る。**
    ///
    /// 球は半径だけでは稜線のつながりが変わらないので、半径1の形で控える (#1606)。箱・平面・円柱も、
    /// 溶接される点の組が寸法で変わらない範囲では単位の形で控える (#2386)。どちらも
    /// ``SolidShape/unitEdgeScaling`` が決める。使うときに点を軸ごとに伸ばし、利用者へ渡す形自身の
    /// 座標も元の寸法のまま保つ。範囲の外 (溶接の許容差が下限に張り付く・近傍の距離の二乗が溢れうる・
    /// 最も短い軸が許容差を割るほど細い寸法) と、ほかの形は寸法ごとに取り出す。
    func solidEdges(of source: SolidSource, mesh build: () -> SolidMesh) -> SolidEdges {
        if let (unit, scale) = unitEdgeScaling(of: source) {
            let key = SolidSource.mesh(unit)
            let net: SolidEdges
            if let cached = solidEdges[key] {
                net = cached
            } else {
                net = SolidEdges(unit.make())
                solidEdges.insert(net, for: key)
            }
            return net.scaled(by: scale)
        }
        if let cached = solidEdges[source] { return cached }
        let net = SolidEdges(build())
        solidEdges.insert(net, for: source)
        return net
    }

    /// 稜線を単位の形から広げてよい出どころなら、その単位の形と軸ごとの倍率。球は #1606 から
    /// 常に共有する。箱・平面・円柱は ``sharesUnitShapes`` が立つときだけ (検査が寸法ごとの経路と比べる口)。
    func unitEdgeScaling(of source: SolidSource) -> (unit: SolidShape, scale: SIMD3<Float>)? {
        guard case .mesh(let shape) = source, let scaling = shape.unitEdgeScaling else { return nil }
        if case .sphere = shape { return scaling }
        return sharesUnitShapes ? scaling : nil
    }

    /// 線分 1 本を帯にする。
    private func appendSolidBand(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>,
        shape: (SIMD3<Float>, SIMD3<Float>), half: Float, camera: StrokeCamera
    ) {
        guard length_squared(b - a) > 0 else { return }
        // 画面で点に潰れる線 (目を通る線・平行で視線に沿う線) は帯の幅を持たない。両端は画面で
        // 重なる 1 点として、その先の帯との折れ目か端の形を置く (`strokeNet` の群・#1893)
        guard let side = screenAcross(a, b, camera: camera) else { return }
        let atA = side * (half * camera.worldPerPixel(at: a, height: height))
        let atB = side * (half * camera.worldPerPixel(at: b, height: height))
        appendSolidStrokeTriangle(
            a + atA, b + atB, b - atB, shape: (shape.0, shape.1, shape.1), camera: camera)
        appendSolidStrokeTriangle(
            a + atA, b - atB, a - atA, shape: (shape.0, shape.1, shape.0), camera: camera)
    }

    /// 線分を画面に写したときの垂線を、**世界の向き**で返す。画面の画素で長さ 1 の向きを、世界の
    /// 向きに直したもの (`StrokeCamera.world(_:)`)。
    ///
    /// 向きは画面の横 (`camera.right`) と縦 (`camera.down`) の組み合わせ — 視線に直交する
    /// 面の中の向きなので、そちらへ `half × worldPerPixel(at:)` (縦の 1 画素の長さ) だけ動かすと、
    /// 画面でちょうど `half` 画素動く (透視でもその点の奥行きのまま動くため)。**画面の横と縦で 1 画素の
    /// 世界での長さが違う投影 (縦横比を面と違えた投影・#2176) では、横の成分に比 (`StrokeCamera.pixelAspect`)
    /// を掛けて世界の向きに直す**。画面で長さ `half` の動きが、世界では横に `half × 横の 1 画素`、
    /// 縦に `half × 縦の 1 画素` になる。
    ///
    /// **正対させる相手はカメラ全体の軸ではなく、画面に写った線である** (#1546)。
    /// 透視投影では、奥行きのある線は画面の中心から外れるほど斜めに写るので、軸との
    /// 外積で決めた横向きは画面の線とずれ、帯が細る (ずれが揃うと線が消える)。
    ///
    /// 透視では目と線を含む平面の法線 `cross(a − eye, b − eye)` を視点の座標で取る。
    /// その横と縦の成分が、画面に写した線の垂線の向きになる — 端点を割り算で画面へ
    /// 落とさないので、目の後ろへ回る端点があっても向きが決まる。平行投影では画面の
    /// 線は視点の座標での線そのものなので、その向きを 90° 回す。どちらも、画面の画素で
    /// 測った向きにするため、成分に横と縦の比を掛ける (`StrokeCamera.screenNormal`)。
    ///
    /// 画面での長さが 0 の線 (透視で目を通る線・平行で視線に沿う線) には `nil` を返す。
    private func screenAcross(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, camera: StrokeCamera
    ) -> SIMD3<Float>? {
        guard let normal = camera.screenNormal(a, b) else { return nil }
        return camera.world(normal)
    }

    /// 線分 a → b を画面に写したときの、a から b へ進む向き (画面の横と縦の成分・長さ 1)
    /// ([#1644])。決まらなければ `nil`。
    ///
    /// **世界での差の横と縦の成分では代われない。** 透視投影で奥へ引っ込む辺は、画面の中心
    /// から外れた所では、世界での差と画面での動きが逆を向きうる (中心より左の点から奥へ
    /// 引っ込む辺は、画面では右へ、中心へ寄っていく)。向きは `StrokeCamera.screenNormal` の垂線を 90° 回して
    /// 取る。垂線は a・b・目の張る平面の法線 (透視) か、画面の中の線を 90° 回したもの
    /// (平行) なので、回す向きは 2 つで逆になる (画面の横 × 縦 = −前 を使う)。目の手前にある
    /// 点では、どちらも画面で a から b へ進む向きになる。
    ///
    /// [#1644]: https://github.com/mokume-metal/mokume/issues/1644
    private func screenToward(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, camera: StrokeCamera
    ) -> SIMD2<Float>? {
        guard let normal = camera.screenNormal(a, b) else { return nil }
        return camera.isPerspective ? SIMD2(-normal.y, normal.x) : SIMD2(normal.y, -normal.x)
    }

    /// 視線に正対する円板を置く (丸い端点と丸い角・曲線の刻み)。
    ///
    /// **周は、画面に出る半径で刻む** ([#2011])。立体の線は太さを画面の画素 (出す画素) で測り、
    /// 奥にあるものほど世界では広く組むので、画面の半径は太さの半分 `half` そのもので、置き場所の
    /// 変換の拡大は掛からない。分割数は平面の円板と同じ式 (``segmentCount(forRadius:scale:)``) で
    /// 決める — 円周と多角形の隔たりは 0.25 画素以下で、上限は 1024 である。**下限は 16 に残す**
    /// (``solidDiscSegments(half:)``): 式が 16 未満を返す半径 13.01 画素 (太さ 26.02) 以下の円板は、
    /// 決め打ちの 16 角形だった頃と 1 ビットも変わらない。分割数を 16 に決め打ちしていた頃は、
    /// 太さ 60 の丸い端が画面で 0.58 画素角ばっていた。
    ///
    /// 周の点 `units` は、呼ぶ側が線 1 本につき 1 度だけ求めて渡す (``solidDiscUnits(half:)``)。
    /// GPU の骨の円板は 16 角形だけを持つ (``SolidStrokeGeometry``)。16 で足りない太さの丸い端は、
    /// GPU で組まずにここで組む (``gpuStrokeGeometry(of:weight:cap:mesh:)``)。
    ///
    /// [#2011]: https://github.com/mokume-metal/mokume/issues/2011
    private func appendSolidDisc(
        at center: SIMD3<Float>, shape: SIMD3<Float>, half: Float, units: [SIMD2<Float>],
        camera: StrokeCamera
    ) {
        let radius = half * camera.worldPerPixel(at: center, height: height)
        var previous = center + camera.screenRight * radius
        for unit in units.dropFirst() {
            let current = center + camera.world(unit) * radius
            appendSolidStrokeTriangle(
                center, previous, current, shape: (shape, shape, shape), camera: camera)
            previous = current
        }
    }

    /// 立体の線の円板の、一周の分割数 ([#2011])。`half` は画面の半径 (太さの半分・出す画素)。
    ///
    /// 平面の円板と同じ式 (``segmentCount(forRadius:scale:)``。拡大率は 1 — 立体の線の太さは、もう
    /// 画面の画素である) を、下限 ``solidDiscFloorSegments`` で抑える。数でない・負の半径は式が 3 を
    /// 返すので、下限に倒れる。
    ///
    /// [#2011]: https://github.com/mokume-metal/mokume/issues/2011
    static func solidDiscSegments(half: Float) -> Int {
        max(solidDiscFloorSegments, segmentCount(forRadius: half, scale: 1))
    }

    /// 立体の線の円板の分割数の下限で、GPU の骨の円板の分割数 ([#2011])。
    ///
    /// 下限を残すのは、細い線の円板を粗くしないためである。式どおりに決めると太さ 1 の円板は
    /// 3 分割になり、太さ 26 以下の立体の線の絵がすべて動く。
    ///
    /// **GPU の骨の円板も、この数に決め打ちである。** 変えるときは、ほかの 2 か所 —
    /// ``SolidStrokeGeometry`` の円板の片の数 (網の点ごとに 8 つ = この数の半分。`init(net:gpu:)`)
    /// と、`Shapes.metal` の周の点の表 `kSolidStrokeDisc[17]` (この数 + 1 個) — と、検査
    /// `SolidGPUStrokeTests.discUnitsMatchTheCPU` (表の宣言 `kSolidStrokeDisc[17]` を読む) も揃える。
    /// 揃えなければ、その検査が赤になる。
    nonisolated static let solidDiscFloorSegments = 16

    /// 円板の周の点の向き (画面の横と縦の成分)。半径 `half` の円板を ``solidDiscSegments(half:)``
    /// で刻んだ ``solidDiscUnits(segments:)``。下限の分割数なら、控えておいた表を返す。
    static func solidDiscUnits(half: Float) -> [SIMD2<Float>] {
        let segments = solidDiscSegments(half: half)
        return segments == solidDiscFloorSegments
            ? solidDiscFloorUnits : solidDiscUnits(segments: segments)
    }

    /// 一周を `segments` 等分した円板の周の点の向き (画面の横と縦の成分)。点は `segments + 1` 個で、
    /// 0 番は横そのもの、i 番は角 2πi/`segments` の `cos` / `sin` (最後の点は一周した点で、0 番と
    /// 丸めの差しか違わない)。
    nonisolated static func solidDiscUnits(segments: Int) -> [SIMD2<Float>] {
        (0...segments).map { step in
            guard step > 0 else { return SIMD2(1, 0) }
            let angle = 2 * Float.pi * Float(step) / Float(segments)
            return SIMD2(RuntimeMath.cos(angle), RuntimeMath.sin(angle))
        }
    }

    /// 下限の分割数 (16) の円板の周の点。**GPU の骨の円板 (`Shapes.metal` の `kSolidStrokeDisc`) は、
    /// この値を書き写して持つ** — 三角関数は GPU と CPU で丸めが違うので、同じ角の点を同じ値で置く
    /// ため (#1893)。GPU が円板を描くのは、分割数が下限で足りる太さだけである (#2011)。
    nonisolated static let solidDiscFloorUnits = solidDiscUnits(segments: solidDiscFloorSegments)

    /// 視線に正対する、丸めない折れ目の形を置く ([#1644])。
    ///
    /// 形は平面と同じ式 (``Canvas/joinRim(toward:_:half:join:)``) で、**画面に写した 2 本の
    /// 帯の向き**から決める。腕は (出る点, 向こうの点) の対で、帯の横向き (`screenAcross`) を画面の
    /// 横と縦の成分で持ち、それを 90° 回した向きを、角から向こうの点へ向かう向きとする。外側の縁の
    /// 角は、帯 (`appendSolidBand`) の縁の角と同じ式で置く。出る点は角そのものか、角と画面で重なる
    /// 点で (画面で重なる点の群・#1893)、形は角の位置に置く。
    ///
    /// 三角形は尖りなら 2 枚・切り口なら 3 枚・一直線なら 0 枚。帯の横向きが決まらない
    /// (画面で潰れた腕) なら何も置かない — 腕は網の骨 (`strokeNet`) が、画面で長さを持つ辺だけ
    /// から選んで渡す。
    ///
    /// - Parameter join: 形 (`miter` / `bevel`)。記録した形では、記録したときの形を渡す
    ///
    /// [#1644]: https://github.com/mokume-metal/mokume/issues/1644
    private func buildSolidJoin(
        at center: SIMD3<Float>, _ first: (SIMD3<Float>, SIMD3<Float>), _ second: (SIMD3<Float>, SIMD3<Float>),
        join: StrokeJoin, shape: SIMD3<Float>, half: Float, camera: StrokeCamera
    ) {
        guard let across1 = screenAcross(first.1, first.0, camera: camera),
            let across2 = screenAcross(second.0, second.1, camera: camera),
            let arm1 = screenToward(first.0, first.1, camera: camera),
            let arm2 = screenToward(second.0, second.1, camera: camera)
        else { return }
        func onScreen(_ vector: SIMD3<Float>) -> SIMD2<Float> { camera.onScreen(vector) }
        // 腕は画面に写した両隣への向き (`screenToward`)。世界での差を使うと、透視で奥へ
        // 引っ込む辺の向きを取り違え、外側の楔が埋まらない
        let rim = Self.joinRim(toward: arm1, arm2, half: 1, join: join)
        // 周は 角のすぐ内側・1 本目の外側の縁の角・(尖りか切り口)・2 本目の外側の縁の角
        guard rim.count >= 4, let lastOffset = rim.last else { return }
        let radius = half * camera.worldPerPixel(at: center, height: height)
        func placed(_ offset: SIMD2<Float>) -> SIMD3<Float> {
            center + camera.world(offset) * radius
        }
        // 外側の縁の角は、帯の縁の角と同じ式で置く
        let side1 = dot(rim[1], onScreen(across1)) > 0 ? across1 : -across1
        let side2 = dot(lastOffset, onScreen(across2)) > 0 ? across2 : -across2
        var corners: [SIMD3<Float>] = [placed(rim[0]), center + side1 * radius]
        for offset in rim.dropFirst(2).dropLast() { corners.append(placed(offset)) }
        corners.append(center + side2 * radius)
        for index in 1..<(corners.count - 1) {
            appendSolidStrokeTriangle(
                corners[0], corners[index], corners[index + 1], shape: (shape, shape, shape),
                camera: camera)
        }
    }

    /// 視線に正対し、線の向きに沿った楕円を置く (細い線の丸い端・#3734)。`across` は線に垂直に、`along` は線に沿って
    /// 出す半径 (出す画素)。軸は ``appendSolidSquare(at:awayFrom:shape:half:along:camera:)`` と同じで、周の点
    /// `units` は円板と同じ刻み (``solidDiscUnits(half:)``) を、楕円の 2 軸の座標として読む。向きが決まらなければ
    /// 半径 `across` の円板へ倒す。
    private func appendSolidEllipse(
        at center: SIMD3<Float>, awayFrom from: SIMD3<Float>, shape: SIMD3<Float>, across: Float, along: Float,
        units: [SIMD2<Float>], camera: StrokeCamera
    ) {
        guard let right = screenAcross(from, center, camera: camera) else {
            return appendSolidDisc(at: center, shape: shape, half: across, units: units, camera: camera)
        }
        let onScreen = camera.onScreen(right)
        let down = camera.world(SIMD2(-onScreen.y, onScreen.x))
        let pixel = camera.worldPerPixel(at: center, height: height)
        let (wide, long) = (right * (across * pixel), down * (along * pixel))
        var previous = center + wide
        for unit in units.dropFirst() {
            let current = center + wide * unit.x + long * unit.y
            appendSolidStrokeTriangle(center, previous, current, shape: (shape, shape, shape), camera: camera)
            previous = current
        }
    }

    /// 視線に正対し、画面の軸に沿った正方形を置く (向きの無い点の四角い端)。線の端の正方形は
    /// 線の向きに沿って置く (`appendSolidSquare(at:awayFrom:shape:half:camera:)`)。
    private func appendSolidSquare(
        at center: SIMD3<Float>, shape: SIMD3<Float>, half: Float, camera: StrokeCamera
    ) {
        appendSolidSquare(
            at: center, right: camera.screenRight, down: camera.down, shape: shape, half: half, camera: camera)
    }

    /// 視線に正対し、線の向きに沿った正方形を置く (出っ張らせる端 — [#1535])。
    ///
    /// 軸は帯 (`appendSolidBand`) と同じ横向き (画面に写した線の垂線 `screenAcross`) と、
    /// 画面の中でそれに直交する向き (画面に写した線の向き) で取る。帯と合わせて、画面で
    /// 見て線を太さの半分だけ延ばした形になる。
    ///
    /// `from` は、画面で重なる点の群の外にある端の帯の向こうの点で、網の骨 (`strokeNet`) が画面で
    /// 長さを持つ辺から選んで渡す ([#1893])。向きが決まらないときは、向きの無い点として画面の
    /// 軸に沿った正方形へ倒す。
    ///
    /// [#1535]: https://github.com/mokume-metal/mokume/issues/1535
    /// [#1893]: https://github.com/mokume-metal/mokume/issues/1893
    ///
    /// `along` は線に沿って出す長さの半分 (出す画素)。`nil` なら `half` と同じ (正方形)。細い線の端は、横を帯と
    /// 同じ幅にし、線に沿っては元の太さの半分だけ出す (``SolidThinBand/alongHalf``・#3734)。
    private func appendSolidSquare(
        at center: SIMD3<Float>, awayFrom from: SIMD3<Float>, shape: SIMD3<Float>,
        half: Float, along: Float? = nil, camera: StrokeCamera
    ) {
        guard let right = screenAcross(from, center, camera: camera) else {
            return appendSolidSquare(at: center, shape: shape, half: half, camera: camera)
        }
        // 正方形は中心について対称なので、画面の中で 90° 回す向きはどちらでもよい。回すのは
        // 画面の画素で測った成分である (縦横比を面と違えた投影では、世界の向きのまま回すと菱形になる)
        let onScreen = camera.onScreen(right)
        let down = camera.world(SIMD2(-onScreen.y, onScreen.x))
        appendSolidSquare(
            at: center, right: right, down: down, shape: shape, half: half, along: along ?? half, camera: camera)
    }

    /// 視線に正対する長方形を、`right` / `down` の 2 軸で張る。`right` の向きに `half`、`down` の向きに
    /// `along` (省けば `half`・正方形) だけ出す。
    private func appendSolidSquare(
        at center: SIMD3<Float>, right: SIMD3<Float>, down: SIMD3<Float>, shape: SIMD3<Float>,
        half: Float, along: Float? = nil, camera: StrokeCamera
    ) {
        let radius = half * camera.worldPerPixel(at: center, height: height)
        var a = center + (-right - down) * radius
        var b = center + (right - down) * radius
        var c = center + (right + down) * radius
        var d = center + (-right + down) * radius
        // 線に沿って違う長さを出す端だけ、長方形に組み直す (正方形の式はそのまま残し、細くない線の頂点を動かさない)
        if let along, along != half {
            let pixel = camera.worldPerPixel(at: center, height: height)
            let (across, lengthwise) = (right * (half * pixel), down * (along * pixel))
            a = center - across - lengthwise
            b = center + across - lengthwise
            c = center + across + lengthwise
            d = center - across + lengthwise
        }
        appendSolidStrokeTriangle(a, b, c, shape: (shape, shape, shape), camera: camera)
        appendSolidStrokeTriangle(a, c, d, shape: (shape, shape, shape), camera: camera)
    }

    private func appendSolidStrokeTriangle(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
        shape: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), camera: StrokeCamera
    ) {
        // 組み直しの間は積まずに、位置と形自身の座標だけを渡す (``rebuiltSolidStroke(_:)``)
        if solidStrokeCapture != nil {
            let coverage = solidStrokeCoverage
            solidStrokeCapture?.append((liftedTowardViewer(a, camera: camera), shape.0, coverage))
            solidStrokeCapture?.append((liftedTowardViewer(b, camera: camera), shape.1, coverage))
            solidStrokeCapture?.append((liftedTowardViewer(c, camera: camera), shape.2, coverage))
            return
        }
        // 輪郭の頂点を名乗る。頂点関数が画面で半画素寄せる (`SolidVertex.stroke`)。名乗る値は
        // 被覆を兼ねる (細い線を広げたとき 1 未満・#1637)
        let coverage = solidStrokeCoverage
        defer { if coverage < 1 { openBatchHasThinCoverage = true } }
        appendSolidVertex(
            position: liftedTowardViewer(a, camera: camera), shapePosition: shape.0, normal: .zero,
            isStroke: true, strokeCoverage: coverage, color: style.stroke)
        appendSolidVertex(
            position: liftedTowardViewer(b, camera: camera), shapePosition: shape.1, normal: .zero,
            isStroke: true, strokeCoverage: coverage, color: style.stroke)
        appendSolidVertex(
            position: liftedTowardViewer(c, camera: camera), shapePosition: shape.2, normal: .zero,
            isStroke: true, strokeCoverage: coverage, color: style.stroke)
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
    ///
    /// **縦横比を面と違えた投影では、1 画素の長さを横と縦の長いほうで測る** ([#2176])。帯の幅は
    /// 世界で横と縦に違う長さになるので (`StrokeCamera.world(_:)`)、寄せる量が縦の 1 画素の長さの
    /// ままだと、横の幅の側は傾いた面の奥行きの差を上回れず、線が食われる。**代償**は、寄せる量が長い側の
    /// 比 (`StrokeCamera.pixelAspect`) だけ増え、縦に傾いた面の奥の稜線が透けて見える範囲も、その比だけ
    /// 広がること (比が 1 以下のときは変わらない)。
    ///
    /// [#2176]: https://github.com/mokume-metal/mokume/issues/2176
    private func liftedTowardViewer(
        _ point: SIMD3<Float>, camera: StrokeCamera
    ) -> SIMD3<Float> {
        let lift = (style.strokeWeight + 1) * camera.liftPerPixel(at: point, height: height)
        if camera.isPerspective {
            let toEye = camera.eye - point
            let distance = length(toEye)
            guard distance > 0 else { return point }
            // 目を越えて裏へ回らないよう、目までの半分で止める
            return point + toEye / distance * min(lift, distance / 2)
        }
        return point - camera.forward * lift
    }
}

/// CPU で線を組む間に使う、視点から導いた量 ([#1785])。
///
/// ``Camera`` の `forward` / `right` / `down` は読むたびに正規化し直し (`right` と `down` は
/// `forward` もまた作り直す)、`worldPerPixel(at:width:height:)` は読むたびに `tan` を取る。帯 1 本で
/// 正規化が約 13 回・`tan` が約 8 回走っていた。線を組む間は視点が変わらないので、1 度だけ
/// 求めて持ち回る。
///
/// **式と演算の順は ``Camera`` と同じ**である。`worldPerPixel` の透視は
/// `2 * tan(fov / 2) * depth / height` を左から `((2 * tan) * depth) / height` と計算するので、
/// 先に `2 * tan(fov / 2)` を求めておいても同じ値になる (Swift は浮動小数の積和を縮約しない)。
///
/// **画面の横と縦で 1 画素の世界での長さが違う投影 (縦横比を面と違えた投影) に備える** ([#2176])。
/// 線の向きと形は画面の画素で測った座標 (横・縦) で決め、世界の向きへ直すときに横の成分へ比
/// `pixelAspect` (横の 1 画素 ÷ 縦の 1 画素) を掛ける (`world(_:)`)。長さは縦の 1 画素
/// (`worldPerPixel(at:height:)`) の何倍かで持つ。**比がちょうど 1 のときは、掛ける・割るのが
/// 1 ビットも値を変えないので、比を持たなかった頃と同じ値になる。**
///
/// [#1785]: https://github.com/mokume-metal/mokume/issues/1785
/// [#2176]: https://github.com/mokume-metal/mokume/issues/2176
struct StrokeCamera {
    let eye: SIMD3<Float>
    let forward: SIMD3<Float>
    let down: SIMD3<Float>
    /// 視点の横の軸。**画素の長さを持たないので、向きを世界へ直すのには使わない** — 画面の画素で測った
    /// 成分は `world(_:)`・`screenRight` を通す (縦横比を面と違えた投影で、横が伸びないように・#2176)。
    private let right: SIMD3<Float>
    let isPerspective: Bool
    /// 画面の横 1 画素の世界での長さ ÷ 縦 1 画素の世界での長さ (``Camera/pixelAspect(width:height:)``)。
    let pixelAspect: Float
    /// 画面の横 1 画素ぶんを、縦 1 画素ぶんを 1 として世界の向きと長さで表したもの
    /// (`right * pixelAspect`)。
    let screenRight: SIMD3<Float>
    /// 1 画素の長さの係数。透視は `2 * tan(fov / 2)`、平行は `abs(bottom - top)`。
    private let scale: Float
    /// 透視の手前の面。平行では使わない。
    private let near: Float

    init(_ camera: Camera, width: Float, height: Float) {
        eye = camera.eye.simd
        forward = camera.forward
        right = camera.right
        down = camera.down
        pixelAspect = camera.pixelAspect(width: width, height: height)
        screenRight = right * pixelAspect
        switch camera.projection {
        case let .perspective(fieldOfView, _, near, _):
            isPerspective = true
            scale = 2 * RuntimeMath.tan(fieldOfView / 2)
            self.near = near
        case let .orthographic(_, _, bottom, top, _, _):
            isPerspective = false
            scale = abs(bottom - top)
            near = 0
        }
    }

    /// ``Camera/worldPerPixel(at:width:height:)`` の縦 (`y`) と同じ値。横はこれに `pixelAspect` を掛ける。
    func worldPerPixel(at position: SIMD3<Float>, height: Float) -> Float {
        guard isPerspective else { return scale / height }
        let depth = max(dot(position - eye, forward), near)
        return scale * depth / height
    }

    /// 見ている側へ寄せる量の、1 画素ぶんの長さ。寄せるのは視線に沿った奥行きの向きなので、画面の
    /// 横と縦のどちらかの太さではなく、**長いほう**で測る — 帯のどの向きの幅も、寄せた先で面の
    /// 奥行きの差を上回る。横が縦より短い (比が 1 以下) なら縦のままで、比を持たなかった頃と同じ値になる。
    func liftPerPixel(at position: SIMD3<Float>, height: Float) -> Float {
        let vertical = worldPerPixel(at: position, height: height)
        return pixelAspect > 1 ? vertical * pixelAspect : vertical
    }

    /// 画面の画素で測った成分 (横, 縦) の向きを、世界の向きにする。
    func world(_ screen: SIMD2<Float>) -> SIMD3<Float> {
        screenRight * screen.x + down * screen.y
    }

    /// 視線に直交する面の中の世界の向きを、画面の画素で測った成分 (横, 縦) にする。`world(_:)` の逆。
    func onScreen(_ vector: SIMD3<Float>) -> SIMD2<Float> {
        SIMD2(dot(vector, right) / pixelAspect, dot(vector, down))
    }

    /// 外積。**成分ごとの積と差を明示し、縮約しない** (#3165)。simd の `cross` は clang が積和へ縮約する
    /// ので、GPU (`Shapes.metal` の `solidStrokeCross3`) と最終ビットが違いうる。Swift の式は縮約されない。
    static func crossUnfused(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    /// 線分 a–b を画面に写したときの垂線の、画面の画素で測った成分 (横, 縦・長さ 1)。決まらなければ `nil`。
    ///
    /// 視点の座標で取った垂線の横の成分に `pixelAspect` を掛けてから正規化する。透視は目と線を含む
    /// 平面の法線の横の成分に掛ける (平面の方程式 `横 × 法線の横 + 縦 × 法線の縦 + … = 0` を、画素の
    /// 座標 `横 = 画素の横 × 横の 1 画素 / 奥行き` で書き直すと、画素の座標での法線は
    /// `(法線の横 × 横の 1 画素, 法線の縦 × 縦の 1 画素)` に比例する)。平行は、線の向きの画面での成分が
    /// `(横 ÷ 横の 1 画素, 縦 ÷ 縦の 1 画素)` なので、それを 90° 回した垂線も同じく、視点の座標で回した
    /// 垂線 `(−縦, 横)` の横の成分に掛けた形に比例する。
    func screenNormal(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD2<Float>? {
        let normal: SIMD2<Float>
        if isPerspective {
            let plane = Self.crossUnfused(a - eye, b - eye)
            normal = SIMD2(dot(plane, right) * pixelAspect, dot(plane, down))
        } else {
            let along = b - a
            normal = SIMD2(-dot(along, down) * pixelAspect, dot(along, right))
        }
        let size = length(normal)
        guard size > 0, size.isFinite else { return nil }
        return SIMD2(normal.x / size, normal.y / size)
    }
}

extension Canvas {
    /// この立体の列を描く、特化したパイプラインの鍵 ([#1795]・[#2366])。特化できる列でなければ `nil`。
    /// **列を閉じるときに 1 度だけ出して列に持たせる** (``Batch/solidVariant``) — 描き切りは列ごとに
    /// 述語を評価し直さない。`isOpaqueFill` は「塗りの α がちょうど 1 と CPU で分かる列か」
    /// (``isOpaqueFill(_:closing:)``)。
    ///
    /// - **光の分岐を外す** (#1795): 断片が光の分岐に入る条件の否定そのもの (`mokume_shapeColor`) — 光が
    ///   1 つも効かず (`lighting.count == 0`)、周囲を置かず、列が周囲そのものを出す背景でもない。値は列を
    ///   閉じた時点のもので、列ごとに渡る値と同じなので、分岐は必ず偽になる。外しても画素は変わらない
    /// - **ブレンドを外す** (#2366): 重ねる列で、塗りの α がちょうど 1 の列。α = 1 の source-over は
    ///   `source + destination × 0` で、ブレンドなしの書き込みと一致する
    ///
    /// **約束の外が 1 つある: 下地の画素が数でない値・無限のとき。** ブレンドありは `0 × NaN`・`0 × Inf` が
    /// 数でない値になり、箱の上まで数でない値で埋まる。ブレンドなしは下地を読まないので、箱は有限の色で出る。
    /// 下地が有限の画素では 1 ビットも違わない。数でない値は利用者の計算 (画素の書き込みなど) が作るもので、
    /// 箱の上まで染めることを守る理由が無いので、ブレンドなしの結果を採る (`UnlitSolidTests` が違いを固定する)。
    ///
    /// 対象は組み込みの塗りだけである。**利用者の断片の列は、利用者の `shader()` を載せた
    /// パイプラインで描く** (``Shader``) ので外す。GPU で広げる立体の輪郭 (``Batch/strokeGeometry``) は
    /// 元から分岐を外した組で描き、**ブレンドなしの対象からは外す — 輪郭の頂点には被覆 (`coverage`) が付き、
    /// 1 未満になりうる縁では被覆が α を下げるので、塗りの α が 1 でも画素の α は 1 にならない**
    /// (下地を引く列でなければ、縁が下地と混ざらず画素が変わる)。GPU が色を書く粒 (外の置き場所) も
    /// CPU は α を知らないので外す。
    /// **面を置き換える板** (``Batch/replacesSurface``・`background(色)` を切り抜きの下で呼んだとき) は
    /// この経路を通らない — 列を閉じる側 (``closeSolidBatch()``) が出さないので、光を置いた絵の
    /// 背景の置き換えが組を 1 本増やすこともない。
    ///
    /// **列の選び方は既定の組と同じ** (``ShapePipeline/BlendStates/Column/init(drawing:)``)。細い線を
    /// 広げた頂点を持つ置き換える列は下地を読む列で描くので、鍵の列もそれに従う。細い線の被覆を持つ列は
    /// ブレンドなしにしない (被覆は α を下げる)。
    ///
    /// [#1795]: https://github.com/mokume-metal/mokume/issues/1795
    /// [#2366]: https://github.com/mokume-metal/mokume/issues/2366
    func solidVariantKey(
        of batch: Batch, opaque isOpaqueFill: @autoclosure () -> Bool
    ) -> ShapePipeline.SolidVariantKey? {
        guard batch.source == .solid && batch.strokeGeometry == nil && batch.run.paint.shader == nil
        else { return nil }
        let unlit =
            specializesUnlitSolids && batch.lightRange.isEmpty
            && !(batch.surroundings.topAndPresence.w > 0.5)
            && !(batch.surroundings.horizonAndBackdrop.w > 0.5)
        // 頂点と置き場所を読む判定は、ほかの条件が揃ったときだけ走らせる
        let unblended =
            specializesOpaqueSolids && batch.run.mode == .blend && !batch.thinCoverage
            && isOpaqueFill()
        guard unlit || unblended else { return nil }
        return ShapePipeline.SolidVariantKey(
            isUnitShape: batch.usesUnitShape, unlit: unlit, opaque: unblended,
            column: .init(drawing: batch))
    }

    /// 閉じようとしている立体の列の塗りが、どの画素でも α がちょうど 1 と CPU で分かるか ([#2366])。
    ///
    /// **ちょうど 1 だけ**を不透明と数える。`1` を超える不透明度は締めずに渡る (``LinearRGBA``) 口で、
    /// source-over は `source + destination × (1 − α)` と下地を引くが、ブレンドなしは `source` をそのまま
    /// 書くので、画素が変わる。数でない値も偽に倒す。裏面を捨てる判定 (``Batch/cullMode``・`< 1`) は別の
    /// 話で、あちらは今のまま残す — 裏面を捨てた列でも、ここで偽になれば今までどおりブレンドで描く。
    ///
    /// 見るのは、画素の α を決める 3 つ:
    ///
    /// 1. **置き場所の色** — 組み込みの形・読み込んだモデル・保持した形の置き場所 (外の置き場所は見えないので
    ///    偽)。
    /// 2. **頂点の色** — その場で並べた頂点 (輪郭の頂点を含む) は列の頂点を全部見る。保持した形は、置く形が
    ///    持つ判定 (``Shape/solidAlphaIsOne``) を列を開くときに写してある。組み込みの形・読み込んだモデルの
    ///    頂点は白。
    /// 3. **読む面** — 焼き場の白い区画か、白い 1 画素の絵だけ。貼る絵は透けた画素を持ちうる。
    ///
    /// 混ぜ方・断片・細い線の被覆は鍵を作る側が見る (``solidVariantKey(of:opaque:)``)。
    ///
    /// [#2366]: https://github.com/mokume-metal/mokume/issues/2366
    func isOpaqueFill(_ open: OpenSolid, closing batch: Batch) -> Bool {
        let onAtlas = batch.run.texture.texture === atlas.texture
        guard open.external == nil, open.strokeGeometry == nil,
            onAtlas || batch.run.texture.texture === blankPicture?.held.texture
        else { return false }
        // 置き場所の色
        for index in batch.instanceStart..<(batch.instanceStart + batch.instanceCount)
        where solidInstances[index].color.w != 1 {
            return false
        }
        // 頂点の色。焼き場の面を読む列は、読み取り位置が白い区画を指しているかも見る
        switch open.source {
        case .mesh, .model:
            return true
        case .retained, .retainedGeometry:
            return open.retainedVerticesAreOpaque && (!onAtlas || open.retainedReadsWhiteCell)
        case .freeform:
            for index in open.vertexStart..<(open.vertexStart + open.vertexCount) {
                let vertex = solidVertices[index]
                if vertex.color.w != 1 || (onAtlas && vertex.uv != whiteUV) { return false }
            }
            return true
        }
    }
}

/// 細い立体の線の開いた端の切り方 (#3745・``Canvas/solidEndCuts(world:edges:curveSteps:thin:camera:)``)。
nonisolated struct SolidEndCuts {
    /// 端の列の片 1 つ。
    struct Piece {
        /// 端の点と、端の辺の向こうの点。
        var point: Int
        var far: Int
        /// 端の辺の番号。
        var edge: Int
        var cut: ThinEndCut
        /// 端の辺の帯の被覆 (片には ``ThinEndCut/fraction`` を掛ける)。
        var coverage: Float
    }

    let screen: SolidDrawnScreen
    /// 描く画素 1 つの、出す画素での長さ。
    let outputPerDrawn: Float
    /// 点ごとの、その点から出る端の帯の切り方。
    var cuts: [Int: ThinEndCut] = [:]
    /// 積む端の列の片。
    var pieces: [Piece] = []
}

/// 立体の線の点を、**画面の描く画素の絶対座標**へ写す (#3745)。頂点関数の半画素の寄せ
/// (``Canvas/solidStrokeShift(width:height:)``・出す画素で +0.5) を含む。
nonisolated struct SolidDrawnScreen {
    let viewProjection: simd_float4x4
    let width: Float
    let height: Float
    /// 描く画素 1 つが出す画素でいくらか (``Canvas/unitsPerDrawnPixel``)。
    let units: SIMD2<Float>

    /// 世界の点 `point` の描く画素の座標。目の後ろの点は `nil`。
    func locate(_ point: SIMD3<Float>) -> SIMD2<Float>? {
        let clip = viewProjection * SIMD4(point, 1)
        guard clip.w > 0, clip.w.isFinite else { return nil }
        let canvas = SIMD2(
            (clip.x / clip.w + 1) * 0.5 * width + 0.5, (1 - clip.y / clip.w) * 0.5 * height + 0.5)
        let drawn = canvas / units
        return drawn.x.isFinite && drawn.y.isFinite ? drawn : nil
    }

    /// 線分 a → b の上で、描く画素の `axis` の成分が `value` に写る点の媒介変数 (a で 0・b で 1)。画面の線は
    /// 射影で写るので、切り取り座標で `成分 = 正規化した値 × w` を解く。決まらなければ `nil`。
    func parameter(_ a: SIMD3<Float>, _ b: SIMD3<Float>, axis: Int, value: Float) -> Float? {
        let (from, to) = (viewProjection * SIMD4(a, 1), viewProjection * SIMD4(b, 1))
        let target: Float
        let (start, end): (Float, Float)
        if axis == 0 {
            target = 2 * (value * units.x - 0.5) / width - 1
            (start, end) = (from.x, to.x)
        } else {
            target = 1 - 2 * (value * units.y - 0.5) / height
            (start, end) = (from.y, to.y)
        }
        let denominator = (end - start) - target * (to.w - from.w)
        guard denominator != 0 else { return nil }
        let parameter = (target * from.w - start) / denominator
        return parameter.isFinite ? parameter : nil
    }
}
