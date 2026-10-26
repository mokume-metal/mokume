// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// ベクターへ書く図形を、置く口の内側で控える仕組み ([#3139])。
//
// 割る前の図形の列は、組み立てに 1 本としては残っていない ([ADR-0021] 決定 3 の追補 (2026-10-23))。
// 控える位置は 5 つ — 基本図形を置く口 (`appendForm`)・破線の口 (`appendDashedForm` /
// `appendDashedLineForms`)・周を道具で扱う口 (`draw(_ outline:)`)・頂点の形を終える口
// (`drawBuiltShape`)。書けない図形は、公開の口 (字・絵・保持した形・立体・画素・粒) と、置く口が見る
// 設定 (断片・貼る絵・勾配・通常以外の混ぜ方・切り抜き) で数えて落とす。
//
// **控えるのは観測であって、組み立てを変えない。** 控えた後も図形はいままでどおり 1 本の組み立てを
// 通って描かれる。頼まれていないフレームが払うのは、各口の先頭の読み (`vector.capture` が nil か・
// 「置いた」印が立っているか) だけで、書き込みは窓ごとの 1 度 (印を立てる) に限る。
//
// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
// [#3139]: https://github.com/mokume-metal/mokume/issues/3139

import simd

/// 1 回の `draw()` の間に控えている図形と、書けなかったものの記録。
///
/// 書き出す側 (``SketchRuntime``) が `draw()` の終わりで受け取り、行き先ごとに ``requests`` の始まり
/// から後ろを渡す。
final class VectorCapture {
    /// 頼み 1 つ。**呼んだ時点から控える** — 先に置いた図形は含まない。
    struct Request {
        var path: String
        /// この頼みが控え始めた図形の位置 (``figures`` の添字)。
        var figureStart: Int
        /// この頼みが控え始めた「書けなかったもの」の位置 (``drops`` の添字)。
        var dropStart: Int
        /// `draw()` の中で、呼ぶ前に図形を置いていたか (呼ぶ前のものは書かれない)。
        var placedBefore: Bool
    }

    var figures: [VectorFigure] = []
    var drops: [VectorDrop] = []
    var requests: [Request] = []

    /// 図形を 1 つ足す。**画面に見えない塗りと輪郭は書かない** — 透明な線 (`stroke(255, 0)`) を
    /// `stroke-opacity="0"` で書くと、不透明度を無視する取り込み側が線を引く。両方とも見えなければ、
    /// 図形ごと足さない (``VectorColor/isInvisible``)。
    func add(_ figure: VectorFigure) {
        var figure = figure
        if let fill = figure.fill, fill.color.isInvisible { figure.fill = nil }
        if let stroke = figure.stroke, stroke.color.isInvisible { figure.stroke = nil }
        guard figure.fill != nil || figure.stroke != nil else { return }
        figures.append(figure)
    }
}

extension Canvas {
    /// `draw()` の間の控えの状態。**ランタイムが `draw()` の前に立て、後で下ろす。**
    struct VectorWindow {
        /// `draw()` の間か。**ランタイムが `save("x.svg")` の意味を決めるのに読む** — 開いていれば呼んだ時点から、
        /// 閉じていれば次の `draw()` を丸ごと。
        var isOpen = false
        /// 控えている途中なら、その器。
        var capture: VectorCapture?
        /// この窓の中で、控える前に図形を置いたか。`save("x.svg")` が呼ぶ前に置いたものがあれば、
        /// 1 度知らせる。
        var placedBefore = false
    }

    // MARK: - 窓

    /// `draw()` の窓を開く。`pending` は `draw()` の外で頼まれた行き先で、この `draw()` を丸ごと控える。
    func beginVectorWindow(pending: [String]) {
        vector = VectorWindow(isOpen: true)
        guard !pending.isEmpty else { return }
        let capture = VectorCapture()
        for path in pending {
            capture.requests.append(
                VectorCapture.Request(path: path, figureStart: 0, dropStart: 0, placedBefore: false))
        }
        vector.capture = capture
    }

    /// `draw()` の中で頼まれた。呼んだ時点から控え始める。
    func startVectorCapture(path: String) {
        let capture = vector.capture ?? VectorCapture()
        // 呼ぶ前に置いた図形が無いか。別の頼みが先に控え始めていれば、控えた図形も数える (その図形は、
        // いま頼んだ行き先には入らない)
        let placedBefore = vector.placedBefore || !(capture.figures.isEmpty && capture.drops.isEmpty)
        capture.requests.append(
            VectorCapture.Request(
                path: path, figureStart: capture.figures.count, dropStart: capture.drops.count,
                placedBefore: placedBefore))
        vector.capture = capture
    }

    /// 画面が溜めた図形を捨てる口 (`background()` の塗り直し) で、控えた図形も捨てる。
    ///
    /// 塗り直しは、それより前に置いた図形をすべて画面から消す (``replaceSurface(with:)``)。ペンプロッタは画面に
    /// 無い線を引くので、控えもそこで切る。**頼みの始まりはすべて、いまの末尾へ寄せる** — 捨てた図形は
    /// どの頼みにも入らず、捨てた図形の「書けなかった」名乗りも言わない (画面から消えたものは、書けなかった
    /// ことにならない)。呼ぶ前に置いた図形の知らせ (``VectorWindow/placedBefore``) も同じ理由で下ろす。
    ///
    /// 地の塗りそのものは、今までどおり書かず、知らせない (メンテナの決定・2026-10-23)。
    func discardVectorFigures() {
        vector.placedBefore = false
        guard let capture = vector.capture else { return }
        capture.figures.removeAll(keepingCapacity: true)
        capture.drops.removeAll(keepingCapacity: true)
        for index in capture.requests.indices {
            capture.requests[index].figureStart = 0
            capture.requests[index].dropStart = 0
        }
    }

    /// 窓を閉じて、控えを渡す。頼まれていなければ nil。
    func endVectorWindow() -> VectorCapture? {
        defer { vector = VectorWindow() }
        // 効果 (`effects()`) は出力段の手前に立つ段で、ベクターには効かない。このフレームに掛けていれば、
        // 書けなかったものとして数える (``filter(_:)`` は呼んだ時点で数えている)
        if let capture = vector.capture, !pendingEffects.isEmpty { capture.drops.append(.effects) }
        return vector.capture
    }

    // MARK: - 置く口が最初に呼ぶ

    /// 控えている途中なら控えの器を返す。**形の組み立て (`createShape`) の間は控えない** — 組み立てた
    /// 形は `shape()` で置くときに、保持した形として数える。
    ///
    /// 控えていなければ、図形を置いたことだけ覚える (``VectorWindow/placedBefore``)。
    @inline(__always)
    func vectorSink() -> VectorCapture? {
        guard !recordingShape else { return nil }
        if let capture = vector.capture { return capture }
        // 印は 1 度立てれば足りる。図形ごとに同じ値を書かない
        if !vector.placedBefore { vector.placedBefore = true }
        return nil
    }

    /// 書けない口が呼ぶ。控えている途中なら、種類を数える。
    func noteVectorDrop(_ kind: VectorDrop) {
        guard !recordingShape else { return }
        if let capture = vector.capture {
            capture.drops.append(kind)
        } else if !vector.placedBefore {
            vector.placedBefore = true
        }
    }

    /// 控えを止めて、器を返す。返した器は ``resumeVector(_:)`` で戻す。
    ///
    /// 破線の片を置く間と、貼る絵・断片の図形が内側で別の口を通る間は、同じ図形を 2 度控えない。
    func suspendVector() -> VectorCapture? {
        let held = vector.capture
        vector.capture = nil
        return held
    }

    /// 破線の線を、片に分ける前に控え、片を置く間は控えを止める。止めたなら元の器を返す。
    func suspendVectorRecordingDashedLine(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> VectorCapture? {
        guard let sink = vectorSink() else { return nil }
        recordVectorDashedLine(sink, a, b)
        return suspendVector()
    }

    /// 貼る絵か断片が効いている基本図形 (``draw(folding:at:)``) を控え、内側の口で 2 度控えないよう止める。
    ///
    /// ここへ来るのは、断片 (勾配を含む) が効いているか、貼る絵が塗りに効いている図形だけ
    /// (``formAllowed(fills:)``)。**書けない設定が効くのは塗りだけとは限らない** — 貼る絵と勾配は塗りにしか
    /// 効かないので、輪郭は書き、塗りだけを名指しで落とす。利用者の断片と混ぜ方と切り抜きは輪郭にも効くので、
    /// 図形ごと落とす (``vectorWritable(fills:strokes:into:)``)。輪郭は、周を刻んだ折れ線でなく
    /// 真の形 (矩形・楕円・弧) で書く。
    func suspendVectorRecordingShadedFigure(_ form: FlatForm, at anchor: SIMD2<Float>) -> VectorCapture? {
        guard let sink = vectorSink() else { return nil }
        let fills = style.hasFill
        let strokes = style.hasStroke && style.strokeWeight > 0
        if let writable = vectorWritable(fills: fills, strokes: strokes, into: sink) {
            switch form {
            case .rect(let width, let height):
                let half = SIMD2(width / 2, height / 2)
                let corners = [
                    anchor, anchor + SIMD2(width, 0), anchor + SIMD2(width, height), anchor + SIMD2(0, height),
                ]
                writeVectorForm(
                    sink, kind: .rect, center: anchor + half, half: half, axis: SIMD2(1, 0), arc: .zero,
                    arcClosure: .pie, cornerRadius: 0, fills: writable.fills, strokes: writable.strokes,
                    cap: style.strokeCap, dash: writable.strokes ? vectorDash(of: corners, isClosed: true) : [])
            case .roundedRect(let width, let height, let radius):
                // 畳むのは塗りだけの角丸 (#3170) なので、いまは輪郭を持つ角丸は来ない (塗りは落とすので何も書かない)。
                // 来たときも、他の形と同じく輪郭は真の形 (角丸の矩形・貼る絵の無い角丸が書くものと同じ) で書く。
                // 破線は、画面が刻む角丸の周 (``placeRect`` が破線の輪郭に使うものと同じ刻み) から作る
                let half = SIMD2(width / 2, height / 2)
                let outline =
                    writable.strokes
                    ? Self.roundedRectOutline(
                        width: width, height: height, radius: radius,
                        segments: Self.segmentCount(
                            forRadius: radius, scale: Self.splitScale(of: transform.matrix))
                    ).moved(by: anchor) : nil
                writeVectorForm(
                    sink, kind: .rect, center: anchor + half, half: half, axis: SIMD2(1, 0), arc: .zero,
                    arcClosure: .pie, cornerRadius: radius, fills: writable.fills,
                    strokes: writable.strokes, cap: style.strokeCap,
                    dash: outline.map { vectorDash(of: $0.points, isClosed: $0.isClosed) } ?? [])
            case .ellipse(let radiusX, let radiusY):
                writeVectorForm(
                    sink, kind: .ellipse, center: anchor, half: SIMD2(radiusX, radiusY), axis: SIMD2(1, 0),
                    arc: .zero, arcClosure: .pie, cornerRadius: 0, fills: writable.fills,
                    strokes: writable.strokes, cap: style.strokeCap,
                    dash: writable.strokes
                        ? vectorDash(
                            of: ringOutlineForDash(
                                radiusX: radiusX, radiusY: radiusY, start: 0, sweep: 2 * .pi, piece: .sector,
                                at: anchor
                            ).points, isClosed: true) : [])
            case .arc(let radiusX, let radiusY, let start, let sweep):
                // 一周ぶんは楕円。ここへ来る弧は、一周か扇 (`.pie`) か、輪郭の無い弧だけ
                let isFullTurn = sweep >= 2 * .pi
                let ring = writable.strokes
                    ? ringOutlineForDash(
                        radiusX: radiusX, radiusY: radiusY, start: isFullTurn ? 0 : start,
                        sweep: isFullTurn ? 2 * .pi : sweep, piece: .sector, at: anchor)
                    : nil
                writeVectorForm(
                    sink, kind: isFullTurn ? .ellipse : .arc, center: anchor, half: SIMD2(radiusX, radiusY),
                    axis: SIMD2(1, 0), arc: isFullTurn ? .zero : SIMD2(start, sweep), arcClosure: .pie,
                    cornerRadius: 0, fills: writable.fills, strokes: writable.strokes, cap: style.strokeCap,
                    dash: ring.map { vectorDash(of: $0.points, isClosed: $0.isClosed) } ?? [])
            }
        }
        return suspendVector()
    }

    func resumeVector(_ held: VectorCapture?) {
        if let held { vector.capture = held }
    }

    // MARK: - 色・輪郭・変換

    /// 変換の拡大率。**平面の行列の行列式の平方根。** 線の太さと破線の長さに掛ける。
    ///
    /// 画面の道は、太さを形自身の座標で持って変換で拡大する。均等な拡大・回転・平行移動では
    /// この値が拡大率そのものになる。軸ごとに違う倍率や歪みでは、画面の輪郭は楕円のペンになるが、
    /// SVG の線は 1 つの太さしか持てないので、面積の比の平方根で近似する。
    var vectorLinearScale: Float {
        let columns = transform.matrix.columns
        let determinant = columns.0.x * columns.1.y - columns.0.y * columns.1.x
        return determinant.magnitude.squareRoot()
    }

    /// 形自身の座標の点を、いまの変換で画面の座標へ。
    func vectorPlacer() -> (SIMD2<Float>) -> SIMD2<Float> {
        let matrix = transform.matrix
        return { point in
            let moved = matrix * SIMD4<Float>(point.x, point.y, 0, 1)
            return SIMD2(moved.x, moved.y)
        }
    }

    /// 書けない設定が効いているか。効いていれば、数えて落とす理由を返す。
    ///
    /// - Parameter fills: この図形が塗りを描くか。貼る絵と勾配は塗りにしか効かない。
    func vectorBlocker(fills: Bool) -> VectorDrop? {
        // 勾配は面が持つ断片 (``paintsWithGradient``) で塗るので、断片が置かれていても利用者の断片とは
        // 見分ける。勾配が効くのは塗りだけで、輪郭と線は色のまま書ける
        if paintsWithGradient {
            if fills { return .gradient }
        } else if currentShader != nil {
            return .shader
        }
        if fills, style.picture != nil { return .texture }
        if style.blendMode != .blend { return .blendMode }
        if style.clip != nil { return .clip }
        return nil
    }

    /// 塗りと輪郭のうち、書けるほうを返す。**書けないものがあれば、図形 1 つにつき 1 度だけ名指しで数える。**
    ///
    /// - 輪郭が書けない設定 (利用者の断片・通常以外の混ぜ方・切り抜き) は、塗りにも同じに効くので、図形ごと
    ///   落とす。
    /// - 貼る絵と勾配は塗りにしか効かない。輪郭を持つ図形は、塗りだけを落として輪郭を書く
    ///   (黙って輪郭まで失わない)。
    /// - 図形の塗りと輪郭を何度かの口に分けて控える図形 (破線で塗りもある図形・弧) は、
    ///   ``countingOneVectorFigure(_:)`` で括り、同じ図形を 2 度数えない。
    ///
    /// 書くものが無ければ nil。
    func vectorWritable(
        fills: Bool, strokes: Bool, into sink: VectorCapture
    ) -> (fills: Bool, strokes: Bool)? {
        guard fills || strokes else { return nil }
        if strokes, vectorBlocker(fills: false) != nil {
            if let blocked = vectorBlocker(fills: fills) { sink.drops.append(blocked) }
            return nil
        }
        if fills, let blocked = vectorBlocker(fills: true) {
            sink.drops.append(blocked)
            return strokes ? (fills: false, strokes: true) : nil
        }
        return (fills, strokes)
    }

    /// 1 つの図形を何度かの口に分けて控える処理を括り、**書けないものを図形ごとに 1 度だけ数える。**
    ///
    /// 破線で塗りもある図形は塗りと輪郭を別々に、既定の弧は扇の塗りと開いた弧の輪郭を別々に控える。
    /// それぞれが同じ理由 (利用者の断片など) で落とすと、見た目は 1 つの図形なのに 2 と数えてしまう。
    func countingOneVectorFigure(_ body: () -> Void) {
        guard let sink = vectorSink() else { return body() }
        let before = sink.drops.count
        body()
        if sink.drops.count - before > 1 { sink.drops.removeSubrange((before + 1)...) }
    }

    /// 輪郭の破線を、画面と同じく刻めるか。刻めるなら、拡大率を掛けた破線の長さと間隔。
    ///
    /// 画面は、刻む数が上限 (``maxDashPieces``) を越えるときと刻めない折れ線 (点が 2 つに満たない・
    /// 数でない座標) のときに、実線で引く。**同じ判定で、書く側も実線にする**。
    func vectorDash(of points: [SIMD2<Float>], isClosed: Bool) -> [Float] {
        guard let dash = style.strokeDash else { return [] }
        return vectorDash(dash, over: points, isClosed: isClosed)
    }

    func vectorDash(_ dash: StrokeDash, over points: [SIMD2<Float>], isClosed: Bool) -> [Float] {
        guard points.count >= 2, dash.length >= 0, dash.gap > 0 else { return [] }
        var total: Float = 0
        for index in 1..<points.count {
            total += simd_length(points[index] - points[index - 1])
        }
        if isClosed { total += simd_length(points[0] - points[points.count - 1]) }
        let period = dash.length + dash.gap
        guard total.isFinite, period.isFinite, period > 0, total / period <= Float(Self.maxDashPieces)
        else { return [] }
        let scale = vectorLinearScale
        return [dash.length * scale, dash.gap * scale]
    }

    /// いまの設定の輪郭。
    func vectorStroke(color: LinearRGBA? = nil, cap: StrokeCap? = nil, dash: [Float] = []) -> VectorStroke {
        VectorStroke(
            color: VectorColor(color ?? style.stroke), width: style.strokeWeight * vectorLinearScale,
            cap: cap ?? style.strokeCap, join: style.strokeJoin, dash: dash)
    }

    /// 点 1 つの輪郭の端。**孤立した端は、長さちょうどで切る形 (`square`) も正方形で出す。**
    ///
    /// 画面は、隣の点を持たない端を `round` なら円板・それ以外なら正方形で置く (``appendPointForm(_:)`` と
    /// 周の端 `strokeCapShape`)。`square` は「線の長さちょうど」で、線が無ければ長さが決まらないからである。
    /// SVG の `butt` は長さ 0 の線を何も描かないので、`project` (SVG の `square`) に読み替えて書く。
    var vectorPointCap: StrokeCap { style.strokeCap == .round ? .round : .project }

    /// いまの設定の塗り。
    func vectorFill(color: LinearRGBA? = nil, evenOdd: Bool = false) -> VectorFill {
        VectorFill(color: VectorColor(color ?? style.fill), evenOdd: evenOdd)
    }

    // MARK: - 基本図形 (appendForm)

    /// 基本図形 1 つを控える。**形自身の座標の寸法から、画面の座標の道を作る。**
    ///
    /// 楕円と弧は 3 次ベジェ (四分円ごと) で書く。変換は制御点にそのまま当てる (3 次ベジェは
    /// アフィン変換で閉じている)。
    func recordVectorForm(
        _ sink: VectorCapture, kind: FormInstance.Kind, center: SIMD2<Float>, half: SIMD2<Float>,
        axis: SIMD2<Float>, arc: SIMD2<Float>, arcClosure: FormInstance.ArcClosure,
        cornerRadius: Float, fills: Bool, strokes: Bool, cap: StrokeCap
    ) {
        guard let writable = vectorWritable(fills: fills, strokes: strokes, into: sink) else { return }
        writeVectorForm(
            sink, kind: kind, center: center, half: half, axis: axis, arc: arc, arcClosure: arcClosure,
            cornerRadius: cornerRadius, fills: writable.fills, strokes: writable.strokes, cap: cap)
    }

    /// 書けると分かった基本図形を、図形にして控える (``recordVectorForm``)。
    func writeVectorForm(
        _ sink: VectorCapture, kind: FormInstance.Kind, center: SIMD2<Float>, half: SIMD2<Float>,
        axis: SIMD2<Float>, arc: SIMD2<Float>, arcClosure: FormInstance.ArcClosure,
        cornerRadius: Float, fills: Bool, strokes: Bool, cap: StrokeCap, dash: [Float] = []
    ) {
        let place = vectorPlacer()
        let fill = fills ? vectorFill() : nil
        let stroke = strokes ? vectorStroke(cap: cap, dash: dash) : nil

        func single(_ subpath: VectorSubpath) {
            sink.add(VectorFigure(subpaths: [subpath], fill: fill, stroke: stroke))
        }

        switch kind {
        case .rect:
            if cornerRadius > 0 {
                single(Self.roundedRectSubpath(center: center, half: half, radius: cornerRadius, place: place))
            } else {
                let corners = [
                    SIMD2(center.x - half.x, center.y - half.y), SIMD2(center.x + half.x, center.y - half.y),
                    SIMD2(center.x + half.x, center.y + half.y), SIMD2(center.x - half.x, center.y + half.y),
                ].map(place)
                single(VectorSubpath(points: corners, isClosed: true))
            }
        case .ellipse:
            let cubics = Self.ellipseCubics(center: center, radius: half, start: 0, sweep: 2 * .pi)
            single(
                VectorSubpath(
                    points: cubics.map(place), curves: Array(repeating: true, count: (cubics.count - 1) / 3),
                    isClosed: true))
        case .arc:
            recordVectorArc(
                sink, center: center, radius: half, start: arc.x, sweep: arc.y, closure: arcClosure,
                fill: fill, stroke: stroke, place: place)
        case .line:
            let tip = axis * half.x
            let ends = [center - tip, center + tip].map(place)
            // 長さ 0 の線 (点) は、点 1 つの道にする
            let points = ends[0] == ends[1] ? [ends[0]] : ends
            single(VectorSubpath(points: points, isClosed: false))
        }
    }

    /// 弧を控える。**閉じ方で、塗りの形と輪郭の形が違う。**
    ///
    /// | 閉じ方 | 塗り | 輪郭 |
    /// | --- | --- | --- |
    /// | `pie` | 扇 | 扇の周 |
    /// | `standard` | 扇 | 開いた弧 |
    /// | `chord` | 弦で結んだ形 | 弦で結んだ形の周 |
    /// | `open` | 弦で結んだ形 | 開いた弧 |
    ///
    /// 塗りと輪郭が同じ形なら 1 つの図形に、違えば塗り → 輪郭の順に 2 つの図形にする。
    private func recordVectorArc(
        _ sink: VectorCapture, center: SIMD2<Float>, radius: SIMD2<Float>, start: Float, sweep: Float,
        closure: FormInstance.ArcClosure, fill: VectorFill?, stroke: VectorStroke?,
        place: (SIMD2<Float>) -> SIMD2<Float>
    ) {
        let cubics = Self.ellipseCubics(center: center, radius: radius, start: start, sweep: sweep)
        let curveCount = (cubics.count - 1) / 3
        let placedCubics = cubics.map(place)
        let placedCenter = place(center)
        // 扇: 中心 → 弧の始点 (線) → 弧 (曲線) → 閉じる
        let sector = VectorSubpath(
            points: [placedCenter] + placedCubics,
            curves: [false] + Array(repeating: true, count: curveCount), isClosed: true)
        // 弦で結んだ形: 弧 → 閉じる (終点から始点へ戻る線)
        let chord = VectorSubpath(
            points: placedCubics, curves: Array(repeating: true, count: curveCount), isClosed: true)
        let openArc = VectorSubpath(
            points: placedCubics, curves: Array(repeating: true, count: curveCount), isClosed: false)

        let fillShape = closure.fillsChord ? chord : sector
        let strokeShape: VectorSubpath
        switch closure {
        case .pie: strokeShape = sector
        case .chord: strokeShape = chord
        case .standard, .open: strokeShape = openArc
        }
        if let fill, let stroke {
            if fillShape == strokeShape {
                sink.add(VectorFigure(subpaths: [fillShape], fill: fill, stroke: stroke))
            } else {
                sink.add(VectorFigure(subpaths: [fillShape], fill: fill, stroke: nil))
                sink.add(VectorFigure(subpaths: [strokeShape], fill: nil, stroke: stroke))
            }
        } else if let fill {
            sink.add(VectorFigure(subpaths: [fillShape], fill: fill, stroke: nil))
        } else if let stroke {
            sink.add(VectorFigure(subpaths: [strokeShape], fill: nil, stroke: stroke))
        }
    }

    /// 破線の線を控える。**片に分ける前の線と、破線の指定を控える。**
    func recordVectorDashedLine(_ sink: VectorCapture, _ a: SIMD2<Float>, _ b: SIMD2<Float>) {
        if let blocked = vectorBlocker(fills: false) {
            sink.drops.append(blocked)
            return
        }
        let place = vectorPlacer()
        let ends = [place(a), place(b)]
        guard ends.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return }
        let dash = vectorDash(of: [a, b], isClosed: false)
        sink.add(
            VectorFigure(
                subpaths: [VectorSubpath(points: ends, isClosed: false)], fill: nil,
                stroke: vectorStroke(dash: dash)))
    }

    // MARK: - 周 (Outline)

    /// 周を控える。**点は形自身の座標のまま受け、置くときの変換を当てる。**
    ///
    /// - Parameters:
    ///   - fills: 塗りを描くか (周の旗といまの設定が揃っているか)。
    ///   - strokes: 輪郭を引くか。
    func recordVectorOutline(
        _ sink: VectorCapture, _ outline: Outline, fills: Bool, strokes: Bool
    ) {
        guard !outline.points.isEmpty, fills || strokes else { return }
        guard let writable = vectorWritable(fills: fills, strokes: strokes, into: sink) else { return }
        let (fills, strokes) = writable
        let place = vectorPlacer()
        var points = [SIMD2<Float>]()
        points.reserveCapacity(outline.points.count)
        for point in outline.points {
            let placed = place(point)
            guard placed.x.isFinite, placed.y.isFinite else { return }
            points.append(placed)
        }
        let dash = strokes ? vectorDash(of: outline.points, isClosed: outline.isClosed) : []
        sink.add(
            VectorFigure(
                subpaths: [VectorSubpath(points: points, isClosed: outline.isClosed)],
                fill: fills ? vectorFill() : nil,
                stroke: strokes
                    ? vectorStroke(cap: points.count == 1 ? vectorPointCap : nil, dash: dash) : nil))
    }

    // MARK: - 曲線

    /// 楕円の弧を 3 次ベジェで。中心 `center`・半径 `radius`・媒介角が `start` から `sweep` だけ。
    /// 返すのは始点を先頭に、区間ごとに制御点 2 つと終点の並び。
    ///
    /// 区間は四分円以下に刻む。1 つの区間の角が Δ のとき、制御点は端の接線の向きに
    /// 4/3 · tan(Δ/4) だけ延ばす (四分円で形の誤差は半径の約 0.03%)。
    static func ellipseCubics(
        center: SIMD2<Float>, radius: SIMD2<Float>, start: Float, sweep: Float
    ) -> [SIMD2<Float>] {
        // 丸めの誤差で四分円がもう 1 つ増えないよう、わずかに引いてから切り上げる
        let pieces = max(1, Int((abs(sweep) / (.pi / 2) - 1e-4).rounded(.up)))
        let step = sweep / Float(pieces)
        let handle = 4 / 3 * RuntimeMath.tan(step / 4)
        func point(_ angle: Float) -> SIMD2<Float> {
            SIMD2(center.x + radius.x * RuntimeMath.cos(angle), center.y + radius.y * RuntimeMath.sin(angle))
        }
        func tangent(_ angle: Float) -> SIMD2<Float> {
            SIMD2(-radius.x * RuntimeMath.sin(angle), radius.y * RuntimeMath.cos(angle))
        }
        var points = [point(start)]
        points.reserveCapacity(1 + 3 * pieces)
        for index in 0..<pieces {
            let from = start + step * Float(index)
            let to = start + step * Float(index + 1)
            let end = point(to)
            points.append(point(from) + handle * tangent(from))
            points.append(end - handle * tangent(to))
            points.append(end)
        }
        return points
    }

    /// 角を丸めた矩形の道 (四分円の角は 3 次ベジェ)。
    static func roundedRectSubpath(
        center: SIMD2<Float>, half: SIMD2<Float>, radius: Float, place: (SIMD2<Float>) -> SIMD2<Float>
    ) -> VectorSubpath {
        let x0 = center.x - half.x
        let y0 = center.y - half.y
        let x1 = center.x + half.x
        let y1 = center.y + half.y
        let r = radius
        // 四分円を 3 次ベジェで近似するときの制御点の延ばし方 (4/3 · tan(π/8))
        let k = 0.552_284_75 * r
        let local: [SIMD2<Float>] = [
            SIMD2(x0 + r, y0),
            SIMD2(x1 - r, y0),
            SIMD2(x1 - r + k, y0), SIMD2(x1, y0 + r - k), SIMD2(x1, y0 + r),
            SIMD2(x1, y1 - r),
            SIMD2(x1, y1 - r + k), SIMD2(x1 - r + k, y1), SIMD2(x1 - r, y1),
            SIMD2(x0 + r, y1),
            SIMD2(x0 + r - k, y1), SIMD2(x0, y1 - r + k), SIMD2(x0, y1 - r),
            SIMD2(x0, y0 + r),
            SIMD2(x0, y0 + r - k), SIMD2(x0 + r - k, y0), SIMD2(x0 + r, y0),
        ]
        return VectorSubpath(
            points: local.map(place),
            curves: [false, true, false, true, false, true, false, true], isClosed: true)
    }
}
