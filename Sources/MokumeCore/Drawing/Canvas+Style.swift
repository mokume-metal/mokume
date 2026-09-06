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
        currentFill = color
        hasFill = true
    }

    /// 図形の内側を塗らない。
    public func noFill() { hasFill = false }

    public func stroke(_ color: LinearRGBA) {
        currentStroke = color
        hasStroke = true
    }

    /// 線を引かない。図形の輪郭も出なくなる。
    public func noStroke() { hasStroke = false }

    public func strokeWeight(_ weight: some ScalarConvertible) {
        let weight = weight.asFloat
        currentStrokeWeight = max(0, weight)
    }

    // 溜めている列をその場で閉じる (混ぜ方と同じ理由)。
    //
    // 面の外へ出た指定を面の内側へ収めるのは、この世代の GPU が範囲外の切り抜きを
    // 受け取ると検証で落ちるためである。指定をそのまま渡さない。
    public func clip(_ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible) {
        let (a, b, c, d) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat)
        let box = Self.resolveBox(a, b, c, d, mode: currentRectMode)
        let left = min(max(0, Int(box.x)), Int(width))
        let top = min(max(0, Int(box.y)), Int(height))
        let right = min(max(left, Int(box.x + box.width)), Int(width))
        let bottom = min(max(top, Int(box.y + box.height)), Int(height))
        closeBatch()
        currentClip = MTLScissorRect(
            x: left, y: top, width: right - left, height: bottom - top)
    }

    public func noClip() {
        guard currentClip != nil else { return }
        closeBatch()
        currentClip = nil
    }

    /// 描くものを、下にある絵とどう混ぜるか。
    ///
    /// **溜めている列をその場で閉じる。** 既に置いた図形が後の混ぜ方で描かれないように
    /// するためで、閉じ忘れは「設定を変えたときだけ絵が崩れる」形で現れる。
    public func blendMode(_ mode: BlendMode) {
        guard mode != currentBlendMode else { return }
        closeBatch()
        currentBlendMode = mode
    }

    /// 落とす行列に、このフレームの揺らしを足す。
    ///
    /// **見る窓ではなく行列を動かす。** 窓の原点は画素の単位へ丸められる (実測) ので、
    /// 画素の内側を揺らせない。行列なら切り取りの立方体の上で足せる。
    ///
    /// 足すのは切り取りの立方体の座標なので、割る前の高さぶんを掛けて足す — 立体は
    /// 遠いほど `w` が大きく、定数を足すと奥ほど揺れなくなる。
    ///
    /// 空間方向では揺らさない (``UpscaleStage/jitter`` が 0)。
    func jittered(_ matrix: simd_float4x4) -> simd_float4x4 {
        guard let offset = upscaleStage?.jitter, offset != .zero else { return matrix }
        var shift = matrix_identity_float4x4
        shift.columns.3.x = offset.x * 2 / Float(pixelWidth)
        // 縦は落とす行列が向きを裏返しているので、面の下向きは立方体の上では逆になる
        shift.columns.3.y = -offset.y * 2 / Float(pixelHeight)
        return shift * matrix
    }

    /// 切り抜きを、実際に刻む画素へ写す。
    ///
    /// 切り抜きは利用者が出す細かさの座標で指定するので、細かく刻んでいるときは
    /// そのままでは面からはみ出す。**丸めたあとで面の内側へ収める** — この世代の
    /// GPU は範囲外の切り抜きを受け取ると検証で落ちる。
    func scissor(_ clip: MTLScissorRect?) -> MTLScissorRect {
        guard let clip else {
            return MTLScissorRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        }
        guard pixelWidth != Int(width) || pixelHeight != Int(height) else { return clip }
        let scaleX = Float(pixelWidth) / width
        let scaleY = Float(pixelHeight) / height
        let left = min(max(0, Int((Float(clip.x) * scaleX).rounded(.down))), pixelWidth)
        let top = min(max(0, Int((Float(clip.y) * scaleY).rounded(.down))), pixelHeight)
        let right = min(
            max(left, Int((Float(clip.x + clip.width) * scaleX).rounded(.up))), pixelWidth)
        let bottom = min(
            max(top, Int((Float(clip.y + clip.height) * scaleY).rounded(.up))), pixelHeight)
        return MTLScissorRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// 切り抜きが同じか。`MTLScissorRect` は素では比べられない。
    static func sameClip(_ a: MTLScissorRect?, _ b: MTLScissorRect?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (lhs?, rhs?):
            return lhs.x == rhs.x && lhs.y == rhs.y
                && lhs.width == rhs.width && lhs.height == rhs.height
        default: return false
        }
    }

    /// 溜めている頂点を、いまの混ぜ方の列として閉じる。
    ///
    /// 位置は**その並びの中で**数える。平面と立体は別の並びに溜まるので、それぞれの
    /// 最後の列の終わりが次の列の始まりになる。
    func closeBatch() {
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
        let start = batches.last(where: { $0.source == .flat })
            .map { $0.run.start + $0.run.count } ?? 0
        let count = vertices.count - start
        guard count > 0 else { return }
        batches.append(
            Batch(
                run: Shape.Run(
                    mode: currentBlendMode, texture: currentTexture,
                    paint: effectivePaint,
                    source: .flat, start: start, count: count, indexStart: 0, indexCount: 0),
                clip: currentClip,
                // ここへ来るのは平面だけ (上の `switch` が他を返している)。**平面は
                // 奥行きを持たないので視点行列を通さず、光も受けない** — 立体の側は
                // `closeSolidBatch` が視点行列と閉じた時点の光を持って閉じる
                matrix: jittered(projection),
                lightRange: 0..<0,
                material: .default,
                viewer: SIMD4(0, 0, -1, 0),
                surroundings: bakeSurroundings(),
                castsShadow: false,
                // 畳んでいない列は、何も動かさない置き場所 (添字 0) を 1 つ通る
                instanceStart: template?.instanceStart ?? 0,
                instanceCount: template.map { flatInstances.count - $0.instanceStart } ?? 1,
                strokeStart: template?.strokeStart ?? .max))
    }

    /// 断片へ渡す面を、いま列に写し取る ([#407](https://github.com/mokume-metal/mokume/issues/407))。
    ///
    /// 並びは宣言と同じ名前順。**描き場所を渡していたら、置いたことを知らせる** —
    /// 貼る口 (``texture(_:)``) と同じで、描き切る前の面を読んだときに黙っていると、
    /// 出るのは前のフレームの絵になる。
    private func snapshotSurfaces() -> [any MTLTexture] {
        guard let shader = currentShader, !shader.surfaces.isEmpty else { return [] }
        return shader.orderedSurfaces.map { surface in
            if case .graphics(let graphics) = surface { note(placing: graphics) }
            return surface.texture
        }
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
            "外の置き場から置き場所を取る列に添字は持たせられない")
        batches.append(
            Batch(
                run: Shape.Run(
                    mode: currentBlendMode, texture: currentTexture,
                    paint: effectivePaint,
                    source: .solid,
                    start: open.vertexStart, count: open.vertexCount,
                    indexStart: indexStart, indexCount: indexCount),
                clip: currentClip,
                matrix: jittered(viewProjection),
                lightRange: bakeActiveLights(),
                material: currentMaterial.receiving(shadow: receivesShadow),
                viewer: viewer,
                surroundings: bakeSurroundings(),
                castsShadow: castsShadow,
                instanceStart: open.external == nil ? open.instanceStart : 0,
                instanceCount: instanceCount,
                instances: open.external?.buffer,
                indirectArguments: open.external?.arguments,
                cullMode: cullMode(for: open),
                solidSource: open.source))
        warnIfMaterialCannotShow()
    }

    /// 閉じようとしている立体の列が、裏を向いた面を捨ててよいか (``Batch/cullMode``)。
    ///
    /// **捨ててよいのは、裏面が絵に出ようのない列だけ**である。閉じた組み込みの形で、
    /// 置き場所が全部不透明で、混ぜ方が普通の重ね方で、貼る絵も利用者の断片も無い —
    /// どれか 1 つでも欠けると、裏面が絵の一部になりうる (半透明の奥・透けた画素・
    /// 足し合わせへの寄与・断片が捨てる画素の奥) ので両面で描く。**迷う側は両面**で、
    /// 捨てないことは遅くなるだけで絵を間違えない。
    private func cullMode(for open: OpenSolid) -> MTLCullMode {
        guard case .mesh(let shape) = open.source, shape.isClosed,
            !open.hasTranslucentInstance,
            currentBlendMode == .blend,
            currentPicture == nil,
            currentShader == nil
        else { return .none }
        return .back
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
            currentMaterial, lights: activeLights, surroundings: activeSurroundings)
        {
        case nil:
            return
        case .noLight:
            warnOnce(
                .materialWithoutLight,
                "材質を書いていますが、光も周囲も 1 つも置いていません。"
                    + "どちらも無い立体は塗り 1 色で出るので、材質はどれも効きません")
        case .metalWithoutSurroundings:
            warnOnce(
                .metalWithoutSurroundings,
                "金属を上げていますが、映す先がありません。金属は周りを映すことでしか"
                    + "見えないので、surroundings() で周囲を置くか ambientLight() を"
                    + "置かないと、艶だけが残って暗くなります")
        }
    }

    /// いま効いている周囲を、この列の形へ詰める。
    ///
    /// **周囲そのものを出す列が優先する。** その列は光も材質も見ないので、置いてある
    /// 周囲ではなく背景に出す周囲を持ち歩く。
    private func bakeSurroundings() -> PackedSurroundings {
        if let backdrop { return backdrop.packed(isBackdrop: true) }
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
        // **平面の頂点はどれもここを通る。** 畳めない頂点が開いている雛形へ紛れ込むのを
        // 止める場所を、1 つに保つ
        closeFlatTemplate()
        guard openSource != .flat else { return }
        closeBatch()
        openSource = .flat
    }

    /// いま効いている光を置き場へ写し、その区間を返す。
    private func bakeActiveLights() -> Range<Int> {
        guard !activeLights.isEmpty else { return 0..<0 }
        let start = lightStorage.count
        lightStorage.append(contentsOf: activeLights)
        return start..<lightStorage.count
    }

    /// 線の端の形。
    public func strokeCap(_ cap: StrokeCap) { currentStrokeCap = cap }

    /// 線の折れ目の形。
    public func strokeJoin(_ join: StrokeJoin) { currentStrokeJoin = join }

    /// 矩形に渡す座標の読み方。
    public func rectMode(_ mode: ShapeMode) { currentRectMode = mode }

    /// 楕円と円弧に渡す座標の読み方。
    public func ellipseMode(_ mode: ShapeMode) { currentEllipseMode = mode }

}
