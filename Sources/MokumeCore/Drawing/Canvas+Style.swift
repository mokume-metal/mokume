// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 描く状態を書き換える口と、その状態で列を閉じる仕組み。`Canvas.swift` の
// MARK「状態」を、区画ごとここへ移した ([#943](https://github.com/mokume-metal/mokume/issues/943))。
//
// **説明文は置かない。** 正本は上の層 (ADR-0020 決定 4) で、api-surface.py の
// slash_doc は宣言の直前に積んだ `//` も説明文として拾う。この覚え書きが
// 拾われないよう、宣言との間は必ず 1 行空ける。

import Metal
import simd

extension Canvas {

    public func fill(_ color: LinearRGBA) {
        // 数でない成分・無限の成分は、塗りを変えずに断る。数の形と同じ鍵で言う (#1706)
        guard color.isFinite else { return warnNotANumberColor(.fill) }
        style.fill = color
        style.hasFill = true
    }

    /// 図形の内側を塗らない。
    public func noFill() { style.hasFill = false }

    public func stroke(_ color: LinearRGBA) {
        guard color.isFinite else { return warnNotANumberColor(.stroke) }
        style.stroke = color
        style.hasStroke = true
    }

    /// 線を引かない。図形の輪郭も出なくなる。
    public func noStroke() { style.hasStroke = false }

    public func strokeWeight(_ weight: some ScalarConvertible) {
        let weight = weight.asFloat
        // 負の太さ・数でない値・無限は 0 にして、1 度知らせる (#1698)。`>=` は NaN も弾く。
        // 無限を通すと、形の経路 (`appendForm`) が形ごと黙って捨て、塗りも出ない (#1698 の
        // 反証 5)。字の大きさ (`textMeasure`) が無限を 0 にするのと揃える
        guard weight >= 0, weight.isFinite else {
            warnRounded(
                .badStrokeWeight, "strokeWeight", "the weight", takes: "a finite value of 0 or more",
                passed: weight, used: 0)
            style.strokeWeight = 0
            return
        }
        style.strokeWeight = weight
    }

    // 溜めている列をその場で閉じる (混ぜ方と同じ理由)。
    //
    // 面の外へ出た指定を面の内側へ収めるのは、この世代の GPU が範囲外の切り抜きを
    // 受け取ると検証で落ちるためである。指定をそのまま渡さない。
    //
    // **矩形は出す画素の小数のまま覚える** ([#1641])。画素へ丸めるのは描く画素が決まる
    // 所 (``scissor(_:)``) の 1 か所だけで、ここで整数へ切り捨てると、細かさ 1 では左右とも
    // 左へ寄り、細かさ 1 未満では丸めが 2 段に重なる。
    //
    // [#1641]: https://github.com/mokume-metal/mokume/issues/1641
    public func clip(_ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible) {
        // **切り抜きはフレームを越えない** (ADR-0021 決定 4)。描画先の座標で効き、形に焼き付か
        // ないので、形の組み立ての中ではフレームの中でも断る (同 決定 4 の追補・#1529)。値の
        // 検めより先に断る
        guard admits(.clip) else { return }
        let (a, b, c, d) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat)
        // 数でない値・無限は、収めた先が決まらない。切り抜きを触らずに返す
        // (ADR-0020 決定 5 の「安全な既定へ倒す」・他の入口と同じ倒し方)
        guard a.isFinite, b.isFinite, c.isFinite, d.isFinite else { return warnBadClipOnce() }
        let box = Self.resolveBox(a, b, c, d, mode: style.rectMode)
        // **`Float` のまま面の内へ収める。** 画素へ丸めるのは ``scissor(_:)`` で、そこでは
        // 面の内の値しか `Int` にしない (`Int(_:Float)` は面より桁違いに大きい値でトラップする・
        // [#1302])。入力が有限でも、読み方を解く算術 (`c * 2`) は ±∞ へ溢れうる
        //
        // [#1302]: https://github.com/mokume-metal/mokume/issues/1302
        let left = min(max(0, box.x), width)
        let top = min(max(0, box.y), height)
        let right = min(max(left, box.x + box.width), width)
        let bottom = min(max(top, box.y + box.height), height)
        closeBatch()
        style.clip = ClipRect(left: left, top: top, right: right, bottom: bottom)
    }

    public func noClip() {
        // 切り抜きの無いフレームの外でも言う。フレームの外では何も変えない口も、書いた
        // ことを知らせる (変換の `resetMatrix()` / `popMatrix()` と同じ扱い・#970)
        guard admits(.clip) else { return }
        guard style.clip != nil else { return }
        closeBatch()
        style.clip = nil
    }

    /// 収めようのない切り抜きを、初回だけ知らせる。
    ///
    /// 毎フレーム起きうるので繰り返さない (``Diagnostics/warn(_:)`` の但し書き)。
    private func warnBadClipOnce() {
        warnOnce(
            .badClip,
            "clip(): got a coordinate that is not a number, or an infinite one, so the clip was "
                + "left as it was")
    }

    /// 描くものを、下にある絵とどう混ぜるか。
    ///
    /// **溜めている列をその場で閉じる。** 既に置いた図形が後の混ぜ方で描かれないように
    /// するためで、閉じ忘れは「設定を変えたときだけ絵が崩れる」形で現れる。
    public func blendMode(_ mode: BlendMode) {
        guard mode != style.blendMode else { return }
        closeBatch()
        style.blendMode = mode
    }

    /// 描き切りが描く位置をどれだけ揺らすか (描く先の画素・[#1913])。**列を落とす行列は、どれも
    /// この 1 つの規則で揺らす** (``jittered(_:drawingInFrame:)``)。
    ///
    /// 選ぶのは、**描く先に既にある絵と同じ揺らし**である。描く先の絵は、それを最初に出す先へ広げる
    /// 拡大が同じ揺らしを戻すので、その時点で揃う。
    ///
    /// - フレームの描き切り (フレームの中の途中の描き切りと、フレームの終わりの描き切り): このフレームで
    ///   描く絵と同じ、次に広げるフレームの揺らし。フレームの終わりの拡大が ``UpscaleStage/jitterInSource``
    ///   で戻す
    /// - フレームの外の描き切り (`setup()` と止まっている間のコールバックで描き切らせる): 描く先に残る
    ///   最後のフレームの絵と同じ、最後に広げたフレームの揺らし。追い付き
    ///   (``catchUpOutput(writingBackPixels:)``) が ``UpscaleStage/lastJitterInSource`` で戻す。描く先の上
    ///   では最後のフレームに描いた絵とまったく同じ絵になるので、効果の前の控え (同じ列・同じ値で描く) と
    ///   奥行き (同じ描き切りが書く) も含めて、以後は最後のフレームの絵と同じに扱われる
    ///
    /// **代償 (時間方向がもともと負うもの):** 次に描くフレームの終わりの拡大は、描く先の全体を次の揺らし
    /// で戻し、履歴を位置で合わせ直さない (`kEffectAccumulate`)。だから塗り直さないスケッチでは、描く先に
    /// 残った絵は次のフレームで揺らしの差 (最大で描く画素 1 個弱) だけずれて混ざる。フレームの外で
    /// 描き切らせた図形も、前のフレームに描いた絵と一緒に同じだけずれる (追い付きが走らずに次のフレームへ
    /// 進む形 — 同じコールバックで `redraw()` を呼ぶ — でも同じ)。
    ///
    /// **列を閉じる時点ではなく、描き切る時点で選ぶ。** 止まっている間に置いて閉じた列 (混ぜ方の
    /// 切り替えで閉じる) も、描き切らせなければ次のフレームの描き切りで描かれ、そのフレームの揺らしで
    /// 戻される。閉じる時点の状態で選ぶと、こちらがずれる。
    ///
    /// 空間方向では揺らさない (``UpscaleStage/jitter`` が 0)。まだ 1 枚も広げていなければ、2 つは
    /// 同じである。
    ///
    /// [#1913]: https://github.com/mokume-metal/mokume/issues/1913
    func jitter(drawingInFrame: Bool) -> SIMD2<Float> {
        guard let stage = upscaleStage else { return .zero }
        return drawingInFrame ? stage.jitter : stage.lastJitter
    }

    /// 落とす行列に、描き切りの揺らし (``jitter(drawingInFrame:)``) を足す。**描き切りが列ごとの値を
    /// 置くときに足す** — 列 (`Batch.matrix`) には揺らす前の行列を持たせる。
    ///
    /// **見る窓ではなく行列を動かす。** 窓の原点は画素の単位へ丸められる (実測) ので、
    /// 画素の内側を揺らせない。行列なら切り取りの立方体の上で足せる。
    ///
    /// 足すのは切り取りの立方体の座標なので、割る前の高さぶんを掛けて足す — 立体は
    /// 遠いほど `w` が大きく、定数を足すと奥ほど揺れなくなる。
    func jittered(_ matrix: simd_float4x4, drawingInFrame: Bool) -> simd_float4x4 {
        let offset = jitter(drawingInFrame: drawingInFrame)
        guard offset != .zero else { return matrix }
        var shift = matrix_identity_float4x4
        shift.columns.3.x = offset.x * 2 / Float(pixelWidth)
        // 縦は落とす行列が向きを裏返しているので、面の下向きは立方体の上では逆になる
        shift.columns.3.y = -offset.y * 2 / Float(pixelHeight)
        return shift * matrix
    }

    /// 切り抜きを、実際に刻む画素へ写す ([#1641])。
    ///
    /// **画素の中心が矩形の内 (縁の上を含む) にある画素を通す。** 覆う割合が半分以上の画素を
    /// 通すことに当たり、同じ矩形の `rect` を 50% で白黒にした形と一致する (ADR-0039 決定 1)。
    /// ちょうど半分の画素は通す側に倒す — 同じ矩形の切り抜きが、その矩形の縁を削らない。
    ///
    /// 切り抜きは利用者が出す細かさの座標で指定するので、描く画素へは ``unitsPerDrawnPixel``
    /// で写してから同じ規則で丸める。**細かさ 1 未満では描く画素の格子でしか切れない**ので、
    /// 縁のずれは描く画素の半分 (細かさ 0.5 で出す画素 1 つ) まで残る。
    ///
    /// **丸めたあとで面の内側へ収める** — この世代の GPU は範囲外の切り抜きを受け取ると
    /// 検証で落ちる。幅か高さが 0 の矩形は、縁の上の画素も通さない。
    ///
    /// [#1641]: https://github.com/mokume-metal/mokume/issues/1641
    func scissor(_ clip: ClipRect?) -> MTLScissorRect {
        guard let clip else {
            return MTLScissorRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        }
        let drawnPerOutput = 1 / unitsPerDrawnPixel
        /// 中心が `[low, high]` に入る画素の範囲 (端は含まない上限)。値は面の内に収めてあるので、
        /// 描く画素へ写しても `Int` に収まる
        func span(_ low: Float, _ high: Float, scale: Float, limit: Int) -> (start: Int, end: Int) {
            guard high > low else { return (0, 0) }
            let start = min(max(0, Int((low * scale - 0.5).rounded(.up))), limit)
            let end = min(max(start, Int((high * scale - 0.5).rounded(.down)) + 1), limit)
            return (start, end)
        }
        let (left, right) = span(clip.left, clip.right, scale: drawnPerOutput.x, limit: pixelWidth)
        let (top, bottom) = span(clip.top, clip.bottom, scale: drawnPerOutput.y, limit: pixelHeight)
        return MTLScissorRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// 切り抜きの矩形。**出す画素の小数のまま**、面の内へ収めて覚える ([#1641])。画素へ
    /// 丸めるのは ``scissor(_:)`` だけである。
    ///
    /// [#1641]: https://github.com/mokume-metal/mokume/issues/1641
    struct ClipRect: Equatable {
        var left: Float
        var top: Float
        var right: Float
        var bottom: Float
    }

    /// 溜めている頂点を、いまの混ぜ方の列として閉じる。
    ///
    /// 位置は**その並びの中で**数える。平面と立体は別の並びに溜まるので、それぞれの
    /// 最後の列の終わりが次の列の始まりになる。
    func closeBatch() {
        // 細い線を広げた頂点の印は、閉じた列が持っていく (#1637)。閉じる列が無くても下ろす
        defer { openBatchHasThinCoverage = false }
        // **`switch` で振る。** `if` 連鎖だと `VertexSource` にケースが増えた日、
        // ここだけ黙って平面の経路へ落ちる (他の 5 箇所は `switch` なので止まる)
        switch openSource {
        case .solid: return closeSolidBatch()
        case .form: return closeFormBatch()
        case .flat: break
        }
        // **雛形は列と一緒に閉じる。** 開いたままにすると、次に来た同じ形が「もう閉じた
        // 列の頂点」を指す置き場所を足してしまう
        let template = openFlat
        openFlat = nil
        // 後ろから探す。閉包を標準ライブラリへ渡すと、列ごとに隔離の実行時検査を払う (#1779)
        var start = 0
        for batch in batches.reversed() where batch.source == .flat {
            start = batch.run.start + batch.run.count
            break
        }
        let count = vertices.count - start
        guard count > 0 else { return }
        batches.append(
            Batch(
                run: Shape.Run(
                    mode: style.blendMode, texture: currentTexture,
                    paint: effectivePaint,
                    source: .flat, start: start, count: count, indexStart: 0, indexCount: 0),
                clip: style.clip,
                // ここへ来るのは平面だけ (上の `switch` が他を返している)。**平面は
                // 奥行きを持たないので視点行列を通さず、光も受けない** — 立体の側は
                // `closeSolidBatch` が視点行列と閉じた時点の光を持って閉じる
                matrix: projection,
                lightRange: 0..<0,
                material: .default,
                viewer: SIMD4(0, 0, -1, 0),
                // 平面は面の向きを持たない (断片へは 0 が届く) ので、移す行列は効かない
                view: matrix_identity_float4x4,
                surroundings: bakeSurroundings(),
                castsShadow: false,
                // 畳んでいない列は、何も動かさない置き場所 (添字 0) を 1 つ通る
                instanceStart: template?.instanceStart ?? 0,
                instanceCount: template.map { flatInstances.count - $0.instanceStart } ?? 1,
                strokeStart: template?.strokeStart ?? .max))
        batches[batches.count - 1].thinCoverage = openBatchHasThinCoverage
    }

    /// 断片へ渡す面を、いま列に写し取る ([#407](https://github.com/mokume-metal/mokume/issues/407))。
    ///
    /// 並びは宣言と同じ名前順。**置いた記録はここでは取らない** — 塗りを比べるだけの読み
    /// (``usePaint(_:)``) もここを通るので、取ると置いていない描き場所まで記録が残る。記録は
    /// 図形を積む口 (``notePaintPlacement()``) が取る。
    private func snapshotSurfaces() -> [HeldTexture] {
        guard let shader = currentShader, !shader.surfaces.isEmpty else { return [] }
        return shader.orderedSurfaces.map(\.held)
    }

    /// いま生きている状態 (``shader(_:)`` / ``numbers(_:)``) から作る塗り。
    private var livePaint: Shape.Paint {
        Shape.Paint(
            shader: currentShader, values: currentShader?.packedValues ?? [],
            surfaces: snapshotSurfaces(), numbers: currentNumbers)
    }

    /// いま列を閉じたら、その列が持つ塗り。
    ///
    /// **保持した形を置いている間は、記録した塗りが勝つ。** 生きている状態から作るのは、
    /// 記録した塗りが無いとき (いつもの描画) だけである。
    var effectivePaint: Shape.Paint { replayedPaint ?? livePaint }

    /// 記録した塗りへ移る。
    ///
    /// **同じなら列は閉じない**ので、続けて置いた形は前の形と同じ列に並び、描く回数は
    /// 増えない (``blendMode(_:)`` / ``useTexture(_:)`` と同じ規則)。
    func usePaint(_ paint: Shape.Paint) {
        guard paint != effectivePaint else { return }
        // **先に閉じる。** ここまでに置いた頂点は、移る前の塗りのものである
        closeBatch()
        replayedPaint = paint
    }

    /// 記録した塗りを外し、生きている状態へ戻す。
    ///
    /// **戻す操作が列を閉じる**ので、いま置いた頂点は記録した塗りで描かれる。閉じるのは
    /// 生きている塗りと違うときだけで、同じなら次に描くものと 1 列に並ぶ。
    func stopReplayingPaint() {
        guard let replayed = replayedPaint else { return }
        if replayed != livePaint { closeBatch() }
        replayedPaint = nil
    }

    /// 開いている雛形を閉じる。**畳めない頂点を置く前に呼ぶ。**
    ///
    /// 字・画像・その場で並べた頂点が雛形の列へ紛れ込むと、置き場所の数だけ**それらも
    /// 繰り返し描かれる**。雛形を組み立てている最中は、その頂点自身がここを通るので
    /// 何もしない。
    func closeFlatTemplate() {
        guard openFlat != nil, !buildingFlatTemplate else { return }
        closeBatch()
    }

    /// 開いている立体の列を閉じる。
    ///
    /// 頂点の区間と置き場所の区間を**両方**持って閉じる。頂点は形ごとに 1 組しか
    /// 無いので、「最後の列の終わりが次の始まり」という数え方はできない。
    ///
    /// 読む順の区間は置き場所と同じ数え方 (末尾までの差) で取る — この列の添字は
    /// 開いてから閉じるまでの間に、並びの末尾へ順に積まれるためである。
    private func closeSolidBatch() {
        guard let open = openSolid else { return }
        openSolid = nil
        let instanceCount = open.external?.count ?? (solidInstances.count - open.instanceStart)
        guard open.vertexCount > 0, instanceCount > 0 else { return }
        let indexStart = open.indexStart ?? 0
        let indexCount = open.indexStart.map { solidIndices.count - $0 } ?? 0
        // **外の置き場から置き場所を取る列は添字を持てない。** 粒が GPU に書かせる
        // 引数は `MTLDrawPrimitivesIndirectArguments` で、添字版とは構造体が違う —
        // 混ぜると引数を読み違えて、絵だけが黙って崩れる
        precondition(
            open.external == nil || indexCount == 0,
            "a run that takes its positions from an outside buffer cannot carry indices")
        batches.append(
            Batch(
                run: Shape.Run(
                    mode: style.blendMode, texture: currentTexture,
                    paint: effectivePaint,
                    source: .solid,
                    start: open.vertexStart, count: open.vertexCount,
                    indexStart: indexStart, indexCount: indexCount),
                clip: style.clip,
                matrix: viewProjection,
                lightRange: bakeActiveLights(),
                material: style.material.receiving(shadow: style.receivesShadow),
                viewer: viewer,
                view: viewMatrix,
                surroundings: bakeSurroundings(),
                castsShadow: style.castsShadow,
                instanceStart: open.external == nil ? open.instanceStart : 0,
                instanceCount: instanceCount,
                instances: open.external?.instances,
                indirectArguments: open.external?.arguments,
                cullMode: cullMode(for: open),
                backFaceParts: backFaceParts(closing: open),
                backFaceInstances: open.external == nil ? open.backFaceInstances : [],
                frontFacing: frontFacing(for: open),
                isMirrored: open.isMirrored,
                solidSource: open.source,
                strokeGeometry: open.strokeGeometry, strokePlacement: open.strokePlacement,
                fillGeometry: open.fillGeometry))
        batches[batches.count - 1].thinCoverage = openBatchHasThinCoverage
        warnIfMaterialCannotShow()
    }

    /// 閉じようとしている立体の列が、裏を向いた面を捨ててよいか (``Batch/cullMode``)。
    ///
    /// **捨ててよいのは、裏面が絵に出ようのない列だけ**である。閉じた組み込みの形で、
    /// 裏面が絵に出うるスタイル (``placementMayShowBackFaces``) で置いた形が 1 つも無い
    /// 列だけが捨てる。**迷う側は両面**で、捨てないことは遅くなるだけで絵を間違えない。
    ///
    /// **スタイルは、閉じる時点ではなく形を置いたときのものを読む**
    /// (``OpenSolid/mayShowBackFaces``)。後から変えた設定は、既に置いた形に効かない
    /// ([#1564](https://github.com/mokume-metal/mokume/issues/1564))。
    ///
    /// **鏡映と裏返す投影は、ここでは見ない。** どちらも巻き方を裏返すだけで、裏面が絵に
    /// 出るようにはしない — 裏返った巻き方は表の巻き方 (``frontFacing(for:)``) の側で
    /// 戻し、捨て方は `.back` のまま保つ ([#1446](https://github.com/mokume-metal/mokume/issues/1446))。
    private func cullMode(for open: OpenSolid) -> MTLCullMode {
        guard open.strokeGeometry == nil,
            case .mesh(let shape) = open.source, shape.isClosed, !open.mayShowBackFaces
        else { return .none }
        return .back
    }

    /// 閉じようとしている立体の列の、裏 → 表の順で描きうる部品 (``Batch/backFaceParts``)。
    ///
    /// 置き場所で置く組み込みの形・モデルの列は、形全体を 1 つの部品にする。部品そのものには印を
    /// 付けず、印は置き場所の側 (``OpenSolid/backFaceInstances``) が持つ。印の付いた置き場所が無い
    /// 列と、向きの求まらないモデルの列は部品にしない。それ以外の列は、置いたときに記録した部品
    /// (``OpenSolid/parts``) をそのまま渡す。外の置き場から取る列 (粒) と GPU の線の列は、個数を
    /// GPU が書く・帯は部品でないので、部品を持たない。
    private func backFaceParts(closing open: OpenSolid) -> [SolidPart] {
        guard open.external == nil, open.strokeGeometry == nil else { return [] }
        switch open.source {
        case .mesh, .model:
            guard let winding = open.meshWinding, winding != .unknown else { return [] }
            return [
                SolidPart(
                    range: open.vertexStart..<(open.vertexStart + open.vertexCount), isIndexed: false,
                    showsBackFaces: false, insideOut: winding == .inward)
            ]
        case .retained, .freeform:
            return open.parts
        }
    }

    /// 置き場所 1 つが、裏面を絵に出しうるか。**裏 → 表で描く印を付ける口は、どれもこれを通る**
    /// (``Batch/backFaceParts``)。
    ///
    /// `styled` は置いたスタイルが裏面を絵に出しうるか (``placementMayShowBackFaces``)。保持した形を
    /// 置くときは偽を渡す — 記録したときのスタイルは部品の印 (``SolidPart/showsBackFaces``) に残って
    /// いて、置く側のスタイルは形に効かない。置き場所の色 (``SolidInstance/color``) が透けていれば、
    /// スタイルによらず裏面が絵に出うる。
    func placementShowsBackFaces(_ placement: SolidInstance, styled: Bool) -> Bool {
        styled || placement.color.w < 1
    }

    /// いまのスタイルで置く形は、裏面が絵に出うるか (``cullMode(for:)``)。
    ///
    /// 出うるのは、次のどれか 1 つでも当たる形である: 半透明の塗り (奥の面が手前の面を
    /// 通して見える)・貼る絵 (透けた画素から奥が見える)・重ねる以外の混ぜ方 (奥の面も
    /// 足し合わせに寄与する)・利用者の断片 (透明を返したり画素を捨てたりできる)。
    ///
    /// **形を置くときに読み、列へ記録する** (``OpenSolid/mayShowBackFaces``)。4 つとも同じ
    /// 扱いにしてある — 混ぜ方と断片は変えれば列を閉じるので、いまは閉じる時点に読んでも
    /// 同じ答えになるが、読み方を 1 つにしておけば、閉じない設定が混ざっても食い違わない。
    ///
    /// 記録した置き場所は、両面で描くだけでなく、4 つの条件のどれでも**置き場所ごと・部品ごとに
    /// 裏 → 表の順で描く** (``Batch/backFaceParts``)。立体は奥行きを書くので、1 回で描くと手前の
    /// 面が奥の面を捨て、奥の面が出るかが形の向きで変わる
    /// ([#1549](https://github.com/mokume-metal/mokume/issues/1549))。保持した形の中で置いた形
    /// には、記録したときのこの値が部品 (``SolidPart/showsBackFaces``) として残り、置くときの
    /// スタイルではなく記録したときのスタイルで判じる。
    var placementMayShowBackFaces: Bool {
        style.fill.alpha < 1 || style.picture != nil || style.blendMode != .blend
            || currentShader != nil
    }

    /// 閉じようとしている立体の列の、表の巻き方 (``Batch/frontFacing``)。
    ///
    /// **置き場所の鏡映と、画面の縦横を裏返す投影の組で決まる。** どちらも画面での巻き方を
    /// 1 度ずつ裏返すので、片方だけなら反時計回りが表になり、両方なら元へ戻る。投影は
    /// **閉じた時点の視点**から読む (視点を当てると列が閉じるので、列の中で投影は変わらない)。
    private func frontFacing(for open: OpenSolid) -> MTLWinding {
        open.isMirrored != currentCamera.flipsScreen ? .counterClockwise : .clockwise
    }

    /// 効きようのない材質を、初回だけ知らせる ([ADR-0020] 決定 5)。
    ///
    /// **黙って無視しないための口である。** どちらも式としては正しく振る舞っていて、
    /// 絵だけが「書いたのに効かない」「真っ黒」になる — 利用者からは自分のコードを
    /// 疑うしかない形の失敗なので、起きた場所で知らせる。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    private func warnIfMaterialCannotShow() {
        switch Material.unusableReason(
            style.material, lights: activeLights, surroundings: activeSurroundings)
        {
        case nil:
            return
        case .noLight:
            warnOnce(
                .materialWithoutLight,
                "A material is being written, but not a single light or surrounding has been placed. "
                    + "A solid with neither comes out as one flat colour, so no material takes effect")
        case .metalWithoutSurroundings:
            warnOnce(
                .metalWithoutSurroundings,
                "Metalness is raised, but there is nothing to reflect. Metal is only visible by "
                    + "reflecting what is around it, so without surroundings() or "
                    + "ambientLight() only the sheen is left and it goes dark")
        }
    }

    /// いま効いている周囲を、この列の形へ詰める。
    ///
    /// 周囲そのものを出す列 (`background(.sky)`) はここを通らない — 呼んだ時点のスタイルを
    /// 読まずに、置き換える列が自分で詰める (``Canvas/replaceSurface(with:)``・#1685)。
    private func bakeSurroundings() -> PackedSurroundings {
        guard openSource == .solid, let activeSurroundings else { return .none }
        return activeSurroundings.packed()
    }

    /// 平面を溜める側へ戻る。**立体の列が開いていれば閉じる。**
    ///
    /// 立体の列を開いたまま平面を溜めると、呼び出し順どおりの重なりが崩れる
    /// ([ADR-0021] 決定 2)。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    func beginFlat() {
        notePaintPlacement()
        // **平面の頂点はどれもここを通る。** 畳めない頂点が開いている雛形へ紛れ込むのを
        // 止める場所を、1 つに保つ
        closeFlatTemplate()
        guard openSource != .flat else { return }
        closeBatch()
        openSource = .flat
    }

    /// これから積む図形の塗りが断片の面として描き場所を読むなら、**置いたことをいま記録する**
    /// ([#1653])。
    ///
    /// 貼る絵 (``useTexture(_:)``) と同じく、記録は置いた時点で取る。列を閉じる時点で取ると、
    /// 置いた後に描き場所が描き換わったとき先に置いた図形まで後の絵になり、描き切る前の
    /// 描き場所を読んだ注意も「いつ置いたか」ではなく「いつ閉じたか」で決まってしまう。
    ///
    /// 呼ぶのは図形を積む口 — 平面は ``beginFlat()`` (頂点はどれもここを通る) と、畳む口の
    /// 入口 (``draw(folding:at:outline:)``。溜め場を組み替える前に呼ぶ・#2042)、立体は ``beginSolids()`` (置く口はどれもここを通る)。基本図形の列は
    /// 利用者の断片で塗らない (``formAllowed(fills:)``) ので呼ばない。**保持した形を置いている
    /// 間は、記録した塗りの面を読む** (``effectivePaint`` と同じ優先)。
    ///
    /// 形の組み立て中は記録しない (``note(placing:)`` が飛ばす)。組み立てた図形は形へ抜かれ、
    /// 形を置くときにここを通り直す。
    ///
    /// [#1653]: https://github.com/mokume-metal/mokume/issues/1653
    func notePaintPlacement() {
        if let replayedPaint {
            for held in replayedPaint.surfaces {
                if let graphics = (held.owner as? RenderTarget)?.drawer { note(placing: graphics) }
            }
            return
        }
        // **記録済みなら何もしない** (``paintSurfacesNoted``)。記録が落ちた・断片か面が替わった・
        // 読む描き場所が描き始めたときは控えが外れているので、下で取り直す。断片を読むより先に
        // 見る — 線や字は三角形ごとにここを通る
        if paintSurfacesNoted == placedGraphicsDrops { return }
        guard let currentShader, !currentShader.drawnSurfaces.isEmpty else { return }
        for graphics in currentShader.drawnSurfaces { note(placing: graphics) }
        // 記録を取れた区間でだけ控える (``note(placing:)`` は区間の外と組み立ての中を飛ばす)。
        // **読む描き場所が追い付けなかった回も控えてよい** ([#2042])。追い付きはその描き場所が次に描き
        // 切るまで見送られ (``placingCatchUpDeferred``)、その描き切りが置いた側へ写させて記録を落とす
        // ので、控えも外れて次に置くとき記録 (と追い付き) をやり直す
        //
        // [#2042]: https://github.com/mokume-metal/mokume/issues/2042
        if writesToSurface, !recordingShape { paintSurfacesNoted = placedGraphicsDrops }
    }

    /// いま効いている光を置き場へ写し、その区間を返す。
    private func bakeActiveLights() -> Range<Int> {
        guard !activeLights.isEmpty else { return 0..<0 }
        let start = lightStorage.count
        lightStorage.append(contentsOf: activeLights)
        return start..<lightStorage.count
    }

    /// 線の端の形。
    public func strokeCap(_ cap: StrokeCap) { style.strokeCap = cap }

    /// 線の折れ目の形。
    public func strokeJoin(_ join: StrokeJoin) { style.strokeJoin = join }

    /// 矩形に渡す座標の読み方。
    public func rectMode(_ mode: ShapeMode) { style.rectMode = mode }

    /// 楕円と円弧に渡す座標の読み方。
    public func ellipseMode(_ mode: ShapeMode) { style.ellipseMode = mode }

}
