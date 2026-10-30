// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

extension CanvasTests {
    /// スタイルの一式と、`Canvas` の格納の台帳 (`everyStoredPropertyIsClassified` と表)・境目で戻す
    /// 状態・形の組み立ての出入口。台帳は複数の検査から読む表なので、1 つの型に置く。
    @Suite(
        "フレームの境目で戻す状態と格納の台帳",
        .enabled(
            if: RenderDevice.isAvailable,
            "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
    )
    struct FrameState {
        private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)

        private func makeCanvas(width: Int = 64, height: Int = 64) throws -> Canvas {
            try CanvasFixture.make(gpu: RenderDevice(), width: width, height: height)
        }

        // MARK: - スタイルの一式 (#780)

        /// 全フィールドが既定と違うスタイル。**`Canvas.Style` にフィールドを足したらここにも
        /// 足す** — 足し忘れると `styleRoundTripsEveryField` が、既定のままのフィールドを
        /// 名乗って赤になる (既定のままでは往復したかどうかを見分けられない)。
        private func distinctStyle(on canvas: Canvas) -> Canvas.Style {
            var style = Canvas.Style()
            style.fill = .linear(red: 0.1, green: 0.2, blue: 0.3)
            style.stroke = .linear(red: 0.4, green: 0.5, blue: 0.6)
            style.strokeWeight = 3
            style.strokeCap = .square
            style.strokeJoin = .bevel
            style.strokeDash = StrokeDash(length: 4, gap: 2)
            style.hasFill = false
            style.hasStroke = false
            style.rectMode = .center
            style.ellipseMode = .corner
            style.blendMode = .add
            style.clip = Canvas.ClipRect(left: 1, top: 2, right: 4, bottom: 6)
            style.fontName = "Helvetica"
            style.textSize = 30
            style.textStyle = .bold
            style.horizontalTextAlign = .right
            style.verticalTextAlign = .top
            style.textLeading = 40
            style.textWrap = .character
            style.imageMode = .center
            style.tint = .linear(red: 0.7, green: 0.8, blue: 0.9)
            style.picture = canvas.drawnPicture
        style.gradient = ResolvedGradient.resolve(
            .linearGradient([(.linear(red: 1, green: 0, blue: 0), 0), (.linear(red: 0, green: 0, blue: 1), 1)], from: [0, 0], to: [10, 0]),
            under: .identity
        ).gradient
            style.material.shininess = 8
            style.castsShadow = false
            style.receivesShadow = false
            return style
        }

        /// フィールドごとの名前と値の綴り。**並びを `Mirror` から取る**ので、ここは宣言に
        /// フィールドが増えても書き足さなくてよい。
        private func fields(of style: Canvas.Style) -> [(name: String, value: String)] {
            Mirror(reflecting: style).children.map {
                (name: $0.label ?? "?", value: String(describing: $0.value))
            }
        }

        @Test("積み降ろしも形の組み立ても、スタイルの全フィールドを往復させる")
        func styleRoundTripsEveryField() throws {
            // 以前はフィールドの並びが宣言・写し取り・戻しの 3 か所にあり、1 か所落としても
            // 型も検査も通った ([#780])。落としたフィールドは「その設定だけ戻らない」形で
            // 絵がそれらしく壊れるので、全フィールドを並べて見る
            let canvas = try makeCanvas()
            let distinct = distinctStyle(on: canvas)
            let expected = fields(of: distinct)
            for (plain, marked) in zip(fields(of: Canvas.Style()), expected) {
                #expect(
                    plain.value != marked.value,
                    "\(marked.name) が既定のままなので、往復したかを見分けられない (distinctStyle に足す)")
            }

            func expectRestored(_ path: String) {
                for (actual, wanted) in zip(fields(of: canvas.currentStyle), expected) {
                    #expect(actual.value == wanted.value, "\(path) で \(wanted.name) が戻らない")
                }
            }
            try canvas.draw {
                canvas.currentStyle = distinct
                canvas.pushStyle()
                canvas.currentStyle = Canvas.Style()
                canvas.popStyle()
                expectRestored("pushStyle / popStyle")

                // 組み立ては積み降ろしを使わず、写し取って戻す (`Canvas.createShape`)。**フレームに
                // 属するフィールド (切り抜き・材質・影) は組み立ての中では断り、出口も戻さない** (#1529・
                // #1684 — 戻すと、組み立ての中で閉じたフレームの値を書き戻す)。中で書き換えるのは描き方
                // だけにし、全フィールドが組み立て前のままであることを見る
                _ = canvas.createShape {
                    canvas.currentStyle = Canvas.Style().keepingFrameFields(of: canvas.style)
                }
                expectRestored("createShape")
            }
        }

        /// 持ち越しを約束する区間 (本体の `setup()` と止まっている間のコールバック) を模して
        /// `body` を走らせる ([#1672])。区間の印を立てるのは、製品ではランタイムだけである。
        ///
        /// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
        private func carryingOver(_ canvas: Canvas, _ body: () -> Void) {
            canvas.carriesOver = true
            defer { canvas.carriesOver = false }
            body()
        }

        // MARK: - フレームの境目で戻す状態 (#1671)

        /// フレームの境目の越え方。**境目の関数はどれを通っても、同じ状態を戻す。**
        enum FrameBoundary: CaseIterable, CustomTestStringConvertible {
            /// 描き切って閉じ、次を始める (`endDraw()` → `beginDraw()`)。
            case endDraw
            /// 閉じ忘れたまま次を始める (`beginDraw()` を重ねる・[#1622])。描き切らないので、
            /// 溜めたものを flush が片付けてくれない。
            case beginDrawAgain
            /// 描き切りに失敗して閉じる ([#342])。flush は溜めたものに触れずに投げる。
            case failedEndDraw
            /// 閉じ忘れたまま、次のフレームを `draw { }` で始める。捨てるのは入口ではなく
            /// フレームの始まりなので、こちらの入口でも同じに捨てる。
            case drawAfterBeginDraw
            /// 描き場所で閉じ忘れたまま、本体の次のフレームが始まる ([#1834])。本体の頭が描かずに
            /// 捨て、描き場所はフレームの外に出る。描き切らないので、溜めたものを flush が片付けて
            /// くれない。**汚す面は描き場所** (``usesLayer``)。
            ///
            /// [#1834]: https://github.com/mokume-metal/mokume/issues/1834
            case mainFrameAfterBeginDraw
            /// 本体の通常の経路 (`draw { }` → `draw { }`)。
            case drawThenDraw
            /// `setup()` にあたるフレームの外 (持ち越しの区間・``Canvas/carriesOver``) で汚し、最初の
            /// `draw { }` を始める。外で書けるものは限られる (シーンの記述は断られる) ので、見るのは
            /// 頭で戻すものだけ (``FrameReset``)。区間の外では形も開けない (#1672)。
            case outsideThenDraw
            /// ループ中 (と `redraw()` を頼んだ後) の入力のコールバックの出口 (#3408)。フレームの内側で汚し、
            /// フレームを閉じずに、同じフレームの中で出口を通る。**越えるのは境目ではなく、コールバックの出口**
            /// なので、見るのはシーンの記述の行だけである (``FrameReset/isSceneDescription``)。描き方と
            /// 溜めたものは、コールバックで書いた・置いたまま残る。
            case inputCallbackExit

            var testDescription: String { "\(self)" }

            /// 汚すのがフレームの外か。
            var dirtiesOutside: Bool { self == .outsideThenDraw }

            /// 汚す面が、本体 (`host`) から作った描き場所か。
            var usesLayer: Bool { self == .mainFrameAfterBeginDraw }

            /// 汚したフレームを閉じる越え方か。閉じた直後にも、終わりで戻すものを見る。本体の頭で
            /// 捨てた描き場所は、捨てた直後にフレームの外に居るので、閉じたものとして見る。
            var closes: Bool {
                [.endDraw, .failedEndDraw, .drawThenDraw, .mainFrameAfterBeginDraw].contains(self)
            }

            /// 汚すフレームを開いて `dirty` を走らせ、境目を越える。閉じる越え方なら閉じた直後に
            /// `closed` を、次のフレームの中で `inspect` を呼ぶ。`host` は ``usesLayer`` の越え方で、
            /// `canvas` を作った本体である。
            func run(
                _ canvas: Canvas, host: Canvas, dirty: () -> Void, closed: () -> Void,
                inspect: () -> Void
            ) throws {
                switch self {
                case .mainFrameAfterBeginDraw:
                    try host.draw {
                        canvas.beginDraw()
                        dirty()
                    }
                    try host.draw { closed() }
                    canvas.beginDraw()
                    inspect()
                    canvas.endDraw()
                case .endDraw, .failedEndDraw:
                    canvas.beginDraw()
                    dirty()
                    if self == .failedEndDraw { canvas.failureForTesting = .deviceUnavailable }
                    canvas.endDraw()
                    canvas.failureForTesting = nil
                    closed()
                    canvas.beginDraw()
                    inspect()
                    canvas.endDraw()
                case .beginDrawAgain:
                    canvas.beginDraw()
                    dirty()
                    canvas.beginDraw()
                    inspect()
                    canvas.endDraw()
                case .drawAfterBeginDraw:
                    canvas.beginDraw()
                    dirty()
                    try canvas.draw { inspect() }
                case .drawThenDraw:
                    try canvas.draw { dirty() }
                    closed()
                    try canvas.draw { inspect() }
                case .inputCallbackExit:
                    try canvas.draw {
                        dirty()
                        canvas.leaveInputCallbackInsideFrame()
                        inspect()
                    }
                case .outsideThenDraw:
                    canvas.carriesOver = true
                    dirty()
                    canvas.carriesOver = false
                    try canvas.draw { inspect() }
                }
            }
        }

        /// フレームに属する状態を、境目のどちらの側で戻すか。
        ///
        /// **終わりの側で戻すものは、閉じた直後にも見る。** 止まっている間のコールバックと
        /// 描き場所の `endDraw()` の後はフレームの外で、そこで置いた図形や読んだ座標に前の
        /// フレームのものが効かないようにする ([#1472]・[#1504])。頭の側だけで見ていると、
        /// 終わりの戻しを頭へ移しても緑のままになる。
        ///
        /// [#1472]: https://github.com/mokume-metal/mokume/issues/1472
        /// [#1504]: https://github.com/mokume-metal/mokume/issues/1504
        enum FrameReset {
            /// 頭でだけ戻す。閉じた直後は汚れたままでよい (次のフレームの前に読まれない)。
            case head
            /// 終わりで戻す。フレームの外で汚したもの (`setup()` で置いた図形) は、最初の
            /// フレームへ持ち越すのが約束なので、頭では戻さない。
            case end
            /// 頭と終わりの両方で戻す。
            case both
            /// `head` と同じ戻し方で、**シーンの記述** (`mokume.md` の「状態の寿命」の表の「シーンの記述」の行)
            /// である。ループ中の入力のコールバックの出口でも戻る (``FrameBoundary/inputCallbackExit``・#3408)。
            case sceneHead
            /// `end` と同じ戻し方の、シーンの記述。
            case sceneEnd
            /// `both` と同じ戻し方の、シーンの記述。
            case sceneBoth

            var atHead: Bool { self != .end && self != .sceneEnd }
            var atEnd: Bool { self != .head && self != .sceneHead }
            /// シーンの記述か。**フレームの内側で配る入力のコールバックの出口で戻す範囲は、この印の行** (#3408)。
            /// 描き方・溜めたもの (置いた図形・絵・背景) は含まない — コールバックで置いたものは残る。
            var isSceneDescription: Bool { [.sceneHead, .sceneEnd, .sceneBoth].contains(self) }
        }

        /// 境目を越えるときに開いている列。**列は同時に 1 本しか開かない**ので、開いたまま
        /// 越える列の種類を引数で回す (``frameState`` の `openIn`)。
        enum OpenBatch: CaseIterable, CustomTestStringConvertible {
            /// 貼る絵の矩形を 2 つ置いて畳み始めた、平面の雛形。
            case flatTemplate
            /// 基本図形の列。
            case form
            /// 立体の列。
            case solid

            var testDescription: String { "\(self)" }
        }

        /// 境目を越える前に、フレームを汚すのに使う道具。
        struct FrameFixture {
            let sheet: Image
            let other: Canvas
            let computation: Computation
            let numbers: Numbers
            let particles: Particles
            /// 開いたまま越える列。
            let openBatch: OpenBatch
            /// 貼る絵の矩形を 1 つ置いた直後の、畳む相手の控え (``Canvas/pendingFlat``)。
            var pendingFlat: Canvas.PendingFlat?
        }

        /// **フレームに属する状態と、それを汚す手順** ([ADR-0021] 決定 4 と追補・[#1671])。
        ///
        /// ここに載る状態は、どの境目を越えた後も (次の `beginFrame()` の後で見て) 既定へ
        /// 戻っていなければならない。**頭でしか戻さないもの** (`pendingEffects`・積み履歴・
        /// `passesThisFrame`・`hasLoadedPixels`・`lightStorage`) もあるので、見るのは次の
        /// フレームを始めた後である。
        ///
        /// 手順は上から順に通す。**塗り直し (`background`) と途中の描き切り (`loadPixels`) は
        /// 溜めたものを捨てるので先頭に置く。** 手順が本当に汚したかは検査が確かめる
        /// (既定のままの状態は、戻ったかどうかを見分けられない)。
        ///
        /// `openIn` はその状態が汚れる開いた列の種類。**開いている列は 1 本だけ**
        /// (``OpenBatch``) なので、列の組と、それに付いて動く状態だけが種類を持つ。
        ///
        /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
        /// [#1671]: https://github.com/mokume-metal/mokume/issues/1671
        private var frameState:
            [(
                name: String, reset: FrameReset, openIn: Set<OpenBatch>,
                dirty: (Canvas, inout FrameFixture) -> Void
            )]
        {
            let all = Set(OpenBatch.allCases)
            let head = FrameReset.head
            let end = FrameReset.end
            let both = FrameReset.both
            let sceneHead = FrameReset.sceneHead
            let sceneEnd = FrameReset.sceneEnd
            let sceneBoth = FrameReset.sceneBoth
            return [
                // 途中の描き切りと塗り直しは、溜めたものを捨てるので先に通す
                ("passesThisFrame", head, all, { c, _ in c.loadPixels() }),
                ("hasLoadedPixels", head, all, { c, _ in c.loadPixels() }),
                // 奥行きを残した描き切りが何かを描くと立つ。**フレームの頭では戻さない** — 止まっている間や
                // `setup()` で描き切った奥行きを、次のフレームの最初の描き切りが受け取る (#1888)
                ("depthIsHeld", end, all, { c, _ in
                    c.rect(10, 10, 4, 4)
                    c.loadPixels()
                }),
                // 描く先 (`target`) の中の、フレームに属する状態 (#1678)。書く口は溜めた図形があれば
                // 描き切るので、塗り直しと図形より先に書く。読み方は ``nestedFrameState``
                ("target.pixelMirror.hasPendingWrites", end, all, { c, _ in
                    c.set(1, 1, .linear(red: 1, green: 0, blue: 0))
                }),
                ("pendingBackground", end, all, { c, _ in c.background(.linear(red: 0, green: 0, blue: 0)) }),
                // 途中の描き切りが既に描いた落とす側 (#1656)。塗り直しも捨てるので、その後で汚す。
                // 描き切らせて汚すと、上の塗り直しの予定を描いてしまうので、中身を直に足す
                ("frameCasters", end, all, { c, _ in c.frameCasters.chainValid = false }),
                // シーンの記述
                ("cameraStorage", sceneEnd, all, { c, _ in c.perspective() }),
                ("drawsDebugGuides", sceneBoth, all, { c, _ in c.debugMode() }),
                ("transform", sceneBoth, all, { c, _ in c.translate(5, 5) }),
                ("transformStack", sceneHead, all, { c, _ in c.pushMatrix() }),
                ("styleStack", sceneHead, all, { c, _ in c.pushStyle() }),
                ("activeLights", sceneBoth, all, { c, _ in c.ambientLight(.linear(red: 0.2, green: 0.2, blue: 0.2)) }),
                ("activeSurroundings", sceneBoth, all, { c, _ in c.surroundings(.sky) }),
                ("shadowsEnabled", sceneEnd, all, { c, _ in c.shadows(true) }),
                ("shadowRangeValue", sceneEnd, all, { c, _ in c.shadowRange(50) }),
                ("shadowDetailValue", sceneEnd, all, { c, _ in c.shadowDetail(ShadowMap.detailRange.lowerBound) }),
                ("shadowBiasValue", sceneEnd, all, { c, _ in c.shadowBias(0.5) }),
                ("pendingEffects", sceneHead, all, { c, _ in c.effects([.invert()]) }),
                ("pendingComputations", end, all, { c, f in c.compute(f.computation, over: 1, writes: [f.numbers]) }),
                // 溜めたもの。立体は光を置いた後に置くので、列を閉じたときに光の置き場へ写る
                ("solidVertices", end, all, { c, _ in c.box(4) }),
                ("solidMeshRanges", end, all, { c, _ in c.box(4) }),
                ("solidInstances", end, all, { c, _ in c.box(4) }),
                ("lightStorage", head, all, { c, _ in c.box(4) }),
                ("solidIndices", end, all, { c, _ in
                    c.beginShape(.triangles)
                    c.vertex(0, 0, 1)
                    c.vertex(8, 0, 1)
                    c.vertex(0, 8, 1)
                    c.index(0)
                    c.index(1)
                    c.index(2)
                    c.endShape()
                }),
                // 貼る絵の矩形は、読む面を替えた 1 つ目が列を閉じるので、2 つ目が畳む相手を待つ
                ("vertices", end, all, { c, f in
                    c.texture(f.sheet)
                    c.noStroke()
                    c.rect(0, 0, 3, 3)
                    c.rect(4, 0, 3, 3)
                    f.pendingFlat = c.pendingFlat
                    c.noTexture()
                    c.stroke(.linear(red: 1, green: 1, blue: 1))
                }),
                ("flatInstances", end, all, { c, _ in c.flatInstances.append(.identity) }),
                ("thinFillRecords", end, all, { c, _ in
                    c.thinFillRecords.append(
                        .unitSquare(around: .zero, inverse: matrix_identity_float2x2, coverage: 0.5))
                }),
                ("thinFillSpans", end, all, { c, _ in
                    c.thinFillSpans.append(Canvas.ThinFillSpan(first: 0, count: 1))
                }),
                ("lastThinFillRecord", end, all, { c, _ in c.lastThinFillRecord = 0 }),
                ("coverageSpans", end, all, { c, _ in
                    c.coverageSpans.append(Canvas.CoverageSpan(range: 0..<3, value: 0.5))
                }),
                ("recordedStrokeRanges", end, all, { c, _ in c.recordedStrokeRanges.append(StrokeRange(0..<0)) }),
                ("recordedFillRanges", end, all, { c, _ in
                    c.recordedFillRanges.append(
                        RingFillRange(
                            0..<0,
                            recipe: RingFillRecipe(
                                outline: Canvas.Outline(points: [], isClosed: false),
                                color: .transparent, hasPicture: false, transform: .identity,
                                uv: .zero)))
                }),
                ("recordedGeometryForms", end, all, { c, _ in
                    c.recordedGeometryForms.append(
                        FormInstance(
                            kind: .arc, linear: SIMD4(1, 0, 0, 1), offset: .zero, half: SIMD2(4, 4),
                            arc: SIMD2(0, 1), halfWeight: 0, fill: .zero, stroke: .zero, fills: false,
                            strokes: false, cap: .round, join: .round))
                }),
                ("recordedSolidStrokes", end, all, { c, _ in
                    c.recordedSolidStrokes.append(
                        SolidStrokePiece(
                            source: .ring(points: [.zero], shapePoints: [.zero], isClosed: false, curveSteps: []),
                            weight: 1, join: .miter, cap: .round, vertexStart: 0, vertexCount: 0))
                }),
                ("recordedGPUStrokes", end, all, { c, _ in
                    c.recordedGPUStrokes.append(
                        RetainedGPUStroke(
                            source: .freeform, matrix: Transform.identity.matrix, weight: 1, cap: .round,
                            color: .transparent, uv: .zero, vertices: 0..<0))
                }),
                ("formInstances", end, all, { c, _ in c.rect(10, 10, 4, 4) }),
                ("batches", end, all, { c, _ in c.rect(10, 10, 4, 4) }),
                // 置いた描き場所を描き換えると、置いた時点の絵の写しを読む (#1656)。描き換えは置いた
                // 記録を落とすので、置いた記録より先に汚す
                ("placedPictureCopiesInUse", end, all, { c, _ in
                    let layer = try! c.createGraphics(4, 4)
                    c.image(layer, 0, 0)
                    layer.beginDraw()
                    layer.background(.linear(red: 1, green: 0, blue: 0))
                    layer.endDraw()
                }),
                ("placedGraphics", end, all, { c, f in c.note(placing: f.other) }),
                ("outlinesAssembledThisFrame", end, all, { c, _ in c.outlinesAssembledThisFrame = 7 }),
                ("pointScansThisFrame", end, all, { c, _ in c.pointScansThisFrame = 7 }),
                // 組み立て中の形 (#1591)。閉じずに境目を越える
                ("isBuildingShape", both, all, { c, _ in c.beginShape(.triangles) }),
                ("shapeKind", both, all, { _, _ in }),
                ("currentNormal", both, all, { c, _ in c.normal(0, 0, 1) }),
                ("shapePoints", both, all, { c, _ in c.vertex(0, 0, 1) }),
                ("shapeHasDepth", both, all, { _, _ in }),
                ("shapeIndices", both, all, { c, _ in c.index(0) }),
                ("shapeHoles", both, all, { c, _ in
                    c.beginContour()
                    c.vertex(1, 1)
                    c.vertex(2, 1)
                    c.vertex(1, 2)
                    c.beginContour()  // 1 つ目の穴を畳み、2 つ目を開いたままにする (#1528)
                }),
                ("holePoints", both, all, { c, _ in c.vertex(3, 3) }),
                ("curveGuides", both, all, { c, _ in
                    c.curveVertex(0, 0)
                    c.curveVertex(1, 1)
                }),
                // 開いたまま越える列 (1 本だけ)。**最後に開く** — 後から置いた図形が列を閉じる
                ("openSource", end, [.form, .solid], { c, f in Self.open(f.openBatch, on: c, f) }),
                ("openForm", end, [.form], { _, _ in }),
                ("openSolid", end, [.solid], { _, _ in }),
                ("openFlat", end, [.flatTemplate], { _, _ in }),
                ("currentTexture", end, [.flatTemplate], { _, _ in }),
                // 雛形を開く道は畳む相手を片付け、雛形の旗を立てて下ろすので、列を開いた後に
                // 汚す (列を閉じる道はどちらも読まない)
                ("pendingFlat", end, all, { c, f in c.pendingFlat = f.pendingFlat }),
                ("buildingFlatTemplate", end, all, { c, _ in c.buildingFlatTemplate = true }),
                // 捨てたフレームで積んだ力を落とすための控え (#1622)
                ("forcesThisFrame", end, all, { c, f in c.force(f.particles, [.gravity(0, 1)]) }),
                // 頼んだがまだ投入していない粒の進め。投入で粒へ数え、捨てたフレームでは落とす (#1710)
                // (`particles()` で汚すと、描く列を閉じて開いた列の種類が動くので、直に積む)
                ("particleAdvancesThisFrame", end, all, { c, f in
                    c.particleAdvancesThisFrame.append((Weak(f.particles), 1))
                }),
                // 持ち越しの区間で置いた量の印。フレームの頭の検めが読んで下ろす (#1672)
                ("carriedOverAmount", head, all, { c, _ in c.carriedOverAmount = 7 }),
            ]
        }

        /// 開いたまま越える列を開く。
        private static func open(_ batch: OpenBatch, on canvas: Canvas, _ fixture: FrameFixture) {
            switch batch {
            case .form:
                canvas.rect(20, 20, 4, 4)
            case .solid:
                canvas.box(4)
            case .flatTemplate:
                // 読む面を替えた 1 つ目は列を閉じ、2 つ目が畳む相手を待ち、3 つ目で雛形が開く
                canvas.texture(fixture.sheet)
                canvas.noStroke()
                canvas.rect(0, 0, 4, 4)
                canvas.rect(8, 0, 4, 4)
                canvas.rect(16, 0, 4, 4)
                canvas.noTexture()
            }
        }

        /// **格納の中に降りて読む、フレームに属する状態の読み方** ([#1678])。名前は `.` で繋いだ道で、
        /// ``frameState`` の同じ名前が汚す手順を持つ。
        ///
        /// 持ち越しに分けた格納 (`target` は面と同じだけ生きる) の中にも、フレームに属する状態がある。
        /// 表と綴りが `Canvas` の格納で止まっていると、そこへ足した状態は境目を黙って越える — 写しの
        /// 書き込み待ちは、そうして描かずに捨てたフレームを越えていた。中の格納の分け方は
        /// ``everyTargetStoredPropertyIsClassified()`` が見る。
        ///
        /// [#1678]: https://github.com/mokume-metal/mokume/issues/1678
        private var nestedFrameState: [String: (Canvas) -> String] {
            [
                // 写しがまだ無いのは、書き込み待ちが無いのと同じ
                "target.pixelMirror.hasPendingWrites": {
                    String(describing: $0.target.pixelMirror?.hasPendingWrites ?? false)
                }
            ]
        }

        /// 描く先 (``RenderTarget``) の格納のうち、持ち越すものと理由 ([#1678])。
        ///
        /// [#1678]: https://github.com/mokume-metal/mokume/issues/1678
        private var carriedTargetState: [String: String] {
            let construction = "面を作ったときに決まり、面と同じだけ生きる"
            let resource = "資源 (置き場・パイプライン)。頼まれてはじめて作り、使い回す"
            let count = "計数 (作ってから通算)。数で確かめる検査が読む"
            return [
                "width": construction, "height": construction,
                "texture": "色の面。作ったときに決まり、効果を通すフレームの終わりと次のフレームの頭で効果の控えと取り替わる (フレームの外へ持ち越す・#2388)",
                "exchangePartner": "面を取り替える相手 (効果の控え) の持ち主。初めて取り替えたときに結び、面と同じだけ生きる。面を溜める側が描き場所だけを抱えても、相手の面が先に常駐から外れないため (#2388)",
                "texturesReplaced": "打ち切られた投入の取り消しで面の中身が変わったと名乗った回数 (作ってから通算)。止まっている間に窓と出口へ出し直すかを決める内容の変更番号の一部で、増える一方 (#2388)",
                "depthTexture": construction, "gpu": construction,
                "drawer": "この面を出す先に持つ描き場所 (弱く持つ)。組み立ての最後に 1 度だけ書く",
                "brightness": "明るさを画面へ写す段の設定。画面の性質なのでフレームを越える",
                "encodedStorage": resource, "spareEncodedStorage": resource, "displayStorage": resource,
                "outputPassStorage": resource,
                "lastEncodeSubmission": "最後に出力段を投入した番号。次の出力段の前に名指しで待つ (#927)",
                "readableWindow": "前に返した画素の窓。写しごとに不変で、有効かは返すたびに待ちと写しの新しさで確かめる (#2369)",
                "pixelMirrorsMade": count, "pixelWriteBacksEncoded": count,
                "pixelReadbacksEncoded": count, "encodedImagesMade": count, "encodePassCount": count,
                "failPixelWriteBackForTesting": "検査の差し込み。製品の経路では常に nil (#1906)",
                "judgedThrough": "投げる読む口が GPU の打ち切りを最後に判定した投入の番号。次の判定の範囲の始まりで、フレームに属さない (#1932)",
                "heldDrop": "判定で見つけた、この面へ書いた投入の打ち切り。面の中身が仕上がっていない印で、この面へ書く新しい投入が積まれるまで持ち越す (#1932)",
                "lastWriteSubmission": "この面の中身を書き換えた最後の投入の番号。持ち越した打ち切りを下ろすかを決める。面の中身の印で、フレームに属さない (#1932)",
                "clearSubmission": construction,
                "surfaceClearsRepeated": count,
            ]
        }

        /// 画素の写し (``PixelMirror``) の格納のうち、持ち越すものと理由 ([#1678])。
        ///
        /// [#1678]: https://github.com/mokume-metal/mokume/issues/1678
        private var carriedMirrorState: [String: String] {
            let construction = "写しを作ったときに決まり、写しと同じだけ生きる"
            return [
                "storage": construction, "gpu": construction, "bytesPerRow": construction,
                "syncedThrough": "写しが映した投入の番号。読む口が進め、捨てる口と、打ち切りを見つけた投げる読む口 (#1932) が 0 に戻す。映した絵の印で、フレームに属さない",
                "cpuWriteCount": "CPU が写しへ書いた回数 (作ってから通算)。止まっている間に窓と出口へ出し直すかを決める内容の変更番号の一部で、増える一方。フレームに属さない (#2367)",
                "writtenBackBy": "CPU が書いた画素を最後に書き戻した投入の番号。書き戻しが打ち切られたときに書き込み待ちを立て直すための印で、捨てる口が 0 に戻す。フレームに属さない (#1932)",
            ]
        }

        /// **持ち越す状態と、その理由。** 境目で戻さないことが約束どおりのもの。
        ///
        /// 足すときは理由を 1 行で書く。「戻し忘れ」をここへ逃がすと、この検査は何も守らなく
        /// なる — 迷ったら ``frameState`` に載せ、赤くなったら境目の関数で戻す。
        private var carriedState: [String: String] {
            let construction = "面を作ったときに決まり、面と同じだけ生きる"
            let resource = "資源 (置き場・パイプライン)。作り直さないために持つ"
            let cache = "控え。同じ頼みで作り直さないために持つ (中身は入力で決まり、フレームに属さない)"
            let count = "計数 (作ってから通算・直前のフレーム)。数で確かめる検査が読む"
            let transient = "呼び出しの中でだけ立ち、抜ける前に戻る一時の値。境目では常に既定"
            let testing = "検査の差し込み・上限。製品の経路では既定のまま"
            return [
                "width": construction, "height": construction,
                "outputScale": "\(construction)。書き出しの倍率で、描き場所の作り方が引き継ぐ (#3453)",
                "target": "\(construction)。中のフレームに属する状態は nestedFrameState が見る (#1678)",
                "output": construction, "upscaleStage": construction, "gpu": construction,
                "frameRing": construction, "pipeline": construction, "argumentTable": construction,
                "projection": construction,
                "atlas": construction, "timebase": "時刻と刻み。ランタイムが進め、描き場所は作った面と共有する (#1467)",
                "placementKey": "\(construction)。置いた側の記録が置いた描き場所を見分ける通し番号 (#2306)",
                "vertexStorage": resource, "flatInstanceStorage": resource,
                "thinFillRecordStorage": resource, "thinFillSpanStorage": resource,
                "formInstanceStorage": resource, "solidVertexStorage": resource,
                "solidIndexStorage": resource, "solidInstanceStorage": resource,
                "solidSweepStorage": resource,
                "lightStorageBuffer": resource, "lightingStorage": resource, "materialStorage": resource,
                "surroundingsStorage": resource,
                "blendModeBuffer": resource, "glyphPageBuffer": resource, "uniformsStorage": resource,
                "valuesStorage": resource, "matrixStorage": resource, "computeValuesStorage": resource,
                "uploadStorage": resource, "effectPipelineStorage": resource,
                "imageInputPass": resource, "imageInputUnavailable": "GPU入力の準備失敗を持ち越し、毎フレーム繰り返さない (#1753)",
                "computePipelineStorage": resource,
                "emptyNumbers": resource, "blankPicture": resource,
                "whiteUV": "焼き場の白い区画の位置。面を広げたときだけ変わる",
                "imageCache": cache, "modelCache": cache, "solidMeshes": cache, "solidEdges": cache,
                "typefaces": cache, "solidStrokeGeometry": cache, "modelStrokeGeometries": cache, "modelFills": cache,
            "gradientShaderStorage": "勾配で塗る断片 (#2433)。初めて勾配で塗るときに組み、面と同じだけ生きる。作り直さないために持つ",
            "gradientShaderFailed": "勾配の断片を組めなかった印 (#2433)。組めない面では組み直さない",
            "paintsWithGradient": "いまの断片が勾配の断片かの写し (#2433)。`currentShader` を替えるたびに導き直す (出口の戻しも通る)",
                "discOffsets": "丸い継ぎ目の円板の周のずれ。直前の太さと分割数の 1 件だけで、点は 1024 個が上限 (#1785・#1645)。中身は太さと分割数で決まり、フレームに属さない",
                "ringSplitMemo": "周の分割数の直前の問い合わせ 1 件 (半径と拡大 → 分割数・#1645)。中身は入力で決まり、フレームに属さない",
                "discSplitMemo": "円板の分割数の直前の問い合わせ 1 件 (半径と拡大 → 分割数・#1645)。中身は入力で決まり、フレームに属さない",
                "atlasPageFrame": "焼き場の頁を作ったフレームの番号 (#1342)。番号どうしで比べる",
                "deferredRuns": "先送りして置いた四角の列の控え (#2446)。描き切りで払うか、溜め場と一緒に捨てるので、境目では常に空",
                "deferredRunOpen": "先送りした四角の列を開いているかの印 (#2446)。列を閉じるとき (closeBatch) と、溜め場を捨てるときに下りる。境目では常に既定",
                "isPlacingDeferredGlyph": transient,
                "framePersists": "ランタイムが draw() の後ろで書く、絵が残るかの印 (#2446)。フレームを出る道 (leaveFrame) で下ろすので、境目では常に既定",
                "vector": "SVG へ控える途中の状態 (#3139)。ランタイムが draw() の前に立て、後で下ろす。フレームを出る道 (leaveFrame) でも下ろすので、境目では常に既定。控えるのは観測で、描く道を変えない",
                "retainedSerial": "保持した形を置くたびの通し番号",
                "retainsShapeSolids": "保持した形の立体を置き場に持つかの切り替え (#2791)。検査と計測だけが書く口で、フレームに属さない",
                "retainedSolidThreshold": "置き場に持つ形の大きさの下限 (#2791)。検査と計測だけが書く値で、フレームに属さない",
                "solidPromotion": "形が前のフレームにも置かれたかの控え (#2791)。置き場を作る前の見分けで、フレームのたびに世代を送る。描き切りの外の持ち越しではなく、絵にも効かない",
                "pendingDiscards": "溜め場を捨てた通し番号。形の組み立てが入口と出口で比べる (#1588)",
                "framesDrawn": "閉じたフレームの通し番号。境目の印そのもの",
                "spheresFromUnit": count,
                "effectOutputsExchanged": count, "effectRestoresExchanged": count, "effectRestoreBarriersEncoded": count,
                "effectChangesKeptEncoded": count, "effectCarryDrawsEncoded": count,
                "depthLoadsEncoded": count, "depthStoresEncoded": count,
                "effectBarriersEncoded": count, "effectPassesEncoded": count,
                "computeEncodersOpened": count, "computeEncodersClosed": count,
                "earlySubmissionsAttempted": count,
                "earlySubmissionFailedFrame": "面をまたぐ順のための早い投入に失敗したときのフレーム番号 (#1870)。番号どうしで比べるので、境目で戻す手は要らない (閉じ忘れを捨てる道も番号を進める)",
                "computeBarriersEncoded": count, "uploadBarriersEncoded": count, "uploadWaitsEncoded": count,
                "lastComputeBarrierQueueStages": "最後に積んだ投入の最後の口が待たせる段 (#1687)。積むたびに上書きし、検査が読む。境目で戻す手は要らない",
                "glyphQuadsPlaced": count, "drawCallsInLastFrame": count, "drawsEncodedInLastFrame": count,
                "flatVerticesInLastFrame": count, "flatOutlinesInLastFrame": count,
                "pointScansInLastFrame": count,
                "stagePassesUsed": "段の枠の採番。描き切りごとに 0 から数える (コマンドと同じ寿命)",
                "shaders": "この面が作った断片 (弱く持つ)。観測へ失敗を載せる",
                "effectShaders": "この面が作った効果 (弱く持つ)。観測へ失敗を載せる",
                "computations": "この面が作った計算 (弱く持つ)。観測へ失敗を載せる",
                "warnings": "言った注意の控え。初回だけ言うのは面の寿命で数える",
                "currentShader": "描き方。断片はフレームを越える (ADR-0021 決定 4)",
                "currentNumbers": "描き方。断片と一組でフレームを越える (#1470)",
                "currentCurveDetail": "描き方 (曲線の細かさ)。一度書けば残る",
                "currentCurveTightness": "描き方 (曲線の張り)。一度書けば残る",
                "noiseStore": "揺らぎの種と細かさの置き場。一度書けば残る (断片と共有する・#366)。描き場所は作った面と共有する (#1503)",
                "carriesPictureBeforeEffects": "効果を通す前の絵の控えがあるか。次のフレームの最初の描き切りが戻す (面の取り替え・#1469・#2388)",
                "targetChangedSinceUpscale": "描く先が最後の拡大より後に変わったか。止まっている間の出力段が広げ直して下ろす。フレームの終わりの描き切りも下ろす (#1882)",
                "placingCatchUpDeferred": "置く口の追い付きを見送っているか。描く先が変わる描き切りと、追い付けたときに下ろす (#2042)",
                "placers": "自分を置いた面。自分の絵が変わる直前 (描き切り) に相手へ置いた時点の絵を写させて空にする (#1656)。捨てるだけでは絵が変わらないので残す",
                "casterSegmentsFree": "途中の描き切りで控えた落とす列の区画の空き。読んだ投入が終わってから使い回す (#1656)",
                "upscaledBy": "最後に拡大を積んだ投入の番号。打ち切られたら targetChangedSinceUpscale を立て直すために越える (#2199)",
                "carriedAwaitingOutcome": "効果を通した絵を書いて結末の届いていない投入と、結末の前に次のフレームが戻したか。結末が届いたら手放す (#2388)",
                "filterSubmissions": "filter() の投入のうち結末がまだ届いていないもの。打ち切られたら知らせるために越え、結末が届いたら手放す (#2455)",
                "beforeFilterCommitForTesting": "検査の差し込み。filter() の投入の直前に呼ぶだけで、絵に関わらない (#2455)",
                "filterWorkspaces": "Image.filtered() の作業の面のうち、この面が持つもの。新しい絵に掛けるたびに作り直さないために、面の寿命のあいだ持つ (#2455)",
                "carriedFlush": "効果を通した絵を出す面へ書いて面を取り替えた最後の投入と、その取り替えの内訳。打ち切られたら取り替えを戻して carriesPictureBeforeEffects を投入の前に戻すために越える (#2199・#2388)",
                "placedPictureCopiesFree": "置いた時点の絵の写しの空き。使い回すために持ち、境目で 1 フレーム使わなかったものを手放す (#1656)",
                "placedPictureEpoch": "境目の番号。写しの空きのうち使わなかったものを見分けるのに読む (#1656)",
                "placedPictureCopiesMade": count, "placedPicturesCopied": count,
                "placedPictureCopyLimitReached": count,
                "previousFrameCopy": "ShaderSurface.previousFrame が読む写し。1 枚を使い回し、面の大きさが変わったときだけ作り直す (#2456)",
                "previousFrameRead": "前のフレームの写しを読む列を、このフレームで閉じたか。フレームの頭 (beginFrame) が previousFrameWatched へ移して下ろす (#2456)",
                "previousFrameWatched": "前のフレームで読む列を閉じたか。フレームの頭が previousFrameRead から受け取り、最初の描き切りが写しを取るかを決める (#2456)",
                "previousFrameCopiedThisFrame": "このフレームで前のフレームの写しを取ったか。フレームの頭が下ろし、投入の後に立てる (#2456)",
                "previousFrameCopiesMade": count, "previousFramePicturesCopied": count,
                "shadowBake": "影の焼き付けが持ち越す格納 (#2257)。焼いた面・記帳・資源・数えは面と同じだけ生きる。宣言 4 本 (shadowsEnabled ほか) は frameState に残る。中の分け方は everyTargetStoredPropertyIsClassified (shadowBake の層) が見る",
                "pixelLoadFailed": "直前の読む前の描き切りが失敗したか。描き切れたときに戻る (#1368・頭では戻さない)",
                "pixelWriteGateMade": "窓へ渡す書いてよいかの問い合わせ。面を弱く持つだけで状態を抱えず、答えは呼ばれた時点で決まる。面ごとに使い回す (#2369)",
                "isDrawing": "フレームの内外の印そのもの。境目の関数だけが書く",
                "beginDrawFrame": "isDrawing と組のフレームの印 (beginDraw が開いた本体のフレームの番号)。境目の関数だけが書く",
                "droppedAtTheMainFrame": "本体のフレームが始まる所で閉じ忘れを捨てた後、遅れた endDraw() をまだ名乗っていないかの印 (#1834)。捨てる関数が立て、名乗ったとき・次に本体のフレームが始まる所・自分の次のフレームの頭で下ろす",
                "paintSurfacesNoted": "断片の面を置いた記録に載せ終えた控え。記録が落ちる (フレームの終わりの描き切り) と placedGraphicsDrops と食い違って外れる (#1683)",
                "placedGraphicsDrops": count,
                "isFlushing": transient, "replayedPaint": transient,
                "solidStrokeCapture": transient,
                "solidStrokeCoverage": transient, "solidStrokeIsLonePoint": transient,
                "templateStrokeMatrix": transient, "openBatchHasThinCoverage": transient,
                "coverageStorage": resource, "thinStrokesRebuilt": count,
                "thinFillMemo": "細い塗りの記述の直前の問い合わせ 1 件。中身は入力で決まり、組み立てとは関わらない (#2208)",
                "thinFillRecordsBuilt": count,
                "recordingShape": "形の組み立て (createShape) の入口と出口が対で戻す。閉包なので境目をまたがない",
                "frameEndAwaitingShape": "組み立ての中で閉じようとした自分のフレーム (endDraw()・draw { } の終わり) を出口まで待たせる印 (#1855)。一番外の出口が閉じて下ろし、フレームを出る道 (leaveFrame) でも下ろす。境目では常に既定",
                "shapeMarks": "形の組み立ての入口が控えた溜め場の各並びの長さの積み (#2850)。入口と出口が対で積み・降ろす。閉包なので境目をまたがない",
                "refusedBeginDrawsInsideShape": "形の組み立ての中で断った beginDraw() の数で、対の endDraw() が下ろす (#2834)。一番外の組み立ての出口が 0 に戻すので、境目をまたがない",
                "dropAwaitingShape": "本体のフレームが始まる所で捨てることになった組み立て中の自分のフレームを、出口まで待たせる印 (#2509)。一番外の出口が捨てて下ろし、フレームを出る道 (leaveFrame) でも下ろす。境目では常に既定",
                "sketchTimeLease": "draw(into:) の閉包を抜けた後も開いていたフレームのために、借りた時刻の置き場を手放す処理 (#2454)。フレームを出る道 (leaveFrame) が呼んで下ろす。境目では常に既定",
                "carriesOver": "持ち越しの区間の印。ランタイムが setup() と止まっている間のコールバックの出入口で対で戻す (#1672)。境目をまたがない",
                "placementsFoundOutsideRegions": count,
                "isRuntimeSurface": "ランタイムの本体の面かの印。ランタイムが作ったときに 1 度だけ立て、境目では動かない (#2780)",
                "carriedTransformMark": "持ち越しの区間の中だけの印。区間に入るときと出るときに nil へ戻る (フレームの境目では動かない・#3273)",
                "carriedDiscardedAmount": "持ち越しの区間の中で溜め場から捨てた量。区間に入るときと出るときに 0 へ戻り、区間の外では足さない (#3273)",
                "carriedSegmentCount": count,
                "carriedBackdropAmount": "持ち越しの区間の中で背景の板が足した量。区間に入るときと出るときに 0 へ戻り、境目では動かない (#3273)",
                "carriedTransformRead": "区間の中で変換を読む口を使ったかの印。区間に入るときと出るときと変換を書くたびに偽へ戻る (#3273)",
                "frameOpenedInCarriedSegment": "持ち越しの区間の中で開いたフレームが控えた、区間の変換と積み履歴。フレームの頭が書き、フレームを出る道 (leaveFrame) が戻して下ろす。境目では常に既定 (#3273)",
                "stopsOnPlacementOutsideRegions": testing,
                "placesGlyphs": testing, "instanceCapacity": testing, "particleRoute": testing,
                "sweepPolicy": testing, "sharesUnitShapes": testing, "specializesUnlitSolids": testing, "specializesOpaqueSolids": testing,
                "expandsThinFillsInVertexStage": testing,
                "uploadByteLimit": testing, "failureForTesting": testing,
                "placesRetainedStrokesOnGPU": testing,
                "failEffectPassForTesting": testing, "failAfterEffectsForTesting": testing, "failImageInputForTesting": testing,
                "failEarlySubmissionForTesting": testing, "failPlacedPictureCopyForTesting": testing,
            ]
        }

        /// ``Canvas/Style`` のうち、フレームに属するフィールドと汚す手順。**入れ子もフィールド
        /// ごとに同じ 2 つの表で扱う** — 切り抜き・材質・影は越えず、残りの描き方は越える
        /// (ADR-0021 決定 4 の表)。
        private var frameStyle: [String: (reset: FrameReset, dirty: (inout Canvas.Style) -> Void)] {
            [
                "clip": (.sceneBoth, { $0.clip = Canvas.ClipRect(left: 1, top: 2, right: 4, bottom: 6) }),
                "material": (.sceneEnd, { $0.material.shininess = 8 }),
                "castsShadow": (.sceneEnd, { $0.castsShadow = false }),
                "receivesShadow": (.sceneEnd, { $0.receivesShadow = false }),
            ]
        }

        /// 組み立て中の形の状態 (#1591・#1607)。フレームの外 (`setup()`) でも汚せ、頭で捨てる。
        /// 形の組み立て (`createShape`) の出入口が切り離す群でもある。
        static let shapeState: Set<String> = [
            "isBuildingShape", "shapeKind", "currentNormal", "shapePoints", "shapeHasDepth",
            "shapeIndices", "shapeHoles", "holePoints", "curveGuides",
        ]

        /// ``Canvas/Style`` のうち、越えるフィールド。どれも描き方である (ADR-0021 決定 4)。
        private let carriedStyle: Set<String> = [
            "fill", "stroke", "strokeWeight", "strokeCap", "strokeJoin", "strokeDash", "hasFill", "hasStroke",
            "rectMode", "ellipseMode", "blendMode", "fontSelection", "textSize", "textFace",
            "horizontalTextAlign", "verticalTextAlign", "textLeading", "textWrap", "imageMode",
            "tint", "picture", "gradient",
        ]

        /// 影の焼き付けの持ち越す格納 (``Canvas``の `shadowBake`・#2257) の、中の分け方と理由。
        /// 中の格納は全部が持ち越す (フレームに属する宣言 4 本は `Canvas` に残る)。
        private var carriedShadowBakeState: [String: String] {
            let resource = "資源 (置き場・面)。作り直さないために持つ"
            let count = "計数 (作ってから通算)。数で確かめる検査が読む"
            return [
                "map": "焼き付け先。同じ細かさなら作り直さない (ADR-0021 決定 4)。宣言は shadowDetailValue が戻る",
                "mapsBuilt": count, "barriersEncoded": count, "bakesEncoded": count, "bakesReused": count,
                "bakesAdded": count, "rebakeBarriersEncoded": count,
                "everEnabled": "影を 1 度でも有効にしたか。区切りで落とす側を写すかを決める印で、フレームを越える (#1656)",
                "matrixStorage": resource, "unbakedTexture": resource,
                "holds": "影の面がいま持つ落とす列の並びの指紋。焼いた面は誰にも書き換えられないので、lastKey と同じく越える (#1656)",
                "lastKey": "前に焼いた入力の指紋。焼かなかったフレームでは触らない (影の面は誰にも書き換えられない)",
                "bakedSince": "影の面が拠る焼き付けの投入の範囲の始まり。焼いた投入が打ち切られたら指紋を忘れるために、holds と同じく越える (#2199)",
                "bakedThrough": "bakedSince と同じ範囲の終わり (#2199)",
            ]
        }

        @Test("Canvas の格納は、フレームに属するか持ち越すかのどちらかに載っている")
        func everyStoredPropertyIsClassified() throws {
            // 境目で戻す状態は、境目の関数ごとに手で並べてあり、並べ落とした状態が越えていた
            // (#925・#1472・#1504・#1591・#1622)。**格納を 1 つ足したら、ここで止まる** —
            // どちらの表にも無い名前は、境目で戻すかを誰も決めていない
            let canvas = try makeCanvas()
            let labels = Mirror(reflecting: canvas).children.compactMap(\.label)
            let frame = Set(frameState.map(\.name))
            let carried = Set(carriedState.keys)
            #expect(frame.isDisjoint(with: carried), "両方の表に載っている: \(frame.intersection(carried))")
            for label in labels where label != "style" {
                #expect(
                    frame.contains(label) || carried.contains(label),
                    "\(label) がどちらの表にも無い。フレームに属するなら汚す手順を、持ち越すなら理由を書く")
            }
            for name in frame.union(carried) where !name.contains(".") {
                #expect(labels.contains(name), "\(name) は Canvas の格納に無い (表から消す)")
            }
            // 格納の中に降りる名前は、読み方が要る (綴りに載らないと、戻ったかを誰も見ない)
            #expect(
                Set(nestedFrameState.keys) == frame.filter { $0.contains(".") },
                "格納の中に降りる名前と、その読み方が食い違う")

            let fields = Mirror(reflecting: canvas.style).children.compactMap(\.label)
            let frameFields = Set(frameStyle.keys)
            #expect(frameFields.isDisjoint(with: carriedStyle))
            for field in fields {
                #expect(
                    frameFields.contains(field) || carriedStyle.contains(field),
                    "style.\(field) がどちらの表にも無い")
            }
            for name in frameFields.union(carriedStyle) {
                #expect(fields.contains(name), "style.\(name) は Style に無い (表から消す)")
            }
        }

        @Test("描く先・画素の写し・影の焼き付けの格納も、フレームに属するか持ち越すかのどちらかに載っている (#1678)")
        func everyTargetStoredPropertyIsClassified() throws {
            // 描く先は `Canvas` の表で「面と同じだけ生きる」に分けてあり、表も綴りもその中へ降りて
            // いなかった。写しの書き込み待ち (フレームに属する) が、描かずに捨てたフレームを黙って
            // 越えたのはそのためである ([#1678])。**中の格納を 1 つ足したら、ここで止まる**
            //
            // [#1678]: https://github.com/mokume-metal/mokume/issues/1678
            let canvas = try makeCanvas()
            _ = canvas.target.pixels  // 写しを作らせる
            let mirror = try #require(canvas.target.pixelMirror)
            // 影の焼き付けの格納は `private` なので、`Mirror` で名前を指して降りる
            let shadowBake = try #require(
                Mirror(reflecting: canvas).children.first { $0.label == "shadowBake" }?.value)
            let frame = Set(frameState.map(\.name))
            let layers: [(path: String, labels: [String], carried: [String: String], descended: Set<String>)] = [
                ("target", Mirror(reflecting: canvas.target).children.compactMap(\.label),
                 carriedTargetState, ["pixelMirror"]),
                ("target.pixelMirror", Mirror(reflecting: mirror).children.compactMap(\.label),
                 carriedMirrorState, []),
                ("shadowBake", Mirror(reflecting: shadowBake).children.compactMap(\.label),
                 carriedShadowBakeState, []),
            ]
            for layer in layers {
                let framed = Set(
                    frame.compactMap { name -> String? in
                        guard name.hasPrefix(layer.path + ".") else { return nil }
                        let rest = name.dropFirst(layer.path.count + 1)
                        return rest.contains(".") ? nil : String(rest)
                    })
                let carried = Set(layer.carried.keys)
                #expect(framed.isDisjoint(with: carried), "\(layer.path): 両方の表に載っている")
                for label in layer.labels {
                    #expect(
                        framed.contains(label) || carried.contains(label) || layer.descended.contains(label),
                        "\(layer.path).\(label) がどちらの表にも無い。フレームに属するなら汚す手順と読み方を、持ち越すなら理由を書く")
                }
                for name in framed.union(carried).union(layer.descended) {
                    #expect(layer.labels.contains(name), "\(layer.path).\(name) は格納に無い (表から消す)")
                }
            }
        }

        @Test("控えに分けた格納は、どれも上限つきの型である")
        func everyCacheIsBounded() throws {
            // 控えの上限は 2 度書き落とされた (#1593・#1431)。上の表で「控え」に分けた格納は、
            // 上限を書き落とせない型 (BoundedCache) でしか作らない (ADR-0023 決定 5・#1602)。
            // 辞書で控えを足すと、表に理由を 1 行書いても、ここで止まる
            let canvas = try makeCanvas()
            let cacheReason = try #require(carriedState["imageCache"])
            let caches = Set(carriedState.filter { $0.value == cacheReason }.keys)
            #expect(caches.count >= 5)
            for child in Mirror(reflecting: canvas).children {
                guard let label = child.label, caches.contains(label) else { continue }
                let typeName = String(describing: type(of: child.value))
                #expect(
                    typeName.hasPrefix("BoundedCache<"),
                    "\(label) は控えに分けてあるのに \(typeName) で持っている。上限つきの型で作る")
            }
        }

        /// フレームに属する状態の綴り。**同じ面の上で比べる** — 面ごとに違う資源 (焼き場の面) を
        /// 指す値も、同じ面なら同じ綴りになる。
        private func frameFingerprint(of canvas: Canvas) -> [String: String] {
            let names = Set(frameState.map(\.name))
            var prints: [String: String] = [:]
            for child in Mirror(reflecting: canvas).children {
                guard let label = child.label, names.contains(label) else { continue }
                prints[label] = String(describing: child.value)
            }
            for (name, read) in nestedFrameState { prints[name] = read(canvas) }
            let styleNames = Set(frameStyle.keys)
            for child in Mirror(reflecting: canvas.style).children {
                guard let label = child.label, styleNames.contains(label) else { continue }
                prints["style.\(label)"] = String(describing: child.value)
            }
            return prints
        }

        @Test(
            "フレームに属する状態は、どの境目を越えても既定へ戻る (#1671)",
            arguments: FrameBoundary.allCases, OpenBatch.allCases)
        func frameStateResetsAtEveryBoundary(_ boundary: FrameBoundary, _ openBatch: OpenBatch) throws {
            // 戻す状態を境目の関数ごとに手で並べていたので、並べ落とした状態が 1 件ずつ見つかって
            // きた (#925・#1472・#1504・#1591・#1622)。**全部汚してから越え、全部が戻ったかを見る**
            // — 1 例ずつの検査では、次に足した状態の戻し落としが黙る
            let host = try makeCanvas()
            let canvas = boundary.usesLayer ? try host.createGraphics(Int(host.width), Int(host.height)) : host
            let other = try makeCanvas()
            var fixture = FrameFixture(
                sheet: try canvas.createImage(8, 8), other: other,
                computation: try canvas.makeComputation(
                    "kernel void mark(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) { out[id] = 1; }",
                    name: "mark"),
                numbers: try canvas.makeNumbers(count: 1),
                // 粒は別の面で作る。作る道は形を組み立てる (`particleQuad`) ので、開いた列の種類が
                // 汚す前から動いてしまう
                particles: try other.makeParticles(count: 8),
                openBatch: openBatch)
            fixture.sheet.fill(.linear(red: 1, green: 1, blue: 1))
            let resets = Dictionary(
                uniqueKeysWithValues: frameState.map { ($0.name, $0.reset) }
                    + frameStyle.map { ("style.\($0.key)", $0.value.reset) })

            var baseline: [String: String] = [:]
            var dirtied: [String: String] = [:]
            var closed: [String: String]?
            var crossed: [String: String] = [:]
            try boundary.run(
                canvas, host: host,
                dirty: {
                    baseline = frameFingerprint(of: canvas)
                    for entry in frameState { entry.dirty(canvas, &fixture) }
                    for (_, field) in frameStyle { field.dirty(&canvas.style) }
                    dirtied = frameFingerprint(of: canvas)
                },
                closed: { closed = frameFingerprint(of: canvas) },
                inspect: { crossed = frameFingerprint(of: canvas) })

            if boundary.dirtiesOutside {
                // フレームの外で汚せるのは組み立て中の形くらいである。それが汚れていなければ、
                // この越え方は何も見ていない
                for name in Self.shapeState.subtracting(["shapeKind", "shapeHasDepth"]) {
                    #expect(dirtied[name] != baseline[name], "\(name) を外で汚せていない")
                }
            } else {
                for entry in frameState where entry.openIn.contains(openBatch) {
                    #expect(
                        dirtied[entry.name] != baseline[entry.name],
                        "\(entry.name) を汚す手順が汚していない (既定のままでは戻ったかを見分けられない)")
                }
                for field in frameStyle.keys {
                    #expect(dirtied["style.\(field)"] != baseline["style.\(field)"], "style.\(field) が汚れていない")
                }
            }

            if boundary.closes {
                let closed = try #require(closed, "閉じた直後を見ていない")
                for (name, value) in baseline.sorted(by: { $0.key < $1.key }) where resets[name]?.atEnd == true {
                    #expect(closed[name] == value, "\(name) が \(boundary) で閉じた直後に既定へ戻っていない")
                }
            }
            for (name, value) in baseline.sorted(by: { $0.key < $1.key }) {
                // 外で置いたものは最初のフレームへ持ち越すのが約束である (ADR-0021 決定 4 の追補
                // (2026-09-27))。頭で戻すものだけを見る
                guard !boundary.dirtiesOutside || resets[name]?.atHead == true else { continue }
                // コールバックの出口で戻すのはシーンの記述だけ (#3408)。置いたもの・描き方は残る
                guard boundary != .inputCallbackExit || resets[name]?.isSceneDescription == true else { continue }
                #expect(crossed[name] == value, "\(name) が \(boundary) の境目で既定へ戻らない")
            }
        }

        // MARK: - 形の組み立ての出入口で切り離す組み立て中の形 (#1607)

        /// 組み立て中の形の綴り (``shapeState`` の名前だけ)。
        private func shapeFingerprint(of canvas: Canvas) -> [String: String] {
            frameFingerprint(of: canvas).filter { Self.shapeState.contains($0.key) }
        }

        /// 組み立て中の形を、``shapeState`` の全部が既定と違う状態にする。
        private func openBusyShape(on canvas: Canvas) {
            canvas.beginShape(.triangles)
            canvas.normal(0, 0, 1)
            canvas.vertex(0, 0, 1)
            canvas.vertex(8, 0)
            canvas.vertex(0, 8)
            canvas.index(0)
            canvas.beginContour()
            canvas.vertex(1, 1)
            canvas.vertex(2, 1)
            canvas.vertex(1, 2)
            canvas.beginContour()  // 1 つ目の穴を畳み、2 つ目を開いたままにする
            canvas.vertex(3, 3)
            canvas.curveVertex(4, 4)
            canvas.curveVertex(5, 5)
        }

        @Test("外で開いた形は、形の組み立てを挟んでもそのまま残る (#1607)", arguments: [false, true])
        func createShapeKeepsTheOuterOpenShape(insideFrame: Bool) throws {
            // 形の組み立ても、積む・降ろすが釣り合う単位である (ADR-0021 決定 4 の追補
            // (2026-09-15))。直す前は組み立て中の形を切り離しておらず、記録の中の `beginShape()` が
            // 外で開いた形を黙って上書きした。**並びの全部を見る** — 退かせる並びは 3 か所に
            // 書いてあり (`Canvas.OpenShape`)、1 つ落としても型は通る
            let canvas = try makeCanvas()
            let fresh = shapeFingerprint(of: canvas)
            var before: [String: String] = [:]
            var after: [String: String] = [:]
            func run() {
                openBusyShape(on: canvas)
                before = shapeFingerprint(of: canvas)
                _ = canvas.createShape {
                    canvas.beginShape()
                    canvas.vertex(0, 0)
                    canvas.vertex(16, 0)
                    canvas.vertex(16, 16)
                    canvas.endShape(.close)
                }
                after = shapeFingerprint(of: canvas)
                canvas.endShape()
            }
            // フレームの外は `setup()` を模す。形を開けるのは持ち越しの区間の中だけである (#1672)
            if insideFrame { try canvas.draw { run() } } else { carryingOver(canvas, run) }

            for name in Self.shapeState.sorted() {
                #expect(before[name] != fresh[name], "\(name) が既定のままなので、戻ったかを見分けられない")
                #expect(after[name] == before[name], "\(name) が形の組み立てを挟んで変わった")
            }
            #expect(!canvas.warnings.hasWarned(.shapeNotEnded), "閉じた形しか組み立てていないのに注意した")
        }

        @Test("形の組み立ての中で開いたまま抜けた形は、出口で捨てて外へ漏らさない (#1607)", arguments: [false, true])
        func createShapeDropsTheShapeLeftOpenInside(insideFrame: Bool) throws {
            // 直す前は記録の中で開いた形が外へ漏れ、外の `vertex()` が形自身の座標の点に積み足した
            let canvas = try makeCanvas()
            var building: Bool?
            var points: Int?
            func run() {
                _ = canvas.createShape {
                    canvas.beginShape()
                    canvas.vertex(0, 0)
                    canvas.vertex(16, 0)
                }
                building = canvas.isBuildingShape
                canvas.vertex(16, 16)
                points = canvas.shapePoints.count
            }
            // フレームの外は `setup()` を模す。区間の外の `vertex()` は形の外より先に区間の外を
            // 言う (#1672) ので、形の外の注意を見るには区間の中で呼ぶ
            if insideFrame { try canvas.draw { run() } } else { carryingOver(canvas, run) }

            #expect(building == false, "記録の中で開いた形が外へ漏れた")
            #expect(points == 0, "外の vertex() が記録の中の形に積み足した")
            #expect(canvas.warnings.hasWarned(.shapeNotEnded))
            #expect(canvas.warnings.hasWarned(.vertexOutsideShape))
        }

        @Test("外で開いた形は、形の組み立ての中からは続けられない (#1607)")
        func createShapeCannotContinueTheOuterShape() throws {
            let canvas = try makeCanvas()
            var shape: Shape?
            try canvas.draw {
                canvas.beginShape()
                canvas.vertex(0, 0)
                canvas.vertex(60, 0)
                shape = canvas.createShape {
                    canvas.vertex(30, 60)  // 外の形の続きにはならない
                    canvas.endShape(.close)
                }
                canvas.vertex(30, 60)
                canvas.endShape(.close)
            }
            #expect(canvas.warnings.hasWarned(.vertexOutsideShape), "記録の中から外の形を続けられた")
            #expect(canvas.warnings.hasWarned(.shapeNotBegun), "記録の中の endShape() が外の形を閉じた")
            let recorded = try #require(shape)
            #expect(recorded.runs.isEmpty, "記録の中に外の形が焼き付いた")
        }

        /// 戻すときに変わるフィールド。列を閉じるかどうかの違いを持つものを並べる。
        enum StyleChange: CaseIterable, CustomTestStringConvertible {
            case material, castsShadow, receivesShadow, blendMode, clip, picture, fill

            /// 戻す前に列を閉じるか。**置いた図形が、列の持つ設定を後から書き換えられない**
            /// ためのもので、列が読むのは材質・影・混ぜ方・切り抜きだけである。塗りに貼る絵は
            /// 塗りを置く手前で面を選び直すので、戻すときには閉じない
            var closesBatch: Bool {
                switch self {
                case .material, .castsShadow, .receivesShadow, .blendMode, .clip: true
                case .picture, .fill: false
                }
            }

            var testDescription: String { "\(self)" }

            func apply(from source: Canvas.Style, to style: inout Canvas.Style) {
                switch self {
                case .material: style.material = source.material
                case .castsShadow: style.castsShadow = source.castsShadow
                case .receivesShadow: style.receivesShadow = source.receivesShadow
                case .blendMode: style.blendMode = source.blendMode
                case .clip: style.clip = source.clip
                case .picture: style.picture = source.picture
                case .fill: style.fill = source.fill
                }
            }
        }

        @Test("スタイルを戻すとき、列を閉じるのは列が読む設定が変わったときだけ", arguments: StyleChange.allCases)
        func restoringStyleClosesTheBatchOnlyWhenItMatters(_ change: StyleChange) throws {
            let canvas = try makeCanvas()
            let distinct = distinctStyle(on: canvas)
            try canvas.draw {
                canvas.rect(0, 0, 8, 8)  // 閉じていない列を 1 本持つ
                var restored = canvas.currentStyle
                change.apply(from: distinct, to: &restored)
                let before = canvas.batches.count
                canvas.currentStyle = restored
                #expect(
                    canvas.batches.count - before == (change.closesBatch ? 1 : 0),
                    change.closesBatch ? "戻す前に列を閉じていない" : "閉じなくてよい列を閉じた")
            }
        }

        @Test("開いたままの形は、描き場所の endDraw() の後へ残らない (#1591)")
        func openShapeDoesNotOutliveTheFrame() throws {
            // 終わりの側で捨てることを見る。頭の側だけだと、`draw()` で開いた形が止まっている
            // 間のコールバック (ここではフレームの外の `vertex()`) へ漏れる
            let canvas = try makeCanvas()
            canvas.beginDraw()
            canvas.background(black)
            canvas.beginShape()
            canvas.vertex(0, 0)
            canvas.vertex(16, 0)
            canvas.vertex(16, 16)
            canvas.endDraw()

            #expect(!canvas.isBuildingShape)
            #expect(canvas.shapePoints.isEmpty)
            #expect(canvas.warnings.hasWarned(.shapeNotEnded))

            // 止まっている間のコールバックを模す (持ち越しの区間・#1672)
            carryingOver(canvas) { canvas.vertex(8, 8) }
            #expect(canvas.warnings.hasWarned(.vertexOutsideShape), "閉じた後の vertex() が黙っている")
            #expect(canvas.shapePoints.isEmpty, "閉じた後の vertex() が点を積んだ")
        }

        @Test("開いたままの穴と通過点の曲線も、形ごと捨てる (#1591)")
        func openHoleAndCurveGuidesDoNotOutliveTheFrame() throws {
            // 開いたままの穴 (#1528) は畳まずに形ごと捨てる。畳むのは `endShape()` が描くときの
            // 約束である
            let canvas = try makeCanvas()
            var holes = 0
            var guides = 0
            var holeOpen = false
            canvas.beginDraw()
            canvas.beginShape()
            canvas.vertex(0, 0)
            canvas.vertex(60, 0)
            canvas.vertex(60, 60)
            canvas.beginContour()
            canvas.vertex(4, 4)
            canvas.vertex(12, 4)
            canvas.vertex(4, 12)
            canvas.beginContour()  // 1 つ目の穴を畳み、2 つ目を開く
            for index in 0..<6 {
                canvas.curveVertex(Float(20 + index * 4), Float(20 + index % 2 * 8))
            }
            holes = canvas.shapeHoles.count
            guides = canvas.curveGuides.count
            holeOpen = canvas.holePoints != nil
            canvas.endDraw()

            try #require(holes > 0 && guides > 0 && holeOpen, "検査の前提: 穴と曲線を開いたまま抜けていない")
            #expect(canvas.curveGuides.isEmpty)
            #expect(canvas.shapeHoles.isEmpty)
            #expect(canvas.holePoints == nil)
        }
    }
}
