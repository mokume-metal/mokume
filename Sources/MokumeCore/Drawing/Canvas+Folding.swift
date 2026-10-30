// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 周を 1 本の道具としてなぞる仕組み。

import simd

extension Canvas {

    /// 図形の周。**塗りと輪郭はここから出る**ので、図形ごとに輪郭を書かずに済む。
    ///
    /// 点は変換をかける前の座標で持つ — 変換は最後に 1 度だけ掛ける。輪郭の太さは
    /// 画面の画素で測るので、変換の前に帯を作ると拡大で太さが変わってしまう。
    nonisolated struct Outline {
        /// 周を回る点。
        var points: [SIMD2<Float>]
        /// 最後の点から最初の点へ戻るか。
        var isClosed: Bool
        /// 扇で塗れる図形の中心。`nil` なら最初の点から扇状に分ける。
        ///
        /// **最初の点からの扇は、凸な周でしか正しくない。** 凸でない周は ``fillTriangles``
        /// で割り方を渡す (凸でない `quad`)。
        var fanCenter: SIMD2<Float>?
        /// 塗りを割る三角形。`nil` なら扇で割る (``fanCenter``)。
        ///
        /// 周は与えた順のまま輪郭に使い、**塗りだけを別に割る**ときに持つ。凸でない `quad` が
        /// そうで、最初の点から扇に割ると、凹んだ形はへこみまで塗り、辺の交差した形は
        /// 砂時計にならない ([#1534])。
        ///
        /// [#1534]: https://github.com/mokume-metal/mokume/issues/1534
        var fillTriangles: [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)]?
        /// 塗りを持つか。線と点は持たない。
        var fills: Bool
        /// 輪郭を引くか。偽なら、いまの設定が輪郭を引くときも塗りだけを出す。
        ///
        /// 円弧の既定 (塗りは扇・輪郭は開いた弧) は、扇の塗りと開いた弧の輪郭を別の周にして、
        /// 扇の塗りの側がこれを偽にする (``Ring/Piece``)。
        var strokes: Bool
        /// 点ごとに、折れ目の形によらず円板で埋めるか。曲線の刻みの点
        /// (``BuildingVertex/isCurveStep``) と、扇の 3 つの角 (中心と弧の両端・#1486) がそう。
        /// 空ならどの点も角。
        var curveSteps: [Bool]
        /// 点ごとに、矩形の直角の角としての外向きの対角 (各成分 ±1)。`strokeJoin(.bevel)` で
        /// 角を距離関数の経路と同じ 45° の線で削ぐのに使う (#1506)。空なら矩形の角ではない
        /// (任意多角形の折れ目で、2 本の帯の向きから決まる形で埋める・#1644。直角の `bevel`
        /// では、ここで削いだ角と同じ形になる)。
        var cornerDiagonals: [SIMD2<Float>]
        /// 線を 1 つの領域として 1 回だけ混ぜるか。基本図形 (`rect` / `ellipse` / `arc`) と、辺の交差しない
        /// `quad` が立てる。
        ///
        /// 立てると、線の片は線に沿った隔たりによらず先に置いた片を全部引いて積む
        /// (``StrokeCarving``・[#1562])。距離関数の経路と同じ塗り方で、細長い楕円の上下の弧の
        /// ように線に沿って離れた部分が重なっても濃くならない。基本図形は自己交差しない
        /// ので、交差を 2 回混ぜる任意多角形の約束 (#1536) とは食い違わない。
        ///
        /// [#1562]: https://github.com/mokume-metal/mokume/issues/1562
        var strokesAsOneRegion: Bool
        /// 置き場所ぶんずらす前の周と、ずらした量 (``moved(by:)``)。ずらしていなければ `nil`。
        ///
        /// 線の片の重なりを引くときは、ずらす前の周で引いてから足す (``StrokeCarving``)。
        /// 引き算の切り口は単精度の丸めを含むので、ずらした座標で引くと、畳んだ雛形
        /// (ずらす前の座標で組む) と頂点の数まで食い違う。
        var unmoved: (points: [SIMD2<Float>], offset: SIMD2<Float>)?
        /// 周が楕円か弧の周なら、その元 (``Ring``)。そうでなければ `nil`。
        ///
        /// 点は元から刻んだ多角形で、**刻み方は置く先の拡大で決まる** (#1645)。保持した形は
        /// 記録のときの拡大で点まで組むので、置くときの拡大で刻み直せるよう、点とは別に持つ。
        var ring: Ring?
        /// `fill(_:)` の説明が名指す基本図形 (`rect` / `square` / `ellipse` / `circle`・一周の
        /// `arc`) の塗りの形 (``NamedFill``)。それ以外の周 (`triangle`・`quad`・`beginShape`・扇) は
        /// `nil` で、描く画素で 1 画素より細くても補わない ([#1934])。
        ///
        /// [#1934]: https://github.com/mokume-metal/mokume/issues/1934
        var namedFill: NamedFill?
        /// 閉じた周を破線に刻むとき、数え始める点の添字 (#3314)。既定は最初の点。
        ///
        /// **破線の起点だけを動かす。** 点の並びは実線・塗り・畳みの鍵に効くので動かさず、
        /// 破線の片を刻む口 (``Canvas/dashedPieces(of:by:)``) だけがここから周を回る。
        /// 角丸の矩形は `(x + r, y)` (上辺の左の弧の終わり) から数え、SVG の `<rect rx>`・
        /// p5.js の `roundRect` と同じ起点に揃える。
        var dashStart = 0
        /// 破線を刻むときだけ、``points`` の代わりに使う点 (#3314)。`nil` なら ``points`` (と ``dashStart``)。
        ///
        /// 塗りと実線の周は `start` から刻んだ点のまま動かさず、破線だけを別の点の並び (一周の弧は
        /// 角度 0 から刻んだ点) から数えるときに持つ。点の数は ``points`` と同じで、刻みの印 (``curveSteps``) を共有する。
        var dashPoints: [SIMD2<Float>]?

        /// 楕円・弧の周の元。中心は原点で、形自身の座標で持つ。
        struct Ring: Equatable {
            /// 弧のどの部分を周にするか。**円弧は閉じ方 (``ArcMode``) ごとに、塗りの周と輪郭の周が別になる**
            /// (既定は塗りが扇・輪郭が開いた弧) ので、周の元が部分まで持つ。保持した形の刻み直しも、
            /// 同じ部分を作り直す。一周は楕円と同じ形で、部分によらない。
            enum Piece: Equatable {
                /// 扇。塗りも輪郭も持つ (`.pie`)。
                case sector
                /// 扇の塗りだけ (既定の塗り)。
                case sectorFill
                /// 弧の両端を弦で結んだ形。塗りも輪郭も持つ (`.chord`)。
                case chord
                /// 弦で結んだ形の塗りだけ (`.open` の塗り)。
                case chordFill
                /// 開いた弧の輪郭だけ (既定と `.open` の輪郭)。
                case arcLine
            }
            var radiusX: Float
            var radiusY: Float
            var start: Float
            /// 弧の角度。`2π` 以上なら一周 (楕円と同じ形で、中心は周に含めない)。
            var sweep: Float
            /// 一周ぶんの分割数。点はこの数で刻んである (``Canvas/segmentCount(forRadius:scale:)``)。
            var segments: Int
            /// 弧のどの部分を周にするか。
            var piece: Piece
        }

        /// 名指しの基本図形の塗りの形。形自身の座標で、中心と半幅・半高 (楕円は半径) を持つ。
        /// 1 画素より細い塗りの補いが、ここから描く画素での細さを測る (``Canvas/thinFillPieces(_:by:)``)。
        struct NamedFill: Equatable {
            /// 楕円 (偽なら矩形)。
            var isEllipse: Bool
            var center: SIMD2<Float>
            var half: SIMD2<Float>
        }

        init(
            points: [SIMD2<Float>], isClosed: Bool, fanCenter: SIMD2<Float>? = nil,
            fillTriangles: [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)]? = nil,
            fills: Bool = true, strokes: Bool = true, curveSteps: [Bool] = [],
            cornerDiagonals: [SIMD2<Float>] = [],
            strokesAsOneRegion: Bool = false, ring: Ring? = nil, namedFill: NamedFill? = nil
        ) {
            self.points = points
            self.isClosed = isClosed
            self.fanCenter = fanCenter
            self.fillTriangles = fillTriangles
            self.fills = fills
            self.strokes = strokes
            self.curveSteps = curveSteps
            self.cornerDiagonals = cornerDiagonals
            self.strokesAsOneRegion = strokesAsOneRegion
            self.ring = ring
            self.namedFill = namedFill
        }

        /// 形自身の座標で作った周を、置き場所ぶんずらす。**畳まないときの経路。**
        func moved(by offset: SIMD2<Float>) -> Outline {
            var shiftedFill = namedFill
            shiftedFill?.center += offset
            var moved = Outline(
                points: points.map { $0 + offset }, isClosed: isClosed,
                fanCenter: fanCenter.map { $0 + offset },
                fillTriangles: fillTriangles?.map { ($0.0 + offset, $0.1 + offset, $0.2 + offset) },
                fills: fills, strokes: strokes, curveSteps: curveSteps,
                cornerDiagonals: cornerDiagonals,
                strokesAsOneRegion: strokesAsOneRegion, ring: ring, namedFill: shiftedFill)
            moved.dashStart = dashStart
            moved.dashPoints = dashPoints.map { $0.map { $0 + offset } }
            moved.unmoved = unmoved.map { ($0.points, $0.offset + offset) } ?? (points, offset)
            return moved
        }
    }

    /// 周から、塗りと輪郭を出す。
    func draw(_ outline: Outline) {
        // 区間の外では置かず、組み立てた数も数えない (``Canvas/canPlace``・#1672)
        guard canPlace else { return warnOutsideFrame(.placing) }
        outlinesAssembledThisFrame += 1
        // ベクターへ書くなら、周と置くときの変換をここで控える (#3139)
        if let sink = vectorSink() {
            recordVectorOutline(
                sink, outline, fills: outline.fills && style.hasFill,
                strokes: outline.strokes && style.hasStroke && style.strokeWeight > 0)
        }
        // 細い塗りはいまの変換で測る。記録の間は測らない — 置くときに測る (``RingFillRange``)
        if outline.fills, style.hasFill {
            fillInterior(outline, thinFillMatrix: recordingShape ? nil : transform.matrix)
        }
        if outline.strokes, style.hasStroke, style.strokeWeight > 0 { strokeOutline(outline) }
    }

    /// 形自身の座標で作った周を、置き場所へ置く。**同じ形が続く間は畳む。**
    ///
    /// 畳めるときは頂点を 1 組も積まず、置き場所を 1 つ足すだけで済む。畳めないときは
    /// 周を置き場所ぶんずらして今までどおり積む — 足す順が入れ替わるだけなので、
    /// **絵は 1 ビットも変わらない**。
    ///
    /// **周は閉包で受け取る。** 開いている雛形と同じ形なら置き場所を 1 つ足すだけで、
    /// 周は 1 度も作らない (#752 — 畳めても無条件に周を組んでいたのを直した)。
    ///
    /// **円の分割数は、置き場所の拡大で決まる** ([#1645])。周を刻む数と円板の周を刻む数を鍵に入れ、
    /// 周の閉包は鍵の数で周を刻む。拡大の違う置き場所は、分割数が違えば別の雛形になり、
    /// 同じなら 1 つの雛形に畳まれる (鍵に入れるのは拡大そのものではなく整数の分割数)。
    ///
    /// [#1645]: https://github.com/mokume-metal/mokume/issues/1645
    func draw(
        folding form: FlatForm, at anchor: SIMD2<Float>,
        outline makeOutline: (_ ringSegments: Int) -> Outline
    ) {
        // 区間の外では、畳む相手の控えも雛形も動かさない (``Canvas/canPlace``・#1672)
        guard canPlace else { return warnOutsideFrame(.placing) }
        // ここへ来るのは貼る絵か断片が効いている図形だけ (``formAllowed(fills:)``)。塗りはベクターへ書けないので
        // 数えて落とし、輪郭は真の形で書く。内側で通る `draw(_ outline:)` が 2 度控えないよう止める (#3139)
        let heldVector = suspendVectorRecordingShadedFigure(form, at: anchor)
        defer { resumeVector(heldVector) }
        let hasStroke = style.hasStroke && style.strokeWeight > 0
        // 拡大率は置き場所ごとに 1 度だけ求める。鍵・周・円板のどれもこの値から分割数を決める
        let scale = Self.splitScale(of: transform.matrix)
        // `Optional.map` に閉包を渡さない — 置き場所ごとに隔離の実行時検査を払う (#1779)
        var ringSegments = 0
        if let radius = form.ringRadius {
            ringSegments = ringSplitMemo.count(forRadius: radius, scale: scale)
        }
        // 細い塗り: 広げ方を頂点段へ移した畳みでは、置き場所ごとの記述を求める (#2208)。雛形の鍵には
        // 片の数 (置き場所の片の数そのもの・上限 64) だけが入る。移さない形 (検査が比べる) は、鍵に 2x2 そのものを入れる
        var thinFill: ThinFillPlacing?
        var thinFillCapacity = 0
        var fillLinear: ThinFold?
        if expandsThinFillsInVertexStage {
            if style.hasFill,
                let record = thinFillRecord(of: form, drawn: drawnLinear(transform.matrix))
            {
                // 位置と平行移動は記述の外に持つ — 位置が違うだけの置き場所は同じ記述を指す
                let columns = transform.matrix.columns
                thinFill = ThinFillPlacing(
                    record: record, anchor: anchor, translation: SIMD2(columns.3.x, columns.3.y))
                thinFillCapacity = ThinFillRecord.capacity(forPieces: record.pieceCount)
            }
        } else {
            fillLinear = thinFillLinear(form)
        }
        let key = FlatKey(
            form: form,
            hasFill: style.hasFill,
            hasStroke: hasStroke,
            strokeWeight: style.strokeWeight,
            strokeCap: style.strokeCap,
            strokeJoin: style.strokeJoin,
            // 頂点段で広げる細い塗りは周を刻まない。貼る絵が無く輪郭も無ければ、刻み方の違う置き場所も
            // 1 つの雛形に畳む (貼る絵の読み取り位置は周の囲みの箱から作るので、絵があれば刻み方も鍵に残す)
            ringSegments: thinFillCapacity > 0 && !hasStroke && style.picture == nil ? 0 : ringSegments,
            discSegments: hasStroke && form.placesDiscs(cap: style.strokeCap, join: style.strokeJoin)
                ? discSplitMemo.count(forRadius: style.strokeWeight / 2, scale: scale) : 0,
            strokeLinear: thinStrokeLinear(),
            fillLinear: fillLinear,
            thinFillCapacity: thinFillCapacity,
            texture: style.hasFill ? style.picture?.held : nil)
        guard key.hasFill || key.hasStroke else { return }

        // **貼る絵と輪郭が同居する図形は畳まない。** 塗りは絵の面を、輪郭は字形の面を
        // 読むので、1 つの図形の途中で列が割れる (`useTexture`)。1 つの雛形に収まらない
        //
        // 保持する形を記録している最中も畳まない (`recordingShape`)
        // **破線の輪郭は畳まない** ([#2835])。破線の片は置き場所ごとの輪郭から刻むので、雛形にならない
        guard !(key.texture != nil && key.hasStroke), !recordingShape,
            !(hasStroke && style.strokeDash != nil)
        else {
            return draw(makeOutline(ringSegments).moved(by: anchor))
        }

        // **畳んだ置き場所は ``beginFlat()`` も ``useTexture(_:)`` も通らない**ので、描き場所を
        // 置いた記録はここで取る (#1683 の反証)。取らないと、描いている最中の描き場所を読んで
        // 置いた図形が、注意なしに前の絵になる
        //
        // **溜め場を組み替える前に取る** ([#2042])。記録は置く描き場所の出す先を追い付かせ、その前に
        // 先に置いた分を写しへ差し替える (``Canvas/catchUpOutputForPlacing(by:)``)。下の「2 つ目が来てから
        // 畳む」組み替えの後に取ると、1 つ目の図形が雛形へ移ってから追い付くので、1 つ目まで追い付いた
        // 後の絵を読む。ここで取れば 1 つ目は閉じた列に残り、写しへ差し替わる (畳む条件からも外れる)
        //
        // [#2042]: https://github.com/mokume-metal/mokume/issues/2042
        if let graphics = (key.texture?.owner as? RenderTarget)?.drawer { note(placing: graphics) }
        notePaintPlacement()

        // 開いている雛形と同じ形なら、置き場所を足すだけで済む。**細い塗りは、片の数が小さい
        // 置き場所も大きい片の数の雛形に受ける** (片の数が上がったときだけ、新しい雛形になる)
        if let open = openFlat, open.key == key || open.key.holds(key) {
            appendFolded(
                placement(at: anchor), thinFill: thinFill, outline: { makeOutline(ringSegments) })
            return
        }
        let outline = makeOutline(ringSegments)

        // **2 つ目が来てから畳む。** 1 つ目で雛形を開くと、矩形と円を交互に置いた絵で
        // 図形の数だけ列が分かれる — 平面は元から 1 つの列にまとまるので、それは
        // 畳む前より遅い ([#424](https://github.com/mokume-metal/mokume/issues/424))
        if let waiting = pendingFlat, let joined = waiting.key.joined(with: key),
            waiting.vertexEnd == vertices.count, waiting.batchCount == batches.count
        {
            // 1 つ目の頂点を溜め場から抜き、雛形として積み直す。抜けるのは**まだ列が
            // 閉じていない末尾**にいるときだけで、上の 2 つの条件がそれを見ている
            vertices.removeLast(vertices.count - waiting.vertexStart)
            trimCoverage(to: waiting.vertexStart)
            pendingFlat = nil
            openFlatTemplate(key: joined, outline: outline)
            flatInstances.append(waiting.placement)
            if let waitingFill = waiting.thinFill { addThinFill(waitingFill) }
            appendFolded(placement(at: anchor), thinFill: thinFill, outline: { outline })
            return
        }

        // 畳む相手がまだいない。**今までどおり置いて**、次に同じ形が来るのを待つ
        closeFlatTemplate()
        let batchesBefore = batches.count
        let vertexStart = vertices.count
        draw(outline.moved(by: anchor))
        guard batches.count == batchesBefore, vertices.count > vertexStart else {
            pendingFlat = nil
            return
        }
        pendingFlat = PendingFlat(
            key: key, outline: outline, placement: placement(at: anchor),
            vertexStart: vertexStart, vertexEnd: vertices.count, thinFill: thinFill,
            batchCount: batches.count)
    }

    /// 畳んだ置き場所を 1 つ足す。**上限に達していたら、同じ形のまま雛形を開き直す。**
    ///
    /// 開き直すのは、畳まない経路へ落とすと**上限をまたいだ図形だけ組み立て方が
    /// 変わってしまう**ためである。周は上限に達したときしか要らないので閉包で受け取る。
    private func appendFolded(
        _ placement: FlatInstance, thinFill: ThinFillPlacing?,
        outline makeOutline: () -> Outline
    ) {
        // 描き場所を置いた記録は、呼び手 (``draw(folding:at:outline:)``) が組み替えの前に取っている
        if let open = openFlat, isBatchFull(flatInstances.count, since: open.instanceStart) {
            // 開き直す雛形は、開いていた雛形の片の数を引き継ぐ (片の数が上がった後に小さい片の数へ戻さない)
            openFlatTemplate(key: open.key, outline: makeOutline())
        }
        flatInstances.append(placement)
        // 細い塗りの雛形は、置き場所ごとの記述を同じ番号で足す (#2208)
        if let thinFill { addThinFill(thinFill) }
    }

    /// 雛形を 1 つ積んで開く。**開いていた列は閉じる。**
    private func openFlatTemplate(key: FlatKey, outline: Outline) {
        beginFlat()
        closeBatch()
        // 読む面は雛形を積み始める前に決める。積んでいる途中で変わると、雛形が
        // 2 つの列に割れる
        //
        // **面は鍵から引く。** いまの貼る絵から引き直すと、鍵が別の面で開いた雛形を
        // 指しているときに食い違う (`useFillTexture()` と同じ手順を鍵の側から踏む)
        if let texture = key.texture {
            texture.prepare()
            useTexture(texture)
        } else {
            useGlyphTexture()
        }

        // **雛形の頂点は白で、変換を掛けずに積む。** 色も変換も置き場所が持つので、
        // ここで焼き込むと二重に掛かる。組み立て自体は畳まないときとまったく同じ経路
        let savedTransform = transform
        let savedFill = style.fill
        let savedStroke = style.stroke
        transform = .identity
        style.fill = Self.unchangedTint
        style.stroke = Self.unchangedTint
        buildingFlatTemplate = true
        // 細い線の雛形は、鍵の変換で細さを測って広げる (#1637・``thinStrokeMatrix``)
        templateStrokeMatrix = key.strokeLinear.map { Self.placementMatrix($0.linear) }
        outlinesAssembledThisFrame += 1
        // 細い塗りの雛形は、鍵の変換で細さを測って広げる (#1934・``FlatKey/fillLinear``)
        var thinFillUV: SIMD4<Float>?
        if key.hasFill {
            if key.thinFillCapacity > 0 {
                // 頂点は「片の番号と角の番号」で、片は頂点段が置き場所ごとの記述から組む (#2208)
                thinFillUV = fillThinTemplate(capacity: key.thinFillCapacity, outline: outline)
            } else {
                fillInterior(
                    outline, thinFillMatrix: key.fillLinear.map { Self.placementMatrix($0.linear) })
            }
        }
        let strokeStart = vertices.count
        // 円板の分割数は鍵が持つ。雛形は変換を掛けずに積むので、変換からは決まらない (#1645)
        if key.hasStroke { strokeOutline(outline, discSegments: key.discSegments) }
        buildingFlatTemplate = false
        templateStrokeMatrix = nil
        transform = savedTransform
        style.fill = savedFill
        style.stroke = savedStroke

        openFlat = OpenFlat(
            key: key, strokeStart: strokeStart, instanceStart: flatInstances.count,
            thinFillStart: thinFillSpans.count, thinFillUV: thinFillUV)
    }

    /// いまの変換で、線が描く画素 1 画素より細くなる向きがあるなら、その変換の 2x2 (#1637)。
    /// 畳みの鍵 (``FlatKey/strokeLinear``) に入る。線を持たない図形と、どの向きでも細く
    /// ならない線は `nil` で、これまでどおり変換の違う置き場所も同じ雛形に畳む。
    private func thinStrokeLinear() -> ThinFold? {
        guard style.hasStroke, style.strokeWeight > 0 else { return nil }
        let matrix = transform.matrix
        let drawn = drawnLinear(matrix)
        guard Self.thinnestDrawnWeight(style.strokeWeight, by: drawn) < 1 else { return nil }
        return ThinFold(
            key: Self.rotationFreeKey(drawn),
            linear: SIMD4(
                matrix.columns.0.x, matrix.columns.0.y, matrix.columns.1.x, matrix.columns.1.y))
    }

    /// 置き場所の 2x2 (``ThinFold/linear``) を、細さを測る行列にする (平行移動は細さに効かない)。
    static func placementMatrix(_ linear: SIMD4<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4(linear.x, linear.y, 0, 0), SIMD4(linear.z, linear.w, 0, 0),
            SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
    }

    /// 掛けても値の変わらない色。雛形の頂点はこれで積む。
    private static let unchangedTint = LinearRGBA(
        premultipliedRed: 1, green: 1, blue: 1, alpha: 1)

    /// いまの変換と塗りから、置き場所を 1 つ作る。
    private func placement(at anchor: SIMD2<Float>) -> FlatInstance {
        let columns = transform.matrix.columns
        return FlatInstance(
            linear: SIMD4(columns.0.x, columns.0.y, columns.1.x, columns.1.y),
            offset: transform.placed(x: anchor.x, y: anchor.y),
            fill: fillVertexColor, stroke: style.stroke)
    }

    /// 周の内側を塗る。
    ///
    /// 貼る絵があれば、**周の囲みの箱**を 0…1 に写した読み取り位置を付ける。組み込みの
    /// 図形はどれも周だけで表されているので、ここ 1 箇所で全部に効く。
    ///
    /// **名指しの基本図形の塗りが、`thinFillMatrix` で置いて描く画素で 1 画素より細ければ、広げて
    /// 被覆で掛ける** ([#1934]・``thinFillPieces(_:by:)``)。細さを測る行列は呼ぶ側が渡す — 直に
    /// 置くときはいまの変換、畳みの雛形は鍵の変換 (``FlatKey/fillLinear``)、保持する形の記録は
    /// `nil` (置くときに測る)。
    ///
    /// **保持する形の記録では、楕円・弧と名指しの基本図形の塗りに組み直す素材を添える** ([#1645]・
    /// [#1934])。置くときの拡大で要る分割数が記録のときより増えるなら刻み直した頂点に
    /// (``rescaledFillVertices(_:placedBy:cache:fill:)``)、置いた後に細くなるなら広げた頂点に
    /// (``thinFillVertices(_:placedBy:cache:fill:)``) 差し替える。
    ///
    /// [#1645]: https://github.com/mokume-metal/mokume/issues/1645
    /// [#1934]: https://github.com/mokume-metal/mokume/issues/1934
    private func fillInterior(_ outline: Outline, thinFillMatrix: simd_float4x4?) {
        let start = vertices.count
        if let named = outline.namedFill, let thinFillMatrix,
            let pieces = Self.thinFillPieces(named, by: drawnLinear(thinFillMatrix))
        {
            fillThin(pieces, outline: outline)
        } else {
            fillInteriorTriangles(outline)
        }
        guard recordingShape, outline.ring != nil || outline.namedFill != nil,
            vertices.count > start
        else { return }
        // 矩形の素材は周を持たず、細さを測る形だけを持つ (``RingFillRecipe``・#1934 の反証 7)
        recordedFillRanges.append(
            RingFillRange(
                start..<vertices.count,
                recipe: RingFillRecipe(
                    outline: outline, color: fillVertexColor, hasPicture: style.picture != nil,
                    transform: transform, uv: whiteUV)))
    }

    private func fillInteriorTriangles(_ outline: Outline) {
        let points = outline.points
        guard points.count >= 3 else { return }
        let fillColor = fillVertexColor
        if let triangles = outline.fillTriangles {
            let uvOf = style.picture == nil ? nil : Self.boxUV(of: points)
            for (a, b, c) in triangles {
                // `Optional.map` に閉包を渡さない — 三角形ごとに隔離の実行時検査を払う (#1779)
                var uvs: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)?
                if let uvOf { uvs = (uvOf(a), uvOf(b), uvOf(c)) }
                appendTriangle(
                    transform.placed(x: a.x, y: a.y), transform.placed(x: b.x, y: b.y),
                    transform.placed(x: c.x, y: c.y),
                    colors: (fillColor, fillColor, fillColor), uvs: uvs)
            }
            return
        }
        let pivot = outline.fanCenter ?? points[0]
        let center = transform.placed(x: pivot.x, y: pivot.y)
        // 中心を持つ図形は全周を扇に分け、持たない図形は最初の点から分ける
        let ring = outline.fanCenter == nil ? Array(points.dropFirst()) : points
        guard ring.count >= 2 else { return }

        // 箱は**周そのもの**から作る。扇の中心は周の内側にあるので、含めても広がらない
        let uvOf = style.picture == nil ? nil : Self.boxUV(of: points)

        func place(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ bSource: SIMD2<Float>,
            _ c: SIMD2<Float>, _ cSource: SIMD2<Float>)
        {
            var uvs: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)?
            if let uvOf { uvs = (uvOf(pivot), uvOf(bSource), uvOf(cSource)) }
            appendTriangle(a, b, c, colors: (fillColor, fillColor, fillColor), uvs: uvs)
        }

        var previous = transform.placed(x: ring[0].x, y: ring[0].y)
        var previousSource = ring[0]
        for point in ring.dropFirst() {
            let current = transform.placed(x: point.x, y: point.y)
            place(center, previous, previousSource, current, point)
            previous = current
            previousSource = point
        }
        if outline.fanCenter != nil, outline.isClosed {
            let first = transform.placed(x: ring[0].x, y: ring[0].y)
            place(center, previous, previousSource, first, ring[0])
        }
    }

    /// 弧の上の点を返す。円と楕円は「一周ぶんの弧」であり、別の道具にはしない。
    ///
    /// 一周を `fullTurn` 個に刻み、その `sweep / 2π` を刻む (``arcOffsets(radiusX:radiusY:from:sweep:fullTurn:)``)。
    static func arcPoints(
        center: SIMD2<Float>, radiusX: Float, radiusY: Float, from start: Float, sweep: Float,
        fullTurn: Int
    ) -> [SIMD2<Float>] {
        var points = arcOffsets(
            radiusX: radiusX, radiusY: radiusY, from: start, sweep: sweep, fullTurn: fullTurn)
        for index in points.indices { points[index] = center + points[index] }
        return points
    }

    /// 楕円・弧の周を、一周を `ring.segments` 個に刻んだ周にする。**中心は原点。**
    /// 一周ならば中心は周に含めず、弧ならば部分 (``Outline/Ring/Piece``) で決まる。扇は中心を
    /// 最初の点にする (扇の 3 つの角のうち中心と、弧の両端が周の点になる・#1486)。弦は弧の点だけを
    /// 閉じ、開いた弧は閉じない。周の点はどれも刻みで、角は 1 つも無い (#1423)。弦の両端 (弦と弧が作る角) も
    /// 丸く繋ぐ (扇の角と同じ)。
    ///
    /// 周を組む口 (`ellipse` / `arc`) と、保持した形を置くときに刻み直す口
    /// (``Outline/Ring``・#1645) が同じ周を作る。
    static func ringOutline(_ ring: Outline.Ring) -> Outline {
        let arcPoints = arcPoints(
            center: SIMD2(0, 0), radiusX: ring.radiusX, radiusY: ring.radiusY, from: ring.start,
            sweep: ring.sweep, fullTurn: ring.segments)
        let isFullTurn = ring.sweep >= 2 * .pi
        if !isFullTurn {
            switch ring.piece {
            case .sector, .sectorFill:
                break
            case .chord, .chordFill:
                // 弧の点だけを閉じる。最初の点からの扇で塗れる (弦で切った弧は凸)。**弦と弧が出会う 2 つの角も、
                // 折れ目の形によらず丸く繋ぐ** — 距離関数の経路は輪郭を距離の帯で出すので、扇の角と同じく丸くなる。
                // **弧の点が 2 個 (細い掃引) でも閉じる** — 弦と弧の 2 辺の周で、距離関数の経路の閉じた弓形と揃う
                // (開いた線にすると、輪郭が `strokeCap` の端を持つ線分で出る・#2428)
                return Outline(
                    points: arcPoints, isClosed: true, strokes: ring.piece == .chord,
                    curveSteps: Array(repeating: true, count: arcPoints.count),
                    strokesAsOneRegion: true, ring: ring)
            case .arcLine:
                return Outline(
                    points: arcPoints, isClosed: false, fills: false,
                    curveSteps: Array(repeating: true, count: arcPoints.count),
                    strokesAsOneRegion: true, ring: ring)
            }
        }
        let points = isFullTurn ? arcPoints : [SIMD2(0, 0)] + arcPoints
        // 一周は楕円と同じ形で、`fill` の説明が名指す基本図形に入る。扇は入らない (#1934)
        return Outline(
            points: points, isClosed: true, fanCenter: SIMD2(0, 0),
            strokes: ring.piece != .sectorFill,
            curveSteps: Array(repeating: true, count: points.count), strokesAsOneRegion: true,
            ring: ring,
            namedFill: isFullTurn
                ? Outline.NamedFill(
                    isEllipse: true, center: SIMD2(0, 0), half: SIMD2(ring.radiusX, ring.radiusY))
                : nil)
    }

    /// 弧の上の点の、中心からのずれ。**中心を足せば ``arcPoints(center:radiusX:radiusY:from:sweep:fullTurn:)``
    /// と 1 ビットも違わない** — 点は `center.x + radiusX * cos(angle)` で、掛け算を先に済ませて
    /// から中心を足す式なので、ずれを控えて後から足しても同じ値になる (#1785)。
    ///
    /// - Parameter scale: 画面への拡大率 (``splitScale(of:)``)。分割数は拡大した後の半径で決める
    ///   ([#1645])。1 なら、これまでと同じ分割数になる。**既定値を置かない** — この Issue の根は、
    ///   分割数を決める口が拡大を渡し忘れたことだった。拡大を見ない口は、1 と書いて理由を添える。
    ///
    /// [#1645]: https://github.com/mokume-metal/mokume/issues/1645
    static func arcOffsets(
        radiusX: Float, radiusY: Float, from start: Float, sweep: Float, scale: Float
    ) -> [SIMD2<Float>] {
        arcOffsets(
            radiusX: radiusX, radiusY: radiusY, from: start, sweep: sweep,
            fullTurn: segmentCount(forRadius: max(radiusX, radiusY), scale: scale))
    }

    /// 一周を `fullTurn` 個に刻んだ弧の上の点の、中心からのずれ。
    static func arcOffsets(
        radiusX: Float, radiusY: Float, from start: Float, sweep: Float, fullTurn full: Int
    ) -> [SIMD2<Float>] {
        let segments = max(1, Int((Float(full) * sweep / (2 * .pi)).rounded(.up)))
        let step = sweep / Float(segments)
        // 一周は最後の点が最初と重なるので落とす
        let count = sweep >= 2 * .pi ? segments : segments + 1
        // 閉包を標準ライブラリへ渡さずにループで回す。main actor の文脈の閉包は、点ごとに
        // 隔離の実行時検査を払う (#1779)
        var points: [SIMD2<Float>] = []
        points.reserveCapacity(count)
        for index in 0..<count {
            let angle = start + step * Float(index)
            points.append(SIMD2(radiusX * RuntimeMath.cos(angle), radiusY * RuntimeMath.sin(angle)))
        }
        return points
    }

    /// 4 つの数を、左上の角と大きさへ読み替える。
    static func resolveBox(_ a: Float, _ b: Float, _ c: Float, _ d: Float, mode: ShapeMode)
        -> (x: Float, y: Float, width: Float, height: Float)
    {
        switch mode {
        case .corner: return (a, b, c, d)
        case .corners: return (min(a, c), min(b, d), abs(c - a), abs(d - b))
        case .center: return (a - c / 2, b - d / 2, c, d)
        case .radius: return (a - c, b - d, c * 2, d * 2)
        }
    }

    /// 円を近似する多角形の辺の数。
    ///
    /// 多角形と真円の隔たりがいちばん大きいのは辺の中央で、その差は
    /// `r(1 − cos(π/n))`。これを 0.25 画素以下に収める `n` を選ぶ。
    ///
    /// **式が返す値をそのまま使う。** 下限 3 は多角形が成立する最小の辺数であって、
    /// 精度の判断ではない — 精度は式が持っている。かつては下限 32 を掛けていたが、
    /// 根拠がどこにも無く、直径 12 の円 (式は 11 を返す) に 3 倍の頂点を組み立てて
    /// いた。10,000 個置くと 40fps まで落ちる ([#423])。
    ///
    /// **上限 1024 は品質の判断ではなく、暴走の歯止めである。** 式は大きな半径で
    /// `n ≈ π√(2r)` に漸近するので、半径 10⁹ のような値が紛れ込むと 1 個の円に
    /// 14 万辺を割いてしまう。上限 `n` に対して保証が届く半径は `r = n²/(2π²)` で、
    /// 1024 なら約 53,000 — 面より桁違いに大きい円まで保証の内側に居る。
    ///
    /// かつての上限 128 は「大きすぎる円に 128 辺を超えて割いても見た目は変わらない」
    /// を根拠にしていたが、実際には変わっていた。半径 20000 の円は、画面に映る
    /// 800 列のうち 677 列で 1 画素以上・最大 6 画素ずれる ([#429] で実測)。
    ///
    /// **この式に渡す半径は、画面に出る半径である** ([#1645])。`scale` で拡大した円は、拡大した
    /// 後の半径で分割数を決める (``segmentCount(forRadius:scale:)``) — 形自身の座標の半径で決めると、
    /// 拡大した円の保証が画面の上で外れる (`scale(20)` の太さ 1 の丸い端は、半径 0.5 → 3 分割
    /// なので、画面の半径 10 の三角形になっていた)。この式自身は拡大を知らない。
    ///
    /// **製品の呼び出しは、`scale:` 付きの口 (``segmentCount(forRadius:scale:)``) 1 か所だけ** で、
    /// 拡大率 1 のときと数でない半径をここへ渡す。拡大を渡し忘れる呼び口が再び作れないよう、ほかの
    /// 口はここを直には呼ばない。この口を残すのは、式そのものを `CircleSegmentTests` が固定するため。
    ///
    /// [#423]: https://github.com/mokume-metal/mokume/issues/423
    /// [#429]: https://github.com/mokume-metal/mokume/issues/429
    /// [#1645]: https://github.com/mokume-metal/mokume/issues/1645
    static func segmentCount(forRadius radius: Float) -> Int {
        let tolerance = 0.25
        let cap = 1024
        // 隔たりが許容誤差に届かない円は、いちばん粗い多角形で足りる
        guard radius.isFinite, Double(radius) > tolerance else { return 3 }
        // **倍精度で解く。** 半径が大きいほど `1 − tolerance/r` は 1 に貼り付き、
        // 単精度では引き算で桁が落ちる — 半径 20000 で 629 ではなく 628 を返し、
        // 上限とは別に保証を 0.2% 外していた ([#429])
        let radians = RuntimeMath.acos(max(-1, 1 - tolerance / Double(radius)))
        // 角度が潰れるのは半径が大きすぎるとき。いちばん**細かい**側へ倒す
        // (かつては 3 を返し、半径 10⁷ の円が三角形になっていた)
        guard radians > 0 else { return cap }
        return min(cap, max(3, Int((Double.pi / radians).rounded(.up))))
    }

    /// 半径 `radius` の円が、`scale` 倍に拡大されて画面に出るときの分割数 ([#1645])。
    ///
    /// 拡大した後の半径 `radius × scale` を ``segmentCount(forRadius:)`` へ渡す。`scale` が 1 なら
    /// 同じ値を返す。拡大率は ``splitScale(of:)`` で取る (縮めても 1 のまま)。
    ///
    /// [#1645]: https://github.com/mokume-metal/mokume/issues/1645
    static func segmentCount(forRadius radius: Float, scale: Float) -> Int {
        guard scale != 1, radius.isFinite else { return segmentCount(forRadius: radius) }
        let drawn = Double(radius) * Double(scale)
        // 拡大が桁違いで単精度に収まらないときは、いちばん細かい側へ倒す (数でなければ式に任せる)
        guard drawn.isFinite else { return segmentCount(forRadius: .nan) }
        return segmentCount(forRadius: Float(min(drawn, Double(Float.greatestFiniteMagnitude))))
    }

    /// 角度が逆向きの円弧を、初回だけ知らせる。
    ///
    /// 毎フレーム起きうるので繰り返さない (``Diagnostics/warn(_:)`` の但し書き)。
    func warnReversedArcOnce() {
        warnOnce(
            .reversedArc,
            "arc(): the ending angle has to be larger than the starting one. This call draws nothing")
    }

}
