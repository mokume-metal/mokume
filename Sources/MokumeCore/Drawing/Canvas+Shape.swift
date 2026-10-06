// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 保持した形。意味の説明は利用者が最初に触る層 (`Sketch`) が正本で、ここは受け口である
// ([ADR-0020] 決定 4)。
//
// 組み立ては**いつもの描画をそのまま記録する**形で行う。図形の三角形分割も輪郭の生成も
// 経路が 1 つしかないので、保持した形と即時に描いた形が食い違わない。奥行きを持つ頂点も
// 同じ経路を通るので、**立体だけ保持できないということが起きない** ([ADR-0021] 決定 5)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
extension Canvas {
    /// 形を組み立てて保持する。
    public func createShape(_ body: () -> Void) -> Shape {
        // **入口と出口は、ランタイムが持つ乱数の列へも知らせる** (#1936)。中で書いた種は ``Manner`` の
        // 外 (`Canvas` の外) にあるので、出口の戻しはそちらが受ける。早い抜け方 (下の空の形) でも
        // 対で呼ぶよう、`defer` で置く
        //
        // **知らせる先は面ではなく、いま走っているランタイムと同じ寿命の 1 口から引く** (#2041)。
        // 面の作り方 (直に作った面・描き場所) に依らず、種を書く先と同じランタイムへ届く。入口で
        // 1 度だけ引いて控え、出口も同じ相手へ知らせる
        let listener = shapeAssemblyListener
        listener?.shapeAssemblyBegan()
        defer { listener?.shapeAssemblyEnded() }
        closeBatch()
        let vertexStart = vertices.count
        let solidStart = solidVertices.count
        let solidIndexStart = solidIndices.count
        let formStart = formInstances.count
        let instanceStart = solidInstances.count
        let runStart = batches.count

        // 記録の間に触った状態は外へ出さない。**形自身の座標で記録する**ので、
        // 変換も畳んでおく — そうしないと、組み立てた場所でしか置けない形になる
        //
        // **積み降ろし (`pushStyle()` / `pushMatrix()`) は使わず、写し取って戻す。**
        // 断片と数の並びはスタイルの一式に無いので、積み降ろしが効いても戻らなかった
        // ([#836])。積み降ろしがフレームの中でしか効かなかった頃は、`setup()` で組み立てる
        // と退避も復帰も空振りし、中で置いた塗りが外へ残ったうえ、利用者が触っていない
        // 積み降ろしの警告だけが出ていた ([#1041])。**いまは記録の間も積み降ろしが効く**
        // (`Canvas.isShaping`) が、写し取る形はそのままにしてある — 戻す対象が
        // スタイルの一式より広いことは変わらない。
        //
        // 断片と並びは**入口では外さない** — 組み立ての間に効いている塗りは形に焼き付く
        // (#788)。戻すのは出口だけで、読む面と同じ扱いである
        //
        // **何を戻すかは ``Manner`` 1 か所が持つ** ([#1684])。写す・戻すを出入口に並べていた
        // ので、並べ落とした曲線の細かさと揺らぎの設定が外へ漏れていた ([#1646])。`Canvas` の
        // 格納と `Style` のフィールドを 1 つ残らず「戻す・切り離す・断る・触らない」に分けた表は
        // 検査が持ち (`ShapeExitTests`)、格納を足すとそこで止まる
        //
        // [#836]: https://github.com/mokume-metal/mokume/issues/836
        // [#1041]: https://github.com/mokume-metal/mokume/issues/1041
        // [#1646]: https://github.com/mokume-metal/mokume/issues/1646
        // [#1684]: https://github.com/mokume-metal/mokume/issues/1684
        let savedManner = Manner(of: self)
        transform = .identity
        // 切り抜きは外さない — 記録した区間は切り抜きを持たない (``Shape/Run``) ので、記録の中で
        // 効いていても形には入らない。外して出口で戻すと、組み立ての中でフレームが閉じたときに
        // 閉じたフレームの切り抜きを書き戻す (``Manner`` は形に焼き付かないものを戻さない・#1684)
        // **記録の間は畳まない。** 畳むと置き場所が溜め場の側に残り、記録した頂点からは
        // どこへ置くかが落ちる (`Canvas.recordingShape`)
        let savedRecording = recordingShape
        recordingShape = true
        // **積んだ履歴は記録の中で閉じる。** 記録の間も `push()` / `pop()` は効く
        // (`Canvas.isShaping`) ので、切り離さないと記録の中の `pop()` が記録より前に
        // 積んだ段を取り、記録の中で積んだまま抜けた段はあとの `pop()` に拾われる
        // ([#1172])
        //
        // [#1172]: https://github.com/mokume-metal/mokume/issues/1172
        let savedStacks = takeStacks()
        // **組み立て中の形も記録の中で閉じる** ([#1607])。積み履歴と同じく、形の組み立ては
        // 釣り合う単位の 1 つである (ADR-0021 決定 4 の追補 (2026-09-15)・(2026-09-27))。
        // 切り離さないと、外で開いた形を記録の中の `beginShape()` が黙って上書きし、記録の中で
        // 開いたままの形は外へ漏れて、外の `vertex()` が形自身の座標の点に積み足す
        //
        // [#1607]: https://github.com/mokume-metal/mokume/issues/1607
        let savedShape = takeOpenShape()
        let strokeRangeStart = recordedStrokeRanges.count
        let fillRangeStart = recordedFillRanges.count
        let solidStrokeStart = recordedSolidStrokes.count
        let gpuStrokeStart = recordedGPUStrokes.count
        let discardsAtStart = pendingDiscards

        body()

        // 記録の中で開いたまま抜けた形は、形ごと捨てて 1 度知らせる。外で開いていた形はその後に
        // 戻す — 記録の中からは続けられない
        discardShapeLeftOpen()
        restoreOpenShape(savedShape)
        recordingShape = savedRecording
        restore(savedStacks)
        closeBatch()
        // 状態を戻すのは、記録したぶんを溜め場から抜いた後 (下の「抜いてから状態を戻す」)
        defer { savedManner.restore(on: self) }
        // **出口の安全網** ([#1588])。記録の途中で溜め場を捨てると、上で控えた区間は溜め場の外を
        // 指す。塗り直しと画素の口は記録の中で断るが、描き切りそのものを断れない口が残る (置いた
        // 描き場所の描き換えが本体を描き切らせる・揺らぎの設定の書き換え)。捨てる前に記録した
        // ものはもう描かれていて取り戻せないので、捨てた後に記録した残りも溜め場から抜き、空の形を
        // 返す。見分けは長さではなく捨てた回数で行う (``pendingDiscards``)
        //
        // [#1588]: https://github.com/mokume-metal/mokume/issues/1588
        guard pendingDiscards == discardsAtStart else {
            // 前の区切りで描いた立体の影 (持ち越した落とす側) は残す (#1656)
            discardPending(keepingCasters: true)
            warnInsideShape(.drawnOut)
            return .empty
        }
        let recorded = Array(vertices[vertexStart...])
        // 輪郭の区間も形自身の 0 起点へ引き戻し、覚えていた側からは抜く (入れ子の記録なら
        // 外側の記録には、置き直した頂点の区間として `place(_:of:at:)` が積み直す)。
        // 引いて積んだ頂点は区間の番号を持たないので、区間だけを引き戻す
        let recordedStrokes = recordedStrokeRanges[strokeRangeStart...].map {
            $0.shifted(by: -vertexStart)
        }
        recordedStrokeRanges.removeLast(recordedStrokeRanges.count - strokeRangeStart)
        // 楕円・弧の塗りの区間も、同じく形自身の 0 起点へ引き戻して抜く (#1645)
        let recordedFills = recordedFillRanges[fillRangeStart...].map {
            $0.shifted(by: -vertexStart)
        }
        recordedFillRanges.removeLast(recordedFillRanges.count - fillRangeStart)
        let recordedSolid = Array(solidVertices[solidStart...])
        // 立体の線の元も形自身の 0 起点へ引き戻し、覚えていた側からは抜く (入れ子の記録
        // なら外側の記録には、置き直した線として `placeSolid` が積み直す)
        let recordedPieces = recordedSolidStrokes[solidStrokeStart...].map { piece in
            var piece = piece
            piece.vertexStart -= solidStart
            return piece
        }
        recordedSolidStrokes.removeLast(recordedSolidStrokes.count - solidStrokeStart)
        var recordedGPU: [RetainedGPUStroke] = []
        for var stroke in recordedGPUStrokes[gpuStrokeStart...] {
            stroke.vertices = (stroke.vertices.lowerBound - solidStart)..<(stroke.vertices.upperBound - solidStart)
            recordedGPU.append(stroke)
        }
        recordedGPUStrokes.removeLast(recordedGPUStrokes.count - gpuStrokeStart)
        // **添字の値も形自身の 0 起点へ引き戻す。** 値は頂点の並びの番号そのものなので、
        // 区間だけずらすと記録した形が溜め場に残っていた頂点を指す (``Shape/solidIndices``)
        let recordedIndices = solidIndices[solidIndexStart...].map { $0 - UInt32(solidStart) }
        let recordedForms = Array(formInstances[formStart...])
        // 記録した形 1 つずつの部品も、形自身の 0 起点へ引き戻す (``Shape/solidParts``)
        var recordedParts: [SolidPart] = []
        for batch in batches[runStart...] where batch.source == .solid {
            for part in batch.backFaceParts {
                recordedParts.append(part.shifted(by: part.isIndexed ? -solidIndexStart : -solidStart))
            }
        }
        let runs = batches[runStart...].map {
            var run = $0.run
            switch run.source {
            case .flat: run.start -= vertexStart
            case .solid:
                run.start -= solidStart
                if run.isIndexed { run.indexStart -= solidIndexStart }
            case .form: run.start -= formStart
            }
            return run
        }

        // 記録したぶんを溜め場から抜く。**抜いてから状態を戻す** — 先に戻すと、
        // 記録した頂点が戻したあとの設定で閉じられる
        vertices.removeLast(vertices.count - vertexStart)
        trimCoverage(to: vertexStart)
        solidVertices.removeLast(solidVertices.count - solidStart)
        solidIndices.removeLast(solidIndices.count - solidIndexStart)
        formInstances.removeLast(formInstances.count - formStart)
        // 記録の間に開いた置き場所も抜く。**形は何も動かさない置き場所で置き直される**
        // ので、記録側で持ち歩く必要が無い
        solidInstances.removeLast(solidInstances.count - instanceStart)
        batches.removeLast(batches.count - runStart)

        return Shape(
            vertices: recorded, solidVertices: recordedSolid, solidIndices: recordedIndices,
            forms: recordedForms, runs: Array(runs), strokeRanges: recordedStrokes,
            fillRanges: recordedFills,
            solidStrokes: recordedPieces, gpuStrokes: recordedGPU, solidParts: recordedParts)
    }

    /// 形の組み立ての出口で、組み立て前へ戻す状態 ([#1684])。入口で写し、出口で戻す。
    ///
    /// 載せるのは**形に焼き付く描き方**と、形自身の座標で記録するために畳む変換である。描き方は
    /// 形の中で効き (組み立てるコードを読めば何色・何段で刻まれるかが分かる)、外へは残らない。
    /// 形に焼き付かない設定 (シーンの記述・露出) は、ここで戻すのではなく組み立ての中で断る
    /// (``admits(_:)``)。積み履歴と組み立て中の形は、ここではなく切り離して閉じる。
    ///
    /// **`Style` のうちフレームに属するフィールド (切り抜き・材質・影の落とし方と受け方) は
    /// 戻さない** (``Style/keepingFrameFields(of:)``)。組み立ての中では断るので普段は変わらないが、
    /// 組み立ての中でフレームが閉じる (描き場所の組み立ての中の `endDraw()`) と、閉じる側が
    /// 既定へ戻した値を、出口が閉じたフレームの値で書き戻していた。フレームの頭はこの 3 つを
    /// 戻さないので、次のフレームへ持ち越された (#1671 が塞いだのと同じ破れ方・#1684 の反証)。
    ///
    /// **`Canvas` の外にある状態は、ここではなく ``ShapeAssemblyListener`` が受ける** (乱数の種・
    /// [#1936])。
    ///
    /// **項目を足すときは、検査の表 (`ShapeExitTests`) の「戻す」に汚す手順も足す。** 表が
    /// 汚して、出口の直後に戻ったかを見る。「断る」に載る `Style` のフィールドは、組み立ての中で
    /// フレームを閉じた後に書き戻されないかを表が見る。
    ///
    /// [#1684]: https://github.com/mokume-metal/mokume/issues/1684
    /// [#1936]: https://github.com/mokume-metal/mokume/issues/1936
    struct Manner {
        let style: Style
        let transform: Transform
        let texture: HeldTexture
        let shader: Shader?
        let numbers: Numbers?
        let curveDetail: Int
        let curveTightness: Float
        /// 揺らぎの種と細かさ。形に焼き付くのは、記録の中で CPU の `noise()` が返した値だけで
        /// ある。断片の `mokume_noise` は描き切りの時点の種で引くので、形を置いたときの種を使う。
        let noise: ValueNoise

        init(of canvas: Canvas) {
            style = canvas.currentStyle
            transform = canvas.transform
            texture = canvas.currentTexture
            shader = canvas.currentShader
            numbers = canvas.currentNumbers
            curveDetail = canvas.currentCurveDetail
            curveTightness = canvas.currentCurveTightness
            noise = canvas.noiseSettings
        }

        /// 写した値へ戻す。
        ///
        /// **揺らぎは ``Canvas/changeNoise(_:)`` で戻す。** 置き場は描き場所と共有するので、中の
        /// 設定で溜めた図形を持つ面があれば、戻す前に描き切らせる (置いた時点の種で引く・#1503)。
        /// 書き換えていなければ何もしない。
        func restore(on canvas: Canvas) {
            canvas.currentTexture = texture
            canvas.currentShader = shader
            canvas.currentNumbers = numbers
            canvas.currentCurveDetail = curveDetail
            canvas.currentCurveTightness = curveTightness
            canvas.transform = transform
            canvas.currentStyle = style.keepingFrameFields(of: canvas.style)
            canvas.changeNoise { $0 = noise }
        }
    }

    // 保持した形を置く。
    public func shape(_ shape: Shape, _ x: some ScalarConvertible = 0, _ y: some ScalarConvertible = 0) {
        let (x, y) = (x.asFloat, y.asFloat)
        place(shape, at: [Placement(x: x, y: y)])
    }

    // 保持した形を、置き場所ぶんだけまとめて置く。
    public func shape(_ shape: Shape, at placements: [Placement]) {
        place(shape, at: placements)
    }

    /// 保持した形を、渡した置き場所ぶんだけ置く。
    ///
    /// **立体の区間は、頂点を 1 度だけ置いて置き場所を並べる。** 基本図形の区間も
    /// 置き場所に変換を掛けるだけで、頂点は触らない。三角形で組み立てた平面の区間だけは
    /// 置き場所ごとに頂点を展開する (その区間には置き場所の仕組みが無い)。どれも、同じ
    /// 置き場所を 1 つずつ書いたときと同じ絵になる。
    private func place(_ shape: Shape, at placements: [Placement]) {
        // 区間の外では置かない (``Canvas/canPlace``・#1672)。置き場所の検めより先に断る
        guard canPlace else { return warnOutsideFrame(.placing) }
        guard !shape.isEmpty else { return }
        var usable: [Placement] = []
        usable.reserveCapacity(placements.count)
        // 置けない置き場所は、何が数でなかったかを覚えて注意で名指す (#1706 の反証 7)
        var badGeometry = false
        var badFill = false
        for placement in placements {
            if placement.isUsable {
                usable.append(placement)
            } else {
                badGeometry = badGeometry || !placement.hasFiniteGeometry
                badFill = badFill || !placement.hasFiniteFill
            }
        }
        if usable.count != placements.count {
            warnBadPlacement(geometry: badGeometry, fill: badFill)
        }
        guard !usable.isEmpty else { return }

        // 半透明の色を掛ける置き場所があるときだけ、区間ごとに差し替える輪郭を求める。
        // 色を掛けない置き場所だけなら、輪郭を走査しない (輪郭の多い形を毎フレーム置いても増えない)
        var translucent = false
        for placement in usable where (placement.fill?.alpha ?? 1) < 1 {
            translucent = true
            break
        }
        replaying(shape.runs) { run in
            switch run.source {
            case .flat:
                // 差し替える輪郭は区間で決まる。置き場所ごとに求め直さない
                let carved =
                    translucent
                    ? shape.carvedStrokes(within: run.start..<(run.start + run.count)) : []
                for placement in usable { place(run, of: shape, at: placement, carved: carved) }
            case .solid:
                placeSolid(run, of: shape, at: usable)
            case .form:
                for placement in usable { placeForms(run, of: shape, at: placement) }
            }
        }
    }

    /// 記録した区間の設定へ移って `place` で頂点を積み、置く側の設定へ戻す。
    ///
    /// **記録した区間を置き直す口は、どれもここを通る** — 保持した形 (``shape(_:at:)``) と、
    /// 粒の板の 2 経路 (`placeFromGPU` / `placeFromCPU`) である。区間の設定
    /// (混ぜ方・貼る絵の面・塗り) の出入りを口ごとに写して書いていた頃は、粒の速い経路だけが
    /// 塗りと面の張り直しを落とし、置く時点の `texture()` / `shader()` で描いていた ([#1649])。
    /// 手順を 1 か所に置けば、段を足しても口ごとに足し忘れることが無い。
    ///
    /// 控えて戻すのは**並び全体で 1 度だけ**である。区間ごとに戻すと、続けて置いた形が前の形と
    /// 同じ列に並ばなくなる (移る操作は、同じなら列を閉じない)。
    ///
    /// [#1649]: https://github.com/mokume-metal/mokume/issues/1649
    func replaying(_ runs: some Sequence<Shape.Run>, _ place: (Shape.Run) -> Void) {
        let savedMode = style.blendMode
        let savedTexture = currentTexture

        for run in runs {
            // **記録した面を読む前に整える。** 組んだ後で書き換えた画像は、ここで送らないと
            // 形だけを置くフレームに出ない ([#1253])
            //
            // [#1253]: https://github.com/mokume-metal/mokume/issues/1253
            run.prepareSurfaces()
            // 区間の設定へ移る。**同じなら列は閉じない**ので、続けて置いた形は
            // 前の形と同じ列に並び、描く回数は増えない
            blendMode(run.mode)
            useTexture(run.texture)
            // **塗りも記録したものへ戻す。** 置く時点の shader() で塗ると、組み立てる
            // コードを読んでも何色になるかが分からない形になる (#788)
            usePaint(run.paint)
            if run.source == .solid {
                // **立体は区間を先に開いてから、記録した面を束ね直す。**
                // `beginSolids` は `useFillTexture()` を通るので、**置く側の**
                // `style.picture` で面を選び直してしまう — 置く側は普通 `texture()` を
                // 呼んでいないので焼き場へ倒れ、記録した面が捨てられる ([#914])。
                //
                // 直後に置くと描かれていたのは、`createShape` が `openSource` を
                // `.solid` のまま抜けて `beginSolids` が早期 return するからで、
                // **フレームをまたぐと上書きされる**という非対称になっていた。
                //
                // `beginSolids` の側は触らない。あちらの `useFillTexture()` は
                // その場で並べる頂点 (`inSolidBatch`) にとっては正しい振る舞いである。
                //
                // [#914]: https://github.com/mokume-metal/mokume/issues/914
                beginSolids()
                useTexture(run.texture)
            }
            place(run)
        }

        // 記録した設定を外へ漏らさない。**戻す操作が列を閉じる**ので、いま置いた
        // 頂点は区間の設定で描かれる
        blendMode(savedMode)
        useTexture(savedTexture)
        stopReplayingPaint()
    }

    /// 平面の区間を置く。**立体の列が開いていれば閉じる** (呼び出し順どおりに重ねる)。
    ///
    /// **掛ける色が半透明なら、不透明の線の区間は、引いて積んだ頂点に差し替える**
    /// ([#1829]・[#1920])。不透明の線は記録のとき片を重ねたまま積む
    /// (``Canvas/strokeOverlapsShow``) ので、そのまま半透明にすると角と継ぎ目だけが濃くなる。
    /// 色なしと不透明の色は、これまでどおり重ねたまま置く — 差し替えるのは、置き場所の色の
    /// 不透明度 (``LinearRGBA/alpha``) が 1 を下回るときだけである。
    ///
    /// **引くのは、その形を半透明の色で最初に置くとき 1 度だけ。** 引いた頂点は形の側
    /// (``CarvedStroke``) に控えるので、2 回目以降は控えた頂点を移して積むだけで済む。
    ///
    /// - Parameter carved: この区間で、引く素材を持つ輪郭 (``Shape/carvedStrokes(within:)``)。
    ///   半透明の色を掛ける置き場所がなければ空でよい
    ///
    /// [#1829]: https://github.com/mokume-metal/mokume/issues/1829
    /// [#1920]: https://github.com/mokume-metal/mokume/issues/1920
    private func place(
        _ run: Shape.Run, of shape: Shape, at placement: Placement, carved candidates: [StrokeRange]
    ) {
        // **まとめて写してから、その場で移す。** 1 頂点ずつ足すと、置くたびに
        // 溜め場の伸長判定を通ることになる — 保持の速さはここで決まる
        let base = vertices.count
        beginFlat()
        let runRange = run.start..<(run.start + run.count)
        let matrix = transform.matrix * placement.transform.matrix
        let tint = placement.fill
        // 差し替える輪郭 (頂点の並びの順)。色を掛けない置き場所は、半透明の分が空になる。
        // 置いた後に細くなる輪郭は、色によらず組み直した頂点で差し替える (#1637)
        let translucent = (tint?.alpha ?? 1) < 1
        let replaced = replacements(
            in: runRange, of: shape, placedBy: matrix, translucent: translucent,
            carved: translucent ? candidates : [])
        if replaced.isEmpty {
            vertices.append(contentsOf: shape.vertices[runRange])
        } else {
            var cursor = run.start
            for (range, replacement, coverage) in replaced {
                vertices.append(contentsOf: shape.vertices[cursor..<range.lowerBound])
                // 組み直した細い輪郭の被覆は、積んだ先の番号へずらして付ける (#1637)
                let at = vertices.count
                vertices.append(contentsOf: replacement)
                for span in coverage {
                    noteCoverage(
                        span.value,
                        in: (at + span.range.lowerBound)..<(at + span.range.upperBound))
                }
                cursor = range.upperBound
            }
            vertices.append(contentsOf: shape.vertices[cursor..<runRange.upperBound])
        }
        let end = vertices.count
        vertices.withUnsafeMutableBufferPointer { buffer in
            for index in base..<end { Self.move(&buffer[index], by: matrix, tint: tint) }
        }
        // **輪郭は、行列を掛けた直後に画面で半画素寄せる** (`Shape.strokeRanges`)。記録の中で
        // 置き直すときは変換がまだ決まらないので寄せず、外側の記録へ区間を渡す。差し替えた
        // 輪郭は頂点の数が変わるので、置いた先の区間はずれを足して求める
        var shift = 0
        var next = 0
        // 区間だけを読む。`StrokeRange` ごと写すと、置くたびに引いた頂点の参照を数え直す
        for index in shape.strokeRanges.indices {
            let whole = shape.strokeRanges[index].range
            guard whole.overlaps(runRange) else { continue }
            // 手前にある差し替え (刻み直した楕円・弧の塗り・#1645) の頂点数の違いも、ずれへ足す
            while next < replaced.count, replaced[next].range.upperBound <= whole.lowerBound {
                shift += replaced[next].vertices.count - replaced[next].range.count
                next += 1
            }
            let lower = max(whole.lowerBound, runRange.lowerBound)
            let upper = min(whole.upperBound, runRange.upperBound)
            let placed: Range<Int>
            var carved: CarvedStroke?
            var thin: ThinStrokeRecipe?
            if next < replaced.count, replaced[next].range == whole {
                // 差し替えた頂点 (引いて積んだ・細さを補って組み直した) は、色と太さが確定している。
                // 外側の記録へは、この頂点の区間として渡す
                let count = replaced[next].vertices.count
                let start = lower - run.start + base + shift
                placed = start..<(start + count)
                shift += count - whole.count
                next += 1
                // **細さは外側を置くまで決まらないので、組み直す素材は持ち越す** (#1637)。半透明の
                // 色で引いて積んだ頂点に差し替えた輪郭も、外側を縮めて置けば細くなる
                // (記録の中で差し替わるのは、引いて積んだ頂点だけ。外側の記録の頂点は引いてある)
                if recordingShape, let source = shape.strokeRanges[index].thin {
                    thin = source.moved(by: matrix, tint: tint, carvedNow: true)
                }
            } else {
                placed = (lower - run.start + base + shift)..<(upper - run.start + base + shift)
                // 外側の記録へは、引く素材・組み直す素材も移して渡す (使うのは外側を置くとき)。
                // **その場で描くときは要らない** — 置く数だけ素材の箱を作ることになる。区間の一部
                // だけを置くときは、素材も一部になってしまうので持ち越さない
                // (`Optional.map` に閉包を渡さず `if let` で受ける — 隔離の実行時検査を払う・#1779)
                if recordingShape, lower == whole.lowerBound, upper == whole.upperBound {
                    if let source = shape.strokeRanges[index].carved {
                        carved = CarvedStroke(moving: source, by: matrix, tint: tint)
                    }
                    if let source = shape.strokeRanges[index].thin {
                        thin = source.moved(by: matrix, tint: tint, carvedNow: false)
                    }
                }
            }
            if recordingShape {
                recordedStrokeRanges.append(StrokeRange(placed, carved: carved, thin: thin))
                continue
            }
            vertices.withUnsafeMutableBufferPointer { buffer in
                for index in placed { buffer[index].position += 0.5 }
            }
        }
        // 記録の中で置き直すときは、楕円・弧の塗りを刻み直す素材も外側の記録へ渡す (使うのは外側を
        // 置くとき・#1645)。**その場で置くときは要らない。** 塗りは半画素寄せないので、区間の
        // 番号だけを求める
        if recordingShape, !shape.fillRanges.isEmpty {
            var fillShift = 0
            var fillNext = 0
            for fill in shape.fillRanges {
                let whole = fill.range
                guard whole.lowerBound >= runRange.lowerBound,
                    whole.upperBound <= runRange.upperBound
                else { continue }
                while fillNext < replaced.count,
                    replaced[fillNext].range.upperBound <= whole.lowerBound
                {
                    fillShift += replaced[fillNext].vertices.count - replaced[fillNext].range.count
                    fillNext += 1
                }
                let start = whole.lowerBound - run.start + base + fillShift
                recordedFillRanges.append(
                    RingFillRange(
                        start..<(start + whole.count),
                        recipe: fill.recipe.moved(by: matrix, tint: tint)))
            }
        }
    }

    /// 平面の区間 `runRange` で、記録した頂点の代わりに積む輪郭 (頂点の並びの順)。
    ///
    /// - 置いた後に描く画素で 1 画素より細くなる輪郭は、広げて組み直した頂点 (#1637・
    ///   ``Canvas/thinVertices(_:placedBy:cache:stroke:)``)。**記録の中で置き直すときは判断しない** —
    ///   外側を置くまで行列が決まらないので、素材を外側の記録へ渡す
    /// - そうでなく、置いた後の拡大で円板や周の分割数が記録のときより増える輪郭は、刻み直して
    ///   頂点 (#1645・``Canvas/rescaledVertices(_:placedBy:translucent:cache:stroke:)``)。**積み方は
    ///   記録のときに合わせる** — 不透明の線は重ねたまま積み、半透明の色を掛けて置くときだけ引く。
    ///   楕円・弧の塗りも、刻み直した頂点で差し替える
    ///   (``Canvas/rescaledFillVertices(_:placedBy:cache:fill:)``)。
    ///   **拡大して置くときだけ調べる**。縮めて置くときも、記録の中で置き直すときも調べない
    /// - そうでなく `carved` に含まれる輪郭は、引いて積んだ頂点 (半透明の色を掛けて置くとき)
    ///
    /// 区間を跨ぐ輪郭は差し替えない (素材は輪郭ひとつぶんなので、一部だけは置けない)。
    private func replacements(
        in runRange: Range<Int>, of shape: Shape, placedBy matrix: simd_float4x4,
        translucent: Bool, carved: [StrokeRange]
    ) -> [(range: Range<Int>, vertices: [ShapeVertex], coverage: [CoverageSpan])] {
        // 形の中で最も細い輪郭でも細くならなければ、走査しない (いちばんよくある置き方)。
        // 2 つの行列の最小の特異値の積は、積の行列の最小の特異値を越えない
        let mayThin =
            !recordingShape
            && Self.thinnestDrawnWeight(shape.thinnestRecordedWeight, by: drawnLinear(matrix)) < 1
        // 拡大して置くときだけ、周と円板の刻みが記録のときより増えうる。**拡大率が 1 を越えなければ、
        // どの輪郭も増えない** (分割数は半径の単調な関数で、行列の積の最大の特異値は特異値の積を
        // 越えない)。形が周も円板も持たなければ、それも走査しない (#1645)
        let mayRescale = !recordingShape && shape.mayRescale && Self.splitScale(of: matrix) > 1
        guard mayThin || mayRescale || !carved.isEmpty else { return [] }
        var found: [(range: Range<Int>, vertices: [ShapeVertex], coverage: [CoverageSpan])] = []
        var carvedIndex = 0
        for index in shape.strokeRanges.indices {
            let stroke = shape.strokeRanges[index]
            guard !stroke.range.isEmpty, stroke.range.lowerBound >= runRange.lowerBound,
                stroke.range.upperBound <= runRange.upperBound
            else { continue }
            while carvedIndex < carved.count,
                carved[carvedIndex].range.lowerBound < stroke.range.lowerBound
            {
                carvedIndex += 1
            }
            if mayThin, let recipe = stroke.thin,
                let rebuilt = thinVertices(
                    recipe, placedBy: matrix, cache: shape.thinCache, stroke: index)
            {
                found.append((stroke.range, rebuilt.vertices, rebuilt.coverage))
            } else if mayRescale, let recipe = stroke.thin,
                let rebuilt = rescaledVertices(
                    recipe, placedBy: matrix, translucent: translucent, cache: shape.thinCache,
                    stroke: index)
            {
                found.append((stroke.range, rebuilt, []))
            } else if carvedIndex < carved.count, carved[carvedIndex].range == stroke.range {
                found.append((stroke.range, carved[carvedIndex].carved?.vertices ?? [], []))
            }
        }
        if mayRescale {
            let before = found.count
            for index in shape.fillRanges.indices {
                let fill = shape.fillRanges[index]
                guard !fill.range.isEmpty, fill.range.lowerBound >= runRange.lowerBound,
                    fill.range.upperBound <= runRange.upperBound,
                    let rebuilt = rescaledFillVertices(
                        fill.recipe, placedBy: matrix, cache: shape.thinCache, fill: index)
                else { continue }
                found.append((fill.range, rebuilt, []))
            }
            // 塗りは輪郭より先に積まれる。頂点の並びの順に直す
            if found.count > before {
                found.sort { $0.range.lowerBound < $1.range.lowerBound }
            }
        }
        return found
    }

    /// 頂点を置き場所へ移す。行列を掛け、置き場所の色を掛ける。
    @inline(__always)
    private static func move(_ vertex: inout ShapeVertex, by matrix: simd_float4x4, tint: LinearRGBA?) {
        let point = SIMD4<Float>(vertex.position.x, vertex.position.y, 0, 1)
        let moved = matrix * point
        vertex.position = SIMD2<Float>(moved.x, moved.y)
        // 置き場所の色は**掛かる**。渡さなければ何も掛からない
        if let tint {
            let color = vertex.color
            vertex.color = SIMD4<Float>(
                color.x * tint.red, color.y * tint.green, color.z * tint.blue, color.w * tint.alpha)
        }
    }

    /// 引いて積んだ頂点を、区間の頂点と同じように置き場所へ移した写し。
    static func moved(
        _ vertices: [ShapeVertex], by matrix: simd_float4x4, tint: LinearRGBA?
    ) -> [ShapeVertex] {
        var vertices = vertices
        for index in vertices.indices { move(&vertices[index], by: matrix, tint: tint) }
        return vertices
    }

    /// 基本図形の区間を置く。**開いている平面・立体の列は閉じる** (呼び出し順どおりに重ねる)。
    ///
    /// 記録した置き場所は形自身の座標なので、いまの変換と置き場所の変換を合成して
    /// 掛ける。頂点を 1 つも触らないので、**円を含む形も、頂点を並べた形と同じ速さで置ける**。
    private func placeForms(_ run: Shape.Run, of shape: Shape, at placement: Placement) {
        let matrix = transform.matrix * placement.transform.matrix
        for form in shape.forms[run.start..<(run.start + run.count)] {
            let moved = form.placed(by: matrix, tint: placement.fill)
            // 潰れた変換で置いた形は面積を持たない (直に描いたときと同じく何も出ない)
            guard moved.isPlaceable else { continue }
            // 細い塗りは**置いた後の変換で**判定する — 記録したときの大きさが同じでも、
            // 縮めて置けば細くなる
            beginForm(
                flags: moved.meta.w,
                thinFill: moved.mayHaveThinFill(unitsPerDrawnPixel: unitsPerDrawnPixel))
            formInstances.append(moved)
        }
    }

    /// 立体の区間を置く。
    ///
    /// 位置と一緒に**面の向きも移す** — 移さないと、回して置いた形だけ光が付いて
    /// 回らない。位置と違って向きには軸ごとの倍率が逆に効くので、専用の行列を使う。
    private func placeSolid(_ run: Shape.Run, of shape: Shape, at placements: [Placement]) {
        // 閉包を標準ライブラリの高階関数へ渡さずにループで組む。main actor の文脈の閉包は
        // 要素ごとに隔離の実行時検査を払う (#1779)
        var instances: [SolidInstance] = []
        instances.reserveCapacity(placements.count)
        for placement in placements {
            let combined = Transform(matrix: transform.matrix * placement.transform.matrix)
            instances.append(
                SolidInstance(
                    matrix: combined.matrix, normalMatrix: combined.normalMatrix,
                    // 記録した頂点が色を持つので、置き場所は**白** (掛けても
                    // 変わらない)。渡された色があればそれを掛ける
                    color: placement.fill
                        ?? LinearRGBA(premultipliedRed: 1, green: 1, blue: 1, alpha: 1)))
        }
        // 記録した形 1 つずつの部品 (``SolidPart``) を持ち歩く。どの部品を裏 → 表で描くかは、
        // 記録したときのスタイルと置き場所の色で決まる (``Shape/solidParts``)
        placeSolid(run, of: shape, instances: instances, carriesParts: true)
    }

    /// 立体の区間を、組み上がった置き場所ぶんだけ置く。
    ///
    /// **置き場所から行列を組むのは呼ぶ側**で、ここは列へ積むだけを持つ。粒の参照の経路は
    /// 板を視点へ向けた行列を自分で組むので、``Placement`` を通らずにここへ来る。
    ///
    /// **組み立ての中で置き直すときは、置き場所ごとに頂点へ焼く** ([#1297])。記録は置き場所を
    /// 持ち歩かないので、置き場所を並べたままだと、中で書いた変換が外側の記録から落ちる
    /// (組み込みの形の ``placeMesh(_:isDerived:mesh:)`` と同じ理由)。
    ///
    /// **立体の線を持つ区間も、置き場所ごとに頂点へ焼く** ([#1547])。線の帯は視点に
    /// 合わせて組むので、置き場所の行列を掛けただけでは向き・幅・目の側への寄せが記録した
    /// ときのまま残る。焼いた後で、線の頂点の位置だけを置いた後の点で組み直す
    /// (``appendPlacedSolidVertices(_:indices:strokes:placedBy:parts:)``)。線を持たない区間は並べたまま置く。
    ///
    /// [#1297]: https://github.com/mokume-metal/mokume/issues/1297
    /// [#1547]: https://github.com/mokume-metal/mokume/issues/1547
    ///
    /// `carriesParts` が真なら、記録した形 1 つずつの部品 (``Shape/solidParts``) を列へ渡す。
    /// 裏面が絵に出うる部品は、置き場所ごとに裏 → 表の順で描かれる (``Batch/backFaceParts``)。
    /// **粒は渡さない** — 板 1 枚で自分の面が自分を隠すことが無く、描き分けると描く回数が粒の
    /// 数だけ増える。
    func placeSolid(
        _ run: Shape.Run, of shape: Shape, instances: some Collection<SolidInstance>,
        carriesParts: Bool = false
    ) {
        beginSolids()
        let parts = carriesParts ? shape.solidParts(in: run) : []
        let runRange = run.start..<(run.start + run.count)
        var pieces: [SolidStrokePiece] = []
        for piece in shape.solidStrokes where runRange.contains(piece.vertexStart) {
            pieces.append(piece)
        }
        if recordingShape || !pieces.isEmpty {
            let vertices = shape.solidVertices[runRange]
            let indices: ArraySlice<UInt32>? =
                run.isIndexed
                ? shape.solidIndices[run.indexStart..<(run.indexStart + run.indexCount)] : nil
            let gpuStrokes = retainedGPUStrokes(in: run, of: shape)
            if !gpuStrokes.isEmpty {
                for instance in instances {
                    placeSplittingGPUStrokes(
                        run, of: shape, pieces: pieces, gpuStrokes: gpuStrokes, parts: parts,
                        by: instance)
                }
                return
            }
            for instance in instances {
                appendPlacedSolidVertices(
                    vertices, indices: indices, strokes: pieces, placedBy: instance, parts: parts)
            }
            return
        }
        var remaining = instances[...]
        while let first = remaining.first {
            // **頂点は列ごとに 1 度だけ置く。** 上限に達したら列を閉じて置き直す —
            // 描く回数が増えるだけで、絵は 1 ビットも変わらない
            //
            // **鏡映の符号が変わったときも開き直す** ([#1446])。表の巻き方は列ごとに 1 つ
            // (``Canvas/Batch/frontFacing``) なので、鏡映した置き場所と鏡映していない置き場所は
            // 同じ列に並べられない
            //
            // [#1446]: https://github.com/mokume-metal/mokume/issues/1446
            let mirrored = first.isMirrored
            let start = openRetainedSolid(run, of: shape, mirrored: mirrored)
            // 部品を列の描く単位へ写す。頂点も添字も、形の中の位置から写した先までずらすだけ。
            // 置き場所の色で立つ部品は、置き場所の印 (``OpenSolid/backFaceInstances``) で表す —
            // 部品に印を付けると、同じ列の不透明の置き場所まで 2 回で描く
            if let open = openSolid, !parts.isEmpty {
                let shift = run.isIndexed
                    ? (open.indexStart ?? 0) - run.indexStart : open.vertexStart - run.start
                var moved: [SolidPart] = []
                moved.reserveCapacity(parts.count)
                for part in parts { moved.append(part.shifted(by: shift)) }
                openSolid?.parts = moved
            }
            while let instance = remaining.first, instance.isMirrored == mirrored,
                !isBatchFull(solidInstances.count, since: start)
            {
                solidInstances.append(instance)
                if !parts.isEmpty, placementShowsBackFaces(instance, styled: false) {
                    openSolid?.backFaceInstances.append(solidInstances.count - 1 - start)
                }
                remaining = remaining.dropFirst()
            }
        }
    }

    /// 区間の中で、置くときに GPU で組める線 (``Shape/gpuStrokes``・#1756)。組めない区間なら空。
    ///
    /// **記録の中で置き直すときは使わない** — 外側の記録は頂点と線の元で持ち歩く (入れ子)。
    /// 添字を持つ区間・通常以外の混ぜ方の区間も、CPU の帯のまま置く。
    private func retainedGPUStrokes(in run: Shape.Run, of shape: Shape) -> [RetainedGPUStroke] {
        guard placesRetainedStrokesOnGPU, !recordingShape, !run.isIndexed, run.mode == .blend,
            !shape.gpuStrokes.isEmpty
        else { return [] }
        let runRange = run.start..<(run.start + run.count)
        var strokes: [RetainedGPUStroke] = []
        for stroke in shape.gpuStrokes
        where runRange.contains(stroke.vertices.lowerBound)
            && stroke.vertices.upperBound <= runRange.upperBound
        {
            strokes.append(stroke)
        }
        return strokes
    }

    /// 保持した形の区間を 1 か所に置く。**GPU で組める線はその区間を積まずに GPU の列で描き、
    /// 残りは焼いて積む** (#1756)。
    ///
    /// 区間は記録した順に割るので、塗り → 線 → 次の形の塗り … の重ね順は CPU で置いたときと
    /// 同じである (全部の塗り → 全部の線へ並べ替えない)。置き場所の色で線が透ける・骨が
    /// 作れない線は割らずに、焼いた帯のまま置く。
    private func placeSplittingGPUStrokes(
        _ run: Shape.Run, of shape: Shape, pieces: [SolidStrokePiece],
        gpuStrokes: [RetainedGPUStroke], parts: [SolidPart], by instance: SolidInstance
    ) {
        func placeBaked(_ segment: Range<Int>) {
            guard !segment.isEmpty else { return }
            var inside: [SolidStrokePiece] = []
            for piece in pieces where segment.contains(piece.vertexStart) { inside.append(piece) }
            // 区間に収まる部品だけを渡す (線で割った区間を跨ぐ部品は無い — 部品は塗りの区間で、
            // 線はその後ろに積まれる)
            appendPlacedSolidVertices(
                shape.solidVertices[segment], indices: nil, strokes: inside, placedBy: instance,
                parts: parts)
        }
        var cursor = run.start
        for stroke in gpuStrokes {
            // 置き場所の色は線にも掛かる (焼いた頂点に掛かるのと同じ式)。透けたら GPU の
            // 条件 (不透明) から外れるので、焼いた帯のまま置く
            let color = SIMD4(stroke.color.red, stroke.color.green, stroke.color.blue, stroke.color.alpha)
                * instance.color
            guard color.w == 1, case .mesh(let solid) = stroke.source,
                let (geometry, geometryScale) = gpuStrokeGeometry(
                    of: stroke.source, mesh: { solid.make() })
            else { continue }
            placeBaked(cursor..<stroke.vertices.lowerBound)
            openGPUStroke(
                of: stroke.source, geometry: geometry, matrix: instance.matrix * stroke.matrix,
                weight: stroke.weight, cap: stroke.cap,
                color: LinearRGBA(
                    premultipliedRed: color.x, green: color.y, blue: color.z, alpha: color.w),
                uv: stroke.uv, geometryScale: geometryScale)
            cursor = stroke.vertices.upperBound
        }
        placeBaked(cursor..<(run.start + run.count))
    }

    /// 保持した形の区間を置き場所で焼いて積み、**区間の中の立体の線は、置いた後の点で組み直して
    /// 差し込む** ([#1547]・[#1893])。
    ///
    /// 線は記録した区間を丸ごと、組み直した頂点に差し替える (``SolidStrokePiece``)。組み直すのは
    /// その場の線と同じ手順で、頂点の数は記録と違ってよい。差し込むのは記録した区間のあった所
    /// なので、塗りとの重ね順は変わらない。添字の列では、線の頂点は自分の番号を名乗って並んで
    /// いる (`appendSolidVertex`) ので、その並びを組み直した頂点の番号の並びに差し替え、後ろの
    /// 頂点を指す番号はずれのぶんだけ送る。線の頂点は置き場所の色と白い区画を、記録した区間の
    /// 先頭の頂点から受け継ぐ (線 1 本は 1 色で積まれる)。
    ///
    /// 鏡映する置き場所では、添字を持たない区間の三角形を 1 枚ずつ裏返す (焼いた頂点と同じ)。
    ///
    /// **組み立ての中では組み直さず、焼いた頂点のまま線を外側の記録へ渡す。** 置き場所が決まる
    /// のは外側の形を置くときなので、そこで組み直す (``createShape(_:)``)。
    ///
    /// - Parameter strokes: 区間の中の線。`vertexStart` は `vertices` の番号 (形の頂点の並びの番号)
    ///
    /// [#1547]: https://github.com/mokume-metal/mokume/issues/1547
    /// [#1893]: https://github.com/mokume-metal/mokume/issues/1893
    private func appendPlacedSolidVertices(
        _ vertices: ArraySlice<SolidVertex>, indices: ArraySlice<UInt32>?, strokes: [SolidStrokePiece],
        placedBy instance: SolidInstance, parts: [SolidPart]
    ) {
        if recordingShape || strokes.isEmpty {
            let base = solidVertices.count
            appendPlacedSolidVertices(vertices, indices: indices, placedBy: instance, parts: parts)
            guard recordingShape else { return }
            for piece in strokes {
                var moved = piece.moved(by: instance.matrix)
                moved.vertexStart = base + (piece.vertexStart - vertices.startIndex)
                if instance.isMirrored && indices == nil { moved.isReversed.toggle() }
                recordedSolidStrokes.append(moved)
            }
            return
        }
        let lower = vertices.startIndex
        // 差し込んだ後の頂点の並び (置き場所を掛けたもの)。記録した番号 → 並びの位置。線の区間は、
        // 先頭だけが組み直した頂点の区間の先頭を指し、残りは -1
        var placed: [SolidVertex] = []
        placed.reserveCapacity(vertices.count)
        var numbers = [Int](repeating: -1, count: vertices.count)
        var blocks: [(recorded: Range<Int>, placed: Range<Int>)] = []
        var cursor = lower
        func appendBaked(upTo end: Int) {
            while cursor < end {
                numbers[cursor - lower] = placed.count
                placed.append(instance.placing(vertices[cursor]))
                cursor += 1
            }
        }
        // 被覆が 1 未満の線があるか。**印は列を開いた後に立てる** — 先に立てると、頂点を積む
        // ときに開き直す列 (`openFreeformSolid` が閉じる前の列) へ印が渡って下ろされる (#1637)
        var thin = false
        for piece in strokes.sorted(by: { $0.vertexStart < $1.vertexStart }) {
            appendBaked(upTo: piece.vertexStart)
            var prototype = instance.placing(vertices[piece.vertexStart])
            let (corners, coverage) = rebuiltSolidStroke(piece.moved(by: instance.matrix))
            // 被覆も置く面で決まる (#1637)。線の頂点なので 0 にはならない
            prototype.stroke = coverage
            if coverage < 1 { thin = true }
            let start = placed.count
            for corner in corners {
                var vertex = prototype
                vertex.position = corner.position
                vertex.shapePosition = corner.shape
                placed.append(vertex)
            }
            numbers[piece.vertexStart - lower] = start
            blocks.append((piece.vertexStart..<(piece.vertexStart + piece.vertexCount), start..<placed.count))
            cursor = piece.vertexStart + piece.vertexCount
        }
        appendBaked(upTo: vertices.endIndex)

        // 読む順も差し替える。線の頂点は自分の番号を順に名乗っているので、先頭で組み直した頂点の
        // 番号を並べ、残りは捨てる。記録した読む順の位置 → 差し替えた位置も控える (部品を写すため)
        var order: [UInt32]?
        var positions: [Int] = []
        if let indices {
            var heads: [Int: Int] = [:]
            for (offset, block) in blocks.enumerated() { heads[block.recorded.lowerBound] = offset }
            var built: [UInt32] = []
            built.reserveCapacity(indices.count)
            positions.reserveCapacity(indices.count)
            for index in indices {
                positions.append(built.count)
                let number = Int(index)
                if let block = heads[number] {
                    for placedIndex in blocks[block].placed { built.append(UInt32(placedIndex)) }
                } else if numbers[number - lower] >= 0 {
                    built.append(UInt32(numbers[number - lower]))
                }
            }
            order = built
        }
        // 塗りの部品を差し込んだ後の位置へ写す (部品は塗りの区間で、線の区間を跨がない)
        var movedParts: [SolidPart] = []
        for part in parts {
            if indices != nil {
                guard part.isIndexed, let indices, indices.indices.contains(part.range.lowerBound),
                    part.range.upperBound <= indices.endIndex
                else { continue }
                let start = positions[part.range.lowerBound - indices.startIndex]
                movedParts.append(SolidPart(
                    range: start..<(start + part.range.count), isIndexed: true,
                    showsBackFaces: part.showsBackFaces, insideOut: part.insideOut))
            } else {
                guard !part.isIndexed, vertices.indices.contains(part.range.lowerBound),
                    part.range.upperBound <= vertices.endIndex, numbers[part.range.lowerBound - lower] >= 0
                else { continue }
                let start = numbers[part.range.lowerBound - lower]
                movedParts.append(SolidPart(
                    range: start..<(start + part.range.count), isIndexed: false,
                    showsBackFaces: part.showsBackFaces, insideOut: part.insideOut))
            }
        }
        appendPlacedSolidVertices(
            placed[...], indices: order?[...], placedBy: .identity, parts: movedParts,
            showsBackFaces: placementShowsBackFaces(instance, styled: false),
            mirrored: instance.isMirrored)
        if thin { openBatchHasThinCoverage = true }
    }

    /// 保持した形の頂点を積んで、置き場所を入れる列を開く。返すのはその列の先頭。
    ///
    /// **先頭を返すのは、上限に達したかを同じ形で数えるため** (``Canvas/isBatchFull(_:since:)``)。
    /// `openSolid` から読み直すと、開いた直後に強制開示が要る。`mirrored` はこの列に入れる
    /// 置き場所の鏡映の符号 (``Canvas/OpenSolid/isMirrored``)。
    ///
    /// `external` を渡すと、置き場所を溜め場ではなく外の置き場から取る列になる
    /// (``Canvas/OpenSolid/external``)。粒の速い経路だけが使う。**頂点の積み直しは同じ手順を
    /// 通す** — 粒の側に写して持つと、ここに段を足した日に粒だけが落とす ([#1649] の反証)。
    ///
    /// [#1649]: https://github.com/mokume-metal/mokume/issues/1649
    @discardableResult
    func openRetainedSolid(
        _ run: Shape.Run, of shape: Shape, mirrored: Bool, external: ExternalInstances? = nil
    ) -> Int {
        closeBatch()
        let start = solidVertices.count
        solidVertices.append(
            contentsOf: shape.solidVertices[run.start..<(run.start + run.count)])
        // **読む順も一緒に積み直す。** 積まずに開くと、添字を持つ形が置いた瞬間に
        // 非添字の経路へ落ち、頂点を 3 つずつ束ねただけの並びとして描かれる。
        // 値は形自身の 0 起点なので、写した先までのずれを足す
        let indexStart = run.isIndexed ? solidIndices.count : nil
        if run.isIndexed {
            // ずれは負にもなる (形の中での位置より、溜め場の末尾が手前のことがある)
            let shift = start - run.start
            solidIndices.reserveCapacity(solidIndices.count + run.indexCount)
            for index in shape.solidIndices[run.indexStart..<(run.indexStart + run.indexCount)] {
                solidIndices.append(UInt32(Int(index) + shift))
            }
        }
        retainedSerial += 1
        let instanceStart = solidInstances.count
        // **外の置き場から置き場所を取る列は添字を持てない** (`closeSolidBatch`)。粒の板は
        // 添字を持たない四角なので当たらないが、黙って非添字へ倒さず、ここで止める
        assert(external == nil || !run.isIndexed, "an indexed run cannot read external instances")
        openSolid = OpenSolid(
            source: .retained(serial: retainedSerial), vertexStart: start,
            vertexCount: run.count, indexStart: indexStart, instanceStart: instanceStart,
            external: external, isMirrored: mirrored)
        return instanceStart
    }

    /// 置けない置き場所を、初回だけ知らせる。**原因を名指す** — 位置・倍率・回転か、塗り
    /// (`Placement.fill`) か ([#1706] の反証 7)。鍵は 1 つで、初めに言った文面が残る。
    ///
    /// [#1706]: https://github.com/mokume-metal/mokume/issues/1706
    private func warnBadPlacement(geometry: Bool, fill: Bool) {
        let parts = [
            geometry ? "position, scale or rotation" : nil, fill ? "fill" : nil,
        ].compactMap { $0 }.joined(separator: " or ")
        warnOnce(
            .badPlacement,
            "shape(at:): some placements held a value that is not a number, or an infinite one, "
                + "in their \(parts), so those were not placed")
    }
}

extension Canvas.Style {
    /// 描き方のフィールドはこの値のまま、**フレームに属するフィールド (切り抜き・材質・影の
    /// 落とし方と受け方) は `current` のもの**にした値 ([#1684])。
    ///
    /// 形の組み立ての出口 (``Canvas/Manner``) が使う。どのフィールドがフレームに属するかは
    /// ADR-0021 決定 4 の表で、検査の表 (`CanvasTests` の `frameStyle`・`ShapeExitTests` の
    /// 「断る」) が同じ 4 つを持つ。`Style` にフィールドを足すと、`ShapeExitTests` がどちらかに
    /// 分けるまで赤になり、「断る」に分けたものがここで書き戻されると赤になる。
    ///
    /// [#1684]: https://github.com/mokume-metal/mokume/issues/1684
    func keepingFrameFields(of current: Self) -> Self {
        var style = self
        style.clip = current.clip
        style.material = current.material
        style.castsShadow = current.castsShadow
        style.receivesShadow = current.receivesShadow
        return style
    }
}
