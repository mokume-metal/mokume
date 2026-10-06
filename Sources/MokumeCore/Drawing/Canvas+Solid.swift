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
    /// **同じ形の頂点は、描き切るまで 1 組を共有する。** 線で列が分かれても、塗りの
    /// 頂点を置き直さない。描く列は呼び出し順のまま、置き場所 (変換と塗り) を持つ。
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
    /// **同じ入力の頂点は、列をまたいで共有する。** 組み込みの形も読み込んだモデルも
    /// ここを通る。続く同じ出どころは配置をまとめ、離れた列は同じ頂点範囲を指す。
    ///
    /// **保持する形を記録している間だけは、置き場所を頂点へ焼く** ([#1297])。記録は置き場所を
    /// 持ち歩かない (``recordingShape``) ので、置き場所に変換と塗りを持たせたままだと、
    /// 置くときに形の原点へ白く落ちる。平面が記録の間は畳まずに頂点へ焼くのと同じ答えで、
    /// 捨てるのは**形の中での**畳みだけである — 組み上げた形を ``shape(_:at:)`` で何か所に
    /// 置いても、頂点 1 組と置き場所の並びで描くことは変わらない。
    ///
    /// [#1297]: https://github.com/mokume-metal/mokume/issues/1297
    func placeMesh(
        _ source: SolidSource, isDerived: Bool = false,
        winding: () -> SolidWinding = { .outward }, mesh build: () -> SolidMesh
    ) {
        // 区間の外では、立体の側へも移らない (``Canvas/canPlace``・#1672)
        guard canPlace else { return warnOutsideFrame(.placing) }
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
            let points = build().points
            var vertices: [SolidVertex] = []
            vertices.reserveCapacity(points.count)
            for point in points {
                vertices.append(meshVertex(point, isDerived: isDerived, textured: textured))
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
        if openSolid?.source != source || openSolid?.strokeGeometry != nil
            || openSolid?.isMirrored != placement.isMirrored
            || isBatchFull(solidInstances.count, since: openSolid?.instanceStart ?? 0)
        {
            // 列は分けても、描く順序と頂点の所有は別である。同じ入力なら既に積んだ範囲を指す。
            closeBatch()
            let key = SolidMeshRangeKey(
                source: source, isDerived: isDerived, textured: textured, whiteUV: whiteUV)
            // **読み込んだモデルは、頂点を GPU の置き場に持って使い回す** (#1749)。溜め場へ
            // 積まないので、列はその置き場の先頭から数える
            if case .model = source,
                let geometry = modelFill(
                    for: key, isDerived: isDerived, textured: textured, mesh: build)
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
                    solidVertices.append(meshVertex(point, isDerived: isDerived, textured: textured))
                }
                range = start..<solidVertices.count
                solidMeshRanges[key] = range
            }
            openSolid = OpenSolid(
                source: source, vertexStart: range.lowerBound, vertexCount: range.count,
                // 組み込みの形も読み込んだモデルも、頂点を並べた順にそのまま描く
                indexStart: nil,
                instanceStart: solidInstances.count, isMirrored: placement.isMirrored)
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
        for key: SolidMeshRangeKey, isDerived: Bool, textured: Bool,
        mesh build: () -> SolidMesh
    ) -> SolidFillGeometry? {
        if let cached = modelFills[key] { return cached }
        let points = build().points
        guard points.count * MemoryLayout<SolidVertex>.stride <= modelFills.budget / 2 else {
            return nil
        }
        var vertices: [SolidVertex] = []
        vertices.reserveCapacity(points.count)
        for point in points {
            vertices.append(meshVertex(point, isDerived: isDerived, textured: textured))
        }
        guard let made = try? SolidFillGeometry(vertices: vertices, gpu: gpu) else { return nil }
        modelFills.insert(made, for: key)
        return made
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
        placedBy placement: SolidInstance, parts: [SolidPart] = [],
        showsBackFaces: Bool? = nil, mirrored: Bool? = nil
    ) {
        // `showsBackFaces` と `mirrored` は、置き場所を先に掛けた頂点 (`placement` は単位) を積む
        // ときに、元の置き場所の判定を渡す口 (保持した形の線を組み直して差し込む・#1893)
        if indices != nil { openIndexedFreeformSolid() } else { openFreeformSolid() }
        let base = solidVertices.count
        notePlacedParts(
            parts, vertices: vertices, indices: indices, base: base,
            tinted: showsBackFaces ?? placementShowsBackFaces(placement, styled: false))
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
    /// 渡さなければ白い区画を読むので、貼る絵は塗りにしか効かない。
    func appendSolidVertex(
        position: SIMD3<Float>, shapePosition: SIMD3<Float>? = nil,
        normal: SIMD3<Float>, shapeNormal: SIMD3<Float>? = nil, isDerived: Bool = false,
        uv: SIMD2<Float>? = nil, isStroke: Bool = false, strokeCoverage: Float = 1,
        color: LinearRGBA
    ) {
        // **面の切り替えが先。** 切り替えは列を閉じるので、開いてから切り替えると
        // 開いたばかりの列が閉じられ、この頂点がどの列にも属さなくなる
        if uv != nil { useWrittenUVTexture() } else { useGlyphTexture() }
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
        let start = solidVertices.count
        build()
        guard recordingShape, solidVertices.count > start else { return }
        recordedSolidStrokes.append(
            SolidStrokePiece(
                source: source, weight: style.strokeWeight, join: style.strokeJoin, cap: style.strokeCap,
                vertexStart: start, vertexCount: solidVertices.count - start,
                isLonePoint: solidStrokeIsLonePoint))
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
        switch source {
        case let .ring(points, shapePoints, isClosed, steps):
            world = points
            shape = shapePoints
            curveSteps = steps
            let count = points.count
            if count == 1 {
                // 点が 1 つだけなら、向きの無い端点の形そのものを置く (平面の周と同じ)
                let camera = StrokeCamera(currentCamera)
                let half = style.strokeWeight / 2
                if style.strokeCap == .round {
                    appendSolidDisc(at: world[0], shape: shape[0], half: half, camera: camera)
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
        let half = style.strokeWeight / 2
        let camera = StrokeCamera(currentCamera)
        strokeNet(
            count: world.count, edges: edges, curveSteps: curveSteps,
            samePoint: { world[$0] == world[$1] },
            depth: { dot(world[$0] - camera.eye, camera.forward) },
            toward: { screenToward(world[$0], world[$1], camera: camera) },
            endSquare: {
                appendSolidSquare(
                    at: world[$0], awayFrom: world[$1], shape: shape[$0], half: half, camera: camera)
            },
            band: {
                appendSolidBand(world[$0], world[$1], shape: (shape[$0], shape[$1]), half: half, camera: camera)
            },
            disc: { appendSolidDisc(at: world[$0], shape: shape[$0], half: half, camera: camera) },
            square: { appendSolidSquare(at: world[$0], shape: shape[$0], half: half, camera: camera) },
            corner: { index, first, second in
                buildSolidJoin(
                    at: world[index], (world[first.0], world[first.1]), (world[second.0], world[second.1]),
                    join: style.strokeJoin, shape: shape[index], half: half, camera: camera)
            })
    }

    /// 記録の間に CPU で積んだ組み込み立体の線を、**置くときに GPU で組める**ものなら覚える
    /// (``RetainedGPUStroke``・#1756)。
    ///
    /// 条件は、その場で描くときの ``placeGPUStroke(of:mesh:)`` と同じ (記録していないことを
    /// 除く) で、**記録した時点のスタイルで**判じる。骨 (``SolidStrokeGeometry``) はここでは
    /// 作らない — 置かれずに捨てられる形のために GPU の置き場を確保しない。骨が作れない
    /// 稜線 (開いた端) は、置くときに CPU の帯へ戻る。
    private func rememberGPUStroke(of source: SolidSource, from start: Int) {
        guard recordingShape, gpuStrokeStyleAllows(source), solidVertices.count > start else {
            return
        }
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
    ) -> (corners: [(position: SIMD3<Float>, shape: SIMD3<Float>)], coverage: Float) {
        let thin = ThinStroke(drawnWeight: drawnSolidWeight(piece.weight), isPoint: piece.isLonePoint)
        // 寄せる量は線の太さから決まる (`liftedTowardViewer`)。組む太さで組む
        let saved = (style.strokeWeight, style.strokeJoin, style.strokeCap)
        style.strokeWeight = piece.weight * (thin?.widen ?? 1)
        style.strokeJoin = piece.join
        style.strokeCap = thin != nil && piece.isLonePoint ? .square : piece.cap
        solidStrokeCapture = []
        buildSolidStroke(piece.source)
        var built = solidStrokeCapture ?? []
        solidStrokeCapture = nil
        (style.strokeWeight, style.strokeJoin, style.strokeCap) = saved
        if piece.isReversed { Self.reverseTriangles(in: &built, from: 0) }
        return (built, thin?.coverage ?? 1)
    }

    /// 稜線を使い回す。**線を引いた形にだけ作る。**
    ///
    /// 球は半径だけでは稜線のつながりが変わらないので、半径1の形で控える (#1606)。
    /// 使うときに点を伸ばし、利用者へ渡す形自身の座標も元の半径のまま保つ。
    /// 溶接の許容差が下限に張り付く寸法と、近傍の距離の二乗が溢れうる寸法は除く。
    /// 非一様に伸ばす形も面の向きの判定が変わりうるので、寸法ごとに取り出す。
    func solidEdges(of source: SolidSource, mesh build: () -> SolidMesh) -> SolidEdges {
        if case .mesh(.sphere(let radius, let detail)) = source {
            let tolerance = radius * SolidEdges.weldScale
            // 溶接が探す隣の升目までの差は各軸2倍未満。距離の二乗にも余裕を持たせる。
            if tolerance >= Float.leastNormalMagnitude,
                tolerance <= sqrt(Float.greatestFiniteMagnitude) / 4
            {
                let unit = SolidShape.sphere(radius: 1, detail: detail)
                let key = SolidSource.mesh(unit)
                let net: SolidEdges
                if let cached = solidEdges[key] {
                    net = cached
                } else {
                    net = SolidEdges(unit.make())
                    solidEdges.insert(net, for: key)
                }
                return net.scaled(by: radius)
            }
        }
        if let cached = solidEdges[source] { return cached }
        let net = SolidEdges(build())
        solidEdges.insert(net, for: source)
        return net
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

    /// 線分を画面に写したときの垂線を、**世界の向き**で返す (長さ 1)。
    ///
    /// 向きは画面の横 (`camera.right`) と縦 (`camera.down`) の組み合わせ — 視線に直交する
    /// 面の中の向きなので、そちらへ `worldPerPixel(at:)` の長さだけ動かすと、画面で
    /// ちょうど 1 画素動く (透視でもその点の奥行きのまま動くため)。
    ///
    /// **正対させる相手はカメラ全体の軸ではなく、画面に写った線である** (#1546)。
    /// 透視投影では、奥行きのある線は画面の中心から外れるほど斜めに写るので、軸との
    /// 外積で決めた横向きは画面の線とずれ、帯が細る (ずれが揃うと線が消える)。
    ///
    /// 透視では目と線を含む平面の法線 `cross(a − eye, b − eye)` を視点の座標で取る。
    /// その横と縦の成分が、画面に写した線の垂線の向きになる — 端点を割り算で画面へ
    /// 落とさないので、目の後ろへ回る端点があっても向きが決まる。平行投影では画面の
    /// 線は視点の座標での線そのものなので、その向きを 90° 回す。
    ///
    /// 画面での長さが 0 の線 (透視で目を通る線・平行で視線に沿う線) には `nil` を返す。
    private func screenAcross(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, camera: StrokeCamera
    ) -> SIMD3<Float>? {
        guard let normal = screenNormal(a, b, camera: camera) else { return nil }
        return camera.right * normal.x + camera.down * normal.y
    }

    /// 線分 a–b を画面に写したときの垂線の、画面の横と縦の成分 (長さ 1)。`screenAcross` の
    /// 中身で、決まらなければ `nil`。
    private func screenNormal(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, camera: StrokeCamera
    ) -> SIMD2<Float>? {
        let (right, down) = (camera.right, camera.down)
        let normal: SIMD2<Float>
        if camera.isPerspective {
            let plane = cross(a - camera.eye, b - camera.eye)
            normal = SIMD2(dot(plane, right), dot(plane, down))
        } else {
            let along = b - a
            normal = SIMD2(-dot(along, down), dot(along, right))
        }
        let size = length(normal)
        guard size > 0, size.isFinite else { return nil }
        return SIMD2(normal.x / size, normal.y / size)
    }

    /// 線分 a → b を画面に写したときの、a から b へ進む向き (画面の横と縦の成分・長さ 1)
    /// ([#1644])。決まらなければ `nil`。
    ///
    /// **世界での差の横と縦の成分では代われない。** 透視投影で奥へ引っ込む辺は、画面の中心
    /// から外れた所では、世界での差と画面での動きが逆を向きうる (中心より左の点から奥へ
    /// 引っ込む辺は、画面では右へ、中心へ寄っていく)。向きは `screenNormal` の垂線を 90° 回して
    /// 取る。垂線は a・b・目の張る平面の法線 (透視) か、画面の中の線を 90° 回したもの
    /// (平行) なので、回す向きは 2 つで逆になる (画面の横 × 縦 = −前 を使う)。目の手前にある
    /// 点では、どちらも画面で a から b へ進む向きになる。
    ///
    /// [#1644]: https://github.com/mokume-metal/mokume/issues/1644
    private func screenToward(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, camera: StrokeCamera
    ) -> SIMD2<Float>? {
        guard let normal = screenNormal(a, b, camera: camera) else { return nil }
        return camera.isPerspective ? SIMD2(-normal.y, normal.x) : SIMD2(normal.y, -normal.x)
    }

    /// 視線に正対する円板を置く (丸い端点と丸い角)。
    private func appendSolidDisc(
        at center: SIMD3<Float>, shape: SIMD3<Float>, half: Float, camera: StrokeCamera
    ) {
        let radius = half * camera.worldPerPixel(at: center, height: height)
        var previous = center + camera.right * radius
        for unit in Self.solidDiscUnits.dropFirst() {
            let current = center + (camera.right * unit.x + camera.down * unit.y) * radius
            appendSolidStrokeTriangle(
                center, previous, current, shape: (shape, shape, shape), camera: camera)
            previous = current
        }
    }

    /// 円板の周の 16 等分の点の向き (画面の横と縦の成分)。0 番は横そのもので、i 番は角 2πi/16 の
    /// `cos` / `sin`。**GPU の骨の円板 (`Shapes.metal` の `kSolidStrokeDisc`) は、この値を書き写して
    /// 持つ** — 三角関数は GPU と CPU で丸めが違うので、同じ角の点を同じ値で置くため (#1893)。
    nonisolated static let solidDiscUnits: [SIMD2<Float>] = (0...16).map { step in
        guard step > 0 else { return SIMD2(1, 0) }
        let angle = 2 * Float.pi * Float(step) / 16
        return SIMD2(cos(angle), sin(angle))
    }

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
        let (right, down) = (camera.right, camera.down)
        func onScreen(_ vector: SIMD3<Float>) -> SIMD2<Float> {
            SIMD2(dot(vector, right), dot(vector, down))
        }
        // 腕は画面に写した両隣への向き (`screenToward`)。世界での差を使うと、透視で奥へ
        // 引っ込む辺の向きを取り違え、外側の楔が埋まらない
        let rim = Self.joinRim(toward: arm1, arm2, half: 1, join: join)
        // 周は 角のすぐ内側・1 本目の外側の縁の角・(尖りか切り口)・2 本目の外側の縁の角
        guard rim.count >= 4, let lastOffset = rim.last else { return }
        let radius = half * camera.worldPerPixel(at: center, height: height)
        func placed(_ offset: SIMD2<Float>) -> SIMD3<Float> {
            center + (right * offset.x + down * offset.y) * radius
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

    /// 視線に正対し、画面の軸に沿った正方形を置く (向きの無い点の四角い端)。線の端の正方形は
    /// 線の向きに沿って置く (`appendSolidSquare(at:awayFrom:shape:half:camera:)`)。
    private func appendSolidSquare(
        at center: SIMD3<Float>, shape: SIMD3<Float>, half: Float, camera: StrokeCamera
    ) {
        appendSolidSquare(
            at: center, right: camera.right, down: camera.down, shape: shape, half: half, camera: camera)
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
    private func appendSolidSquare(
        at center: SIMD3<Float>, awayFrom from: SIMD3<Float>, shape: SIMD3<Float>,
        half: Float, camera: StrokeCamera
    ) {
        guard let right = screenAcross(from, center, camera: camera) else {
            return appendSolidSquare(at: center, shape: shape, half: half, camera: camera)
        }
        // 正方形は中心について対称なので、画面の中で 90° 回す向きはどちらでもよい
        let down = camera.right * -dot(right, camera.down) + camera.down * dot(right, camera.right)
        appendSolidSquare(at: center, right: right, down: down, shape: shape, half: half, camera: camera)
    }

    /// 視線に正対する正方形を、`right` / `down` の 2 軸で張る。
    private func appendSolidSquare(
        at center: SIMD3<Float>, right: SIMD3<Float>, down: SIMD3<Float>, shape: SIMD3<Float>,
        half: Float, camera: StrokeCamera
    ) {
        let radius = half * camera.worldPerPixel(at: center, height: height)
        let a = center + (-right - down) * radius
        let b = center + (right - down) * radius
        let c = center + (right + down) * radius
        let d = center + (-right + down) * radius
        appendSolidStrokeTriangle(a, b, c, shape: (shape, shape, shape), camera: camera)
        appendSolidStrokeTriangle(a, c, d, shape: (shape, shape, shape), camera: camera)
    }

    private func appendSolidStrokeTriangle(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>,
        shape: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), camera: StrokeCamera
    ) {
        // 組み直しの間は積まずに、位置と形自身の座標だけを渡す (``rebuiltSolidStroke(_:)``)
        if solidStrokeCapture != nil {
            solidStrokeCapture?.append((liftedTowardViewer(a, camera: camera), shape.0))
            solidStrokeCapture?.append((liftedTowardViewer(b, camera: camera), shape.1))
            solidStrokeCapture?.append((liftedTowardViewer(c, camera: camera), shape.2))
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
    private func liftedTowardViewer(
        _ point: SIMD3<Float>, camera: StrokeCamera
    ) -> SIMD3<Float> {
        let lift = (style.strokeWeight + 1) * camera.worldPerPixel(at: point, height: height)
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
/// `forward` もまた作り直す)、`worldPerPixel(at:height:)` は読むたびに `tan` を取る。帯 1 本で
/// 正規化が約 13 回・`tan` が約 8 回走っていた。線を組む間は視点が変わらないので、1 度だけ
/// 求めて持ち回る。
///
/// **式と演算の順は ``Camera`` と同じ**である。`worldPerPixel` の透視は
/// `2 * tan(fov / 2) * depth / height` を左から `((2 * tan) * depth) / height` と計算するので、
/// 先に `2 * tan(fov / 2)` を求めておいても同じ値になる (Swift は浮動小数の積和を縮約しない)。
///
/// [#1785]: https://github.com/mokume-metal/mokume/issues/1785
struct StrokeCamera {
    let eye: SIMD3<Float>
    let forward: SIMD3<Float>
    let right: SIMD3<Float>
    let down: SIMD3<Float>
    let isPerspective: Bool
    /// 1 画素の長さの係数。透視は `2 * tan(fov / 2)`、平行は `abs(bottom - top)`。
    private let scale: Float
    /// 透視の手前の面。平行では使わない。
    private let near: Float

    init(_ camera: Camera) {
        eye = camera.eye
        forward = camera.forward
        right = camera.right
        down = camera.down
        switch camera.projection {
        case let .perspective(fieldOfView, _, near, _):
            isPerspective = true
            scale = 2 * tan(fieldOfView / 2)
            self.near = near
        case let .orthographic(_, _, bottom, top, _, _):
            isPerspective = false
            scale = abs(bottom - top)
            near = 0
        }
    }

    /// ``Camera/worldPerPixel(at:height:)`` と同じ値。
    func worldPerPixel(at position: SIMD3<Float>, height: Float) -> Float {
        guard isPerspective else { return scale / height }
        let depth = max(dot(position - eye, forward), near)
        return scale * depth / height
    }
}
