// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import Synchronization
import simd

/// 図形を描くためのパイプラインと、資源の受け渡し口。
///
/// この世代の Metal では、シェーダへ資源を渡すのは**引数のテーブル**で、GPU 上の
/// 番地を指す。テーブルの用意とパイプラインの構築をここにまとめる。
///
/// 頂点を組み立てる側は組み込みのものしかない — 利用者が差し替えるのは塗りだけなので、
/// **利用者の断片から作るパイプラインも、頂点側は同じものを使う。**
///
/// ## 持ち主は ``RenderDevice`` で、面は分け合う ([#2785])
///
/// ここが抱えるのは**組み上がったら変わらないもの**だけ — ライブラリ・組み立て器・
/// パイプライン・奥行きの扱い (基本図形のパイプラインは使うときに 1 本ずつ組んで控える・
/// 組んだ 1 本は変わらない — [#3114])。組み込みの原文からできる値で、面にも利用者の断片にも
/// 依らない。なので ``RenderDevice/shapePipeline(pixelFormat:)`` が GPU ごと・出力形式ごとに
/// 1 つ組み、面は何枚作っても同じものを使う。面を作るたびに組み直すと、描き場所を動的に
/// 作る場面が、寸法にも内容にも依らない費用を払い続ける。
///
/// **面ごとに変わるもの (引数のテーブル) はここに置かない。** 束ねる番地は描くたびに書き換わる
/// ので、分け合うと面どうしで束ねが漏れる。面が自分の分を作る (``makeArgumentTable(gpu:)``)。
///
/// [#2785]: https://github.com/mokume-metal/mokume/issues/2785
/// [#3114]: https://github.com/mokume-metal/mokume/issues/3114
final class ShapePipeline {
    /// 同じ絵を描く、**混ぜ方ごとに分かれたパイプラインの組**。
    ///
    /// 断片が `[[color(0)]]` を宣言すると、同じ画素へ来る断片は順に並べる必要が
    /// あり、重なりの多い絵ではそれ自体が費用になる。既定の重ね方 (`.blend`) は
    /// 乗算済みの source-over なので**固定機能のブレンドと式が一致し**、置き換え
    /// (`.replace`) はそもそも下地を見ない — この 2 つは下地を読まない断片で描く
    /// ([#758](https://github.com/mokume-metal/mokume/issues/758))。
    ///
    /// 残りの混ぜ方は固定機能では表せないので、今までどおり断片が下地を読んで混ぜる。
    ///
    /// ## どの混ぜ方がどちらの経路へ行くか
    ///
    /// **この表が一覧の実体である**
    /// ([ADR-0001](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0001-founding-principles.md)
    /// 原則 9)。`BlendMode` の doc と `Shaders/Common.metal` の `mokume_composite` は
    /// ここを指すだけで、写しを持たない
    /// ([#887](https://github.com/mokume-metal/mokume/issues/887))。
    ///
    /// | 混ぜ方 | 列 | 描く断片 | 下地 | 混ぜる主体 |
    /// | --- | --- | --- | --- | --- |
    /// | `.blend` (0) | `blend` | `mokume_fragmentDirect` / `mokume_formFragmentBlend` | 読まない | 固定機能のブレンド |
    /// | `.replace` (9) | `replace` | `mokume_fragmentReplace` / `mokume_formFragmentReplace` | 読まない | 混ぜない (そのまま置く) |
    /// | `.add` … `.screen` (1–8) | `composite` | `mokume_fragmentMain` / `mokume_formFragment` | 読む | `mokume_composite` |
    ///
    /// 番号は `BlendMode.rawIndex` (正本は `Shaders/Kinds.metal`)。**`mokume_composite`
    /// へ 0 と 9 が届く経路は無い** — 選び分けは `state(for:)` の 1 箇所で起き、
    /// 前 2 者が使う断片は `mode` を引数に取らない。
    struct BlendStates {
        /// 断片が下地を読んで混ぜる列 (`.blend` と `.replace` 以外)。
        let composite: any MTLRenderPipelineState
        /// 重ねる列。断片は下地を読まず、固定機能のブレンドが混ぜる。
        let blend: any MTLRenderPipelineState
        /// 置き換える列。断片は下地を読まず、混ぜずにそのまま置く。
        let replace: any MTLRenderPipelineState

        /// 3 つとも。差し替えた後も、投入済みのフレームが終わるまで抱えるのに使う
        /// (``RenderDevice/holdUntilSubmittedWorkFinishes(_:)``)。
        var all: [AnyObject] { [composite, blend, replace] }

        /// ``StatesJob`` が組んだ 3 本 (`composite`・`blend`・`replace` の順) から。
        init(_ built: BuiltStates) {
            precondition(built.states.count == 3, "a blend set is built from exactly three states")
            composite = built.states[0]
            blend = built.states[1]
            replace = built.states[2]
        }

        /// その列を描くパイプライン。**置き換える列のうち、細い線を広げた頂点を持つ列だけは
        /// 下地を読む列** (`composite`) で描く (#1637)。広げた帯は覆う割合だけを置き換え、残りの
        /// 下地を残す (`mokume_fragmentMain` の置き換えの枝)。
        func drawing(_ batch: Canvas.Batch) -> any MTLRenderPipelineState {
            batch.run.mode == .replace && batch.thinCoverage ? composite : state(for: batch.run.mode)
        }

        /// その混ぜ方で描くパイプライン。
        func state(for mode: BlendMode) -> any MTLRenderPipelineState {
            switch Column(mode) {
            case .blend: blend
            case .replace: replace
            case .composite: composite
            }
        }

        /// 3 本のうちの 1 本を指す列。**混ぜ方からどの本へ行くかを決めるのはここ 1 か所**で、
        /// 3 本を一度に組む経路 (``init(_:)``) も、基本図形を 1 本ずつ組む経路
        /// (``ShapePipeline/formState(for:mode:)``・#3114) も、この並びを使う。
        enum Column: CaseIterable, Sendable {
            case composite, blend, replace

            init(_ mode: BlendMode) {
                switch mode {
                case .blend: self = .blend
                case .replace: self = .replace
                default: self = .composite
                }
            }

            /// ``ShapePipeline/blendPlans(pixelFormat:label:vertexFunctionName:fragmentFunctionName:blendFragmentFunctionName:replaceFragmentFunctionName:formFlags:)``
            /// が返す 3 本の中での位置。
            var planIndex: Int {
                switch self {
                case .composite: 0
                case .blend: 1
                case .replace: 2
                }
            }
        }
    }

    /// 頂点の並びを渡す口の番号 (シェーダ側の `buffer(0)`)。
    static let vertexBufferIndex = 0
    /// 描画先の座標へ落とす行列を渡す口の番号 (シェーダ側の `buffer(1)`)。
    static let projectionBufferIndex = 1
    /// 混ぜ方の番号を渡す口の番号 (シェーダ側の `buffer(2)`)。
    static let blendModeBufferIndex = 2
    /// 列が字の焼き場を読むかを渡す口の番号 (シェーダ側の `buffer(3)`)。置き換える列の
    /// 断片 (``flatReplaceFragmentFunctionName``) だけが読む。
    ///
    /// 面の中身の種類を渡していた口 (`textureKindBufferIndex`) が、色を持つ字形を色のまま
    /// 描く変更で空いた番号を使っている
    /// ([#468](https://github.com/mokume-metal/mokume/pull/468))。
    static let glyphPageBufferIndex = 3
    /// フレームを通して変わらない値を渡す口の番号 (シェーダ側の `buffer(4)`)。
    static let uniformsBufferIndex = 4
    /// 利用者が渡した値の口の番号 (シェーダ側の `buffer(5)`)。
    static let valuesBufferIndex = 5
    /// この列に効く光の区間を渡す口の番号 (シェーダ側の `buffer(6)`)。
    static let lightingBufferIndex = 6
    /// 置いた光を渡す口の番号 (シェーダ側の `buffer(7)`)。
    static let lightsBufferIndex = 7
    /// この列の材質を渡す口の番号 (シェーダ側の `buffer(8)`)。
    static let materialBufferIndex = 8
    /// この列に効く周囲を渡す口の番号 (シェーダ側の `buffer(9)`)。
    static let surroundingsBufferIndex = 9
    /// 立体の置き場所を渡す口の番号 (シェーダ側の `buffer(10)`)。
    static let instanceBufferIndex = 10
    /// 塗りが読む数の並びを渡す口の番号 (シェーダ側の `buffer(11)`)。
    static let numbersBufferIndex = 11
    /// 平面の頂点ごとの被覆を渡す口の番号 (シェーダ側の `buffer(12)`・#1637)。
    static let coverageBufferIndex = 12
    /// 読む面を渡す口の番号 (シェーダ側の `texture(0)`)。
    static let textureIndex = 0
    /// 焼き付けた影を渡す口の番号 (シェーダ側の `texture(1)`)。
    static let shadowTextureIndex = 1
    /// 利用者が宣言した面を渡す口の、最初の番号 (シェーダ側の `texture(2)` から)。
    static let surfaceTextureIndex = 2
    /// 1 つの断片へ渡せる面の枚数。**上限の正典はここ 1 か所**で、原稿を組み立てる側
    /// (`ShaderSource`)・入口 (`Common.metal`)・断る側 (`Canvas.loadShader`) が
    /// これを見る ([#407](https://github.com/mokume-metal/mokume/issues/407))。
    ///
    /// 口は使う枚数によらず全部が束ねられる。**空きの口にも何かを束ねる**ので、
    /// 宣言より多く読もうとした断片も、絵が乱れるだけで異常終了はしない。
    static let surfaceCapacity = 4

    /// 引数のテーブルに束ねられる置き場の数。上の口の番号はすべてこれより小さい
    /// (`ShaderInterfaceTests` が、入口の関数が宣言する番号と突き合わせる)。
    static let bufferBindCount = 13
    /// 引数のテーブルに束ねられる面の数。利用者の面の口が最後に並ぶ。
    static let textureBindCount = surfaceTextureIndex + surfaceCapacity

    /// 組み込みの塗りで描くパイプライン。**混ぜ方ごとに 3 本ある** (``BlendStates``)。
    let states: BlendStates

    /// 立体を組み込みの塗りで描くパイプライン。頂点の落とし方だけが違う。
    let solidStates: BlendStates
    /// 正の寸法の球・箱・平面・円柱の塗りを、単位の形の頂点と置き場所の軸ごとの寸法で描く
    /// パイプライン ([#1862]・[#2386])。頂点関数だけが別のライブラリ (`UnitShape.metal`) にあり、
    /// 断片は ``solidStates`` と同じ。
    ///
    /// [#1862]: https://github.com/mokume-metal/mokume/issues/1862
    /// [#2386]: https://github.com/mokume-metal/mokume/issues/2386
    let unitShapeStates: BlendStates
    /// 単位の形の列を影へ焼くパイプライン (``shadowState`` の単位の形の版)。
    let unitShapeShadowState: any MTLRenderPipelineState
    let solidStrokeStates: BlendStates
    let solidStrokeShadowState: any MTLRenderPipelineState

    /// 光から見た奥行きを焼き付けるパイプライン。**頂点だけで、断片を持たない。**
    ///
    /// 焼くのは奥行きの面 1 枚で、それは前後判定が書く。色の面が無いので断片には
    /// 書く先が無く、置かない ([#757](https://github.com/mokume-metal/mokume/issues/757))。
    let shadowState: any MTLRenderPipelineState

    /// 平面の基本図形を距離関数で描くパイプライン ([#752])。
    ///
    /// 頂点も断片も専用で、利用者の断片は差し替えられない — 断片が読む面・頂点の
    /// 属性を契約に持つ利用者の断片は、三角形の経路 (``states``) に居続ける。
    ///
    /// **塗り / 輪郭の有無でも分かれる。** 断片は無い側の綴りを持たないほうが速く
    /// (面を覆う矩形 200 枚で 1.4 ms)、有無は列ごとに決まっているので function constant
    /// で特化できる ([#771])。鍵は旗 (``FormInstance/fillsFlag`` | `strokesFlag`) —
    /// 塗りも輪郭も無い図形は置かれないので 0 は使わない。
    ///
    /// **1 画素より細い塗り・輪郭の帯の細い穴を含むかでも分かれる** (``FormInstance/thinFillsFlag``・
    /// [#1477]・[#2186])。3 つの組 (旗 1・2・3) のそれぞれに、細い枝を残した組 (旗 5・6・7) がある。
    ///
    /// [#752]: https://github.com/mokume-metal/mokume/issues/752
    /// [#771]: https://github.com/mokume-metal/mokume/issues/771
    /// [#1477]: https://github.com/mokume-metal/mokume/issues/1477
    /// [#2186]: https://github.com/mokume-metal/mokume/issues/2186
    ///
    /// ## 組むのは使うときで、1 本ずつ ([#3114])
    ///
    /// 組は 12 組 × 3 本 = 36 本あり、全部を ``Canvas`` を作るときに組むと、Metal のコンパイルの
    /// キャッシュが無いとき (版を上げた直後・初めて開く `.app`) に起動が 1.5 秒延びた (#2991)。
    /// 旗の組は絵の中身で決まり、混ぜ方も絵ごとなので、1 つの絵が使う組は数本しかない。
    /// **最初にその旗・その混ぜ方で描くフレームの頭 (``Canvas`` の溜めた列の用意) で組み、
    /// 控えて使い回す。** 起動で組むのは ``defaultFormKey`` の 1 本だけ。
    ///
    /// [#3114]: https://github.com/mokume-metal/mokume/issues/3114
    private let formPipelines: Mutex<[FormKey: any MTLRenderPipelineState]>

    /// 基本図形のパイプライン 1 本の鍵 — 旗の組と、混ぜ方の列。
    struct FormKey: Hashable, Sendable {
        let flags: UInt32
        let column: BlendStates.Column
    }

    /// **起動で組む 1 本。** 既定の描き方 (塗りも輪郭もあり・重ねる) で `circle` を描く列 —
    /// 楕円は縁が軸に斜めになりうる形なので、旗に斜めの縁が立つ。ほかは使うときに組む。
    static let defaultFormKey = FormKey(
        flags: FormInstance.fillsFlag | FormInstance.strokesFlag | FormInstance.obliqueEdgesFlag,
        column: .blend)

    /// 組むパイプラインの旗の組。細い枝の旗は、塗りだけの組には細い塗りで、輪郭だけの組には
    /// 帯の細い穴で立つ (``FormInstance/mayHaveThinFill(unitsPerDrawnPixel:)`` は塗りの無い形に、
    /// ``FormInstance/mayHaveThinHole(unitsPerDrawnPixel:)`` は輪郭の無い形に「含まない」と答える)。
    ///
    /// **縁が画素の軸に斜めになりうる形を含むか** (``FormInstance/obliqueEdgesFlag``・#2991) でも分かれ、
    /// 上の 6 つのそれぞれに、斜めの縁の枝を残した組がある (12 組)。
    static let formFlagCombinations: [UInt32] = {
        let base: [UInt32] = [
            FormInstance.fillsFlag, FormInstance.strokesFlag,
            FormInstance.fillsFlag | FormInstance.strokesFlag,
            FormInstance.fillsFlag | FormInstance.thinFillsFlag,
            FormInstance.strokesFlag | FormInstance.thinFillsFlag,
            FormInstance.fillsFlag | FormInstance.strokesFlag | FormInstance.thinFillsFlag,
        ]
        return base + base.map { $0 | FormInstance.obliqueEdgesFlag }
    }()

    /// その旗の組・その混ぜ方で描くパイプライン。**まだ組んでいなければここで組む** (#3114)。
    ///
    /// 組むのは数十 ms (キャッシュが無いとき) で、描くフレームの頭でそれを払う。
    /// ``Canvas`` は積む前に ``prepareForms(_:)`` で組み済みにするので、積む側は組み済みの
    /// 1 本を引くだけである (``builtFormState(for:mode:)``)。
    func formState(for flags: UInt32, mode: BlendMode) throws(RenderFailure) -> any MTLRenderPipelineState {
        let key = FormKey(flags: flags, column: .init(mode))
        return try formPipelines.withLock { (built) throws(RenderFailure) in
            if let state = built[key] { return state }
            let state = try Self.makeFormState(
                compiler: compiler, vertexLibrary: vertexLibrary, pixelFormat: pixelFormat, key: key)
            built[key] = state
            return state
        }
    }

    /// 組み済みの 1 本。組んでいなければ ``prepareForms(_:)`` を呼び忘れている。
    func builtFormState(for flags: UInt32, mode: BlendMode) -> any MTLRenderPipelineState {
        let key = FormKey(flags: flags, column: .init(mode))
        guard let state = formPipelines.withLock({ $0[key] }) else {
            preconditionFailure(
                "the form pipeline for flags \(flags) (\(key.column)) was not prepared before encoding")
        }
        return state
    }

    /// 積む列が使う基本図形のパイプラインを、積む前に組み済みにする。
    func prepareForms(_ uses: some Sequence<(flags: UInt32, mode: BlendMode)>) throws(RenderFailure) {
        for use in uses { _ = try formState(for: use.flags, mode: use.mode) }
    }

    /// いまの組み済みの本数 (検査用)。
    var builtFormStateCount: Int { formPipelines.withLock { $0.count } }

    /// 平面の奥行きの扱い — **常に通し、書かない**。
    ///
    /// 平面は奥行きを持たない挿入レイヤーなので ([ADR-0021] 決定 2)、書かないことで
    /// 後から来た立体の前後関係を汚さない。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    let flatDepthState: (any MTLDepthStencilState)?

    /// 立体の奥行きの扱い — **手前だけを通し、書く**。
    let solidDepthState: (any MTLDepthStencilState)?

    /// 面を置き換える列の奥行きの扱い — **常に通し、書く** (`Canvas.Batch.replacesSurface`・[#1685])。
    ///
    /// 置き換えは、先に描いた立体の奥行きに左右されない。比べると、途中の描き切りで載った
    /// 立体の画素で板が落ちる ([#1657])。
    ///
    /// [#1657]: https://github.com/mokume-metal/mokume/issues/1657
    /// [#1685]: https://github.com/mokume-metal/mokume/issues/1685
    let replaceDepthState: (any MTLDepthStencilState)?

    private let vertexLibrary: any MTLLibrary
    /// 単位の形の頂点関数だけを持つライブラリ。**Shapes とは別に組む** — 同じライブラリへ足すと、
    /// 既存の頂点関数の組み上がり方が変わりうる (`UnitShape.metal` の冒頭)。
    private let unitShapeLibrary: any MTLLibrary
    private let compiler: any MTL4Compiler
    private let pixelFormat: MTLPixelFormat

    init(gpu: RenderDevice, pixelFormat: MTLPixelFormat) throws(RenderFailure) {
        self.pixelFormat = pixelFormat
        let library = try gpu.shaders.makeShapeLibrary(
            named: "Shapes", body: gpu.shaders.bundledShaderSource(named: "Shapes"),
            bodyName: ShaderLibraries.bundledName("Shapes"))
        self.vertexLibrary = library
        let unitShapeLibrary = try gpu.shaders.makeShapeLibrary(
            named: "UnitShape", body: gpu.shaders.bundledShaderSource(named: "UnitShape"),
            bodyName: ShaderLibraries.bundledName("UnitShape"))
        self.unitShapeLibrary = unitShapeLibrary

        let compiler = try gpu.shaders.compiler()
        self.compiler = compiler

        self.states = try Self.makeBlendStates(
            compiler: compiler, vertexLibrary: library, fragmentLibrary: library,
            pixelFormat: pixelFormat, label: "mokume.shapes",
            vertexFunctionName: Self.flatVertexFunctionName)
        self.solidStates = try Self.makeBlendStates(
            compiler: compiler, vertexLibrary: library, fragmentLibrary: library,
            pixelFormat: pixelFormat, label: "mokume.solids",
            vertexFunctionName: Self.solidVertexFunctionName)
        self.unitShapeStates = try Self.makeBlendStates(
            compiler: compiler, vertexLibrary: unitShapeLibrary, fragmentLibrary: library,
            pixelFormat: pixelFormat, label: "mokume.unit-shapes",
            vertexFunctionName: Self.unitShapeVertexFunctionName)
        self.unitShapeShadowState = try Self.makeDepthOnlyState(
            compiler: compiler, vertexLibrary: unitShapeLibrary, label: "mokume.unit-shape-shadow",
            vertexFunctionName: Self.unitShapeVertexFunctionName)

        self.solidStrokeStates = try Self.makeBlendStates(
            compiler: compiler, vertexLibrary: library, fragmentLibrary: library,
            pixelFormat: pixelFormat, label: "mokume.solid-strokes",
            vertexFunctionName: Self.solidStrokeVertexFunctionName)
        self.solidStrokeShadowState = try Self.makeDepthOnlyState(
            compiler: compiler, vertexLibrary: library, label: "mokume.solid-stroke-shadow",
            vertexFunctionName: Self.solidStrokeVertexFunctionName)
        self.shadowState = try Self.makeDepthOnlyState(
            compiler: compiler, vertexLibrary: library, label: "mokume.shadow",
            vertexFunctionName: Self.solidVertexFunctionName)
        // 基本図形の組 (旗の組 12 × 混ぜ方 3 列) は使うときに 1 本ずつ組む (#3114)。
        // ここで組むのは既定の描き方の 1 本だけ
        let defaultKey = Self.defaultFormKey
        self.formPipelines = Mutex([
            defaultKey: try Self.makeFormState(
                compiler: compiler, vertexLibrary: library, pixelFormat: pixelFormat,
                key: defaultKey)
        ])

        let flat = MTLDepthStencilDescriptor()
        flat.label = "mokume.depth.flat"
        flat.depthCompareFunction = .always
        flat.isDepthWriteEnabled = false
        self.flatDepthState = gpu.device.makeDepthStencilState(descriptor: flat)

        let solid = MTLDepthStencilDescriptor()
        solid.label = "mokume.depth.solid"
        solid.depthCompareFunction = .lessEqual
        solid.isDepthWriteEnabled = true
        self.solidDepthState = gpu.device.makeDepthStencilState(descriptor: solid)

        let replacing = MTLDepthStencilDescriptor()
        replacing.label = "mokume.depth.replace"
        replacing.depthCompareFunction = .always
        replacing.isDepthWriteEnabled = true
        self.replaceDepthState = gpu.device.makeDepthStencilState(descriptor: replacing)
    }

    /// 面が自分で持つ引数のテーブル。**面ごとに 1 つ作る** — 共有しない理由は型の説明を参照。
    static func makeArgumentTable(gpu: RenderDevice) throws(RenderFailure) -> any MTL4ArgumentTable {
        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.label = "mokume.shapes.arguments"
        tableDescriptor.maxBufferBindCount = bufferBindCount
        tableDescriptor.maxTextureBindCount = textureBindCount
        do {
            return try gpu.device.makeArgumentTable(descriptor: tableDescriptor)
        } catch {
            throw .argumentTableUnavailable(reason: error.localizedDescription)
        }
    }

    /// 平面の頂点を落とす関数の名前。
    static let flatVertexFunctionName = "shapeVertexMain"
    /// 立体の頂点を落とす関数の名前。
    static let solidVertexFunctionName = "solidVertexMain"
    /// 単位の形の塗りの頂点を落とす関数の名前 (`UnitShape.metal`)。
    static let unitShapeVertexFunctionName = "unitShapeVertexMain"
    static let solidStrokeVertexFunctionName = "solidStrokeVertexMain"
    /// 三角形の経路の断片の名前 (下地を読む側)。
    static let flatFragmentFunctionName = "mokume_fragmentMain"
    /// 三角形の経路の断片の名前 (**下地を読まない側** — 重ねる列)。
    static let flatDirectFragmentFunctionName = "mokume_fragmentDirect"
    /// 三角形の経路の断片の名前 (**下地を読まない側** — 置き換える列)。
    ///
    /// 三角形の図形は塗る所だけを覆うので捨てる所が無いが、**字は字形の外接矩形に余白を
    /// 付けた四角**として置かれ、字形の外が余白になる。置き換える列でそこを書くと下地が
    /// 抜けるので、字の焼き場を読む列に限って字形の被覆 0 を捨てる
    /// ([#1557](https://github.com/mokume-metal/mokume/issues/1557))。どの列かは
    /// ``glyphPageBufferIndex`` の口で渡す。
    static let flatReplaceFragmentFunctionName = "mokume_fragmentReplace"
    /// 基本図形のクアッドを置く頂点関数の名前。
    static let formVertexFunctionName = "formVertexMain"
    /// 基本図形を距離関数で塗る断片の名前 (下地を読む側)。
    static let formFragmentFunctionName = "mokume_formFragment"
    /// 基本図形を距離関数で塗る断片の名前 (**重ねる列** — 下地を読まず、捨てもしない)。
    static let formBlendFragmentFunctionName = "mokume_formFragmentBlend"
    /// 基本図形を距離関数で塗る断片の名前 (**置き換える列** — 下地を読まず、余白は捨てる)。
    static let formReplaceFragmentFunctionName = "mokume_formFragmentReplace"

    /// 利用者の断片で塗るパイプラインを組む。**組み込みと同じく混ぜ方ごとに 3 本**。
    ///
    /// 組み込みだけを固定機能のブレンドへ載せると、同じ `paint` を書いても経路で速さが
    /// 変わる — 「組み込みも利用者の断片も同じ合成を通る」(`Common.metal`) を、速さの
    /// 側でも保つ。
    func makeStates(
        fragmentLibrary: any MTLLibrary, label: String,
        vertexFunctionName: String = ShapePipeline.flatVertexFunctionName
    ) throws(RenderFailure) -> BlendStates {
        try Self.makeBlendStates(
            compiler: compiler, vertexLibrary: vertexLibrary(for: vertexFunctionName),
            fragmentLibrary: fragmentLibrary,
            pixelFormat: pixelFormat, label: label, vertexFunctionName: vertexFunctionName)
    }

    /// ``makeStates(fragmentLibrary:label:vertexFunctionName:)`` を、断片のライブラリが出来る前に
    /// 用意する。裏で組む経路 (``ShaderBox``・[#2365]) が使い、組み方は同じ 3 本である。
    ///
    /// [#2365]: https://github.com/mokume-metal/mokume/issues/2365
    func statesJob(
        label: String, vertexFunctionName: String = ShapePipeline.flatVertexFunctionName
    ) -> StatesJob {
        StatesJob(
            compiler: compiler, vertexLibrary: vertexLibrary(for: vertexFunctionName),
            plans: Self.blendPlans(
                pixelFormat: pixelFormat, label: label, vertexFunctionName: vertexFunctionName))
    }

    /// 頂点関数を持つライブラリ。単位の形の頂点関数だけが別のライブラリにある。
    private func vertexLibrary(for vertexFunctionName: String) -> any MTLLibrary {
        vertexFunctionName == Self.unitShapeVertexFunctionName ? unitShapeLibrary : vertexLibrary
    }

    /// 同じ絵を描く 3 本を組む (``BlendStates``)。
    ///
    /// 断片の名前を渡さなければ、三角形の経路の入口 (`mokume_fragmentMain` /
    /// `mokume_fragmentDirect` / `mokume_fragmentReplace`) を使う — 利用者の断片もここから組む。
    private static func makeBlendStates(
        compiler: any MTL4Compiler, vertexLibrary: any MTLLibrary,
        fragmentLibrary: any MTLLibrary, pixelFormat: MTLPixelFormat, label: String,
        vertexFunctionName: String,
        fragmentFunctionName: String = ShapePipeline.flatFragmentFunctionName,
        blendFragmentFunctionName: String = ShapePipeline.flatDirectFragmentFunctionName,
        replaceFragmentFunctionName: String = ShapePipeline.flatReplaceFragmentFunctionName,
        formFlags: UInt32? = nil
    ) throws(RenderFailure) -> BlendStates {
        let built = try StatesJob(
            compiler: compiler, vertexLibrary: vertexLibrary,
            plans: blendPlans(
                pixelFormat: pixelFormat, label: label, vertexFunctionName: vertexFunctionName,
                fragmentFunctionName: fragmentFunctionName,
                blendFragmentFunctionName: blendFragmentFunctionName,
                replaceFragmentFunctionName: replaceFragmentFunctionName, formFlags: formFlags)
        ).makeNow(fragmentLibrary: fragmentLibrary)
        return BlendStates(built)
    }

    /// 基本図形のパイプライン 1 本をその場で組む。組み方は 3 本一組のときと同じ ``blendPlans`` を通り、
    /// 旗の組と列だけを選ぶ。
    private static func makeFormState(
        compiler: any MTL4Compiler, vertexLibrary: any MTLLibrary, pixelFormat: MTLPixelFormat,
        key: FormKey
    ) throws(RenderFailure) -> any MTLRenderPipelineState {
        let plans = blendPlans(
            pixelFormat: pixelFormat, label: "mokume.forms.\(key.flags)",
            vertexFunctionName: formVertexFunctionName,
            fragmentFunctionName: formFragmentFunctionName,
            blendFragmentFunctionName: formBlendFragmentFunctionName,
            replaceFragmentFunctionName: formReplaceFragmentFunctionName, formFlags: key.flags)
        return try plans[key.column.planIndex].makeNow(
            compiler: compiler, vertexLibrary: vertexLibrary, fragmentLibrary: vertexLibrary)
    }

    /// 3 本の組み方。`composite`・`blend`・`replace` の順 (``BlendStates/init(_:)`` が読む順)。
    private static func blendPlans(
        pixelFormat: MTLPixelFormat, label: String, vertexFunctionName: String,
        fragmentFunctionName: String = ShapePipeline.flatFragmentFunctionName,
        blendFragmentFunctionName: String = ShapePipeline.flatDirectFragmentFunctionName,
        replaceFragmentFunctionName: String = ShapePipeline.flatReplaceFragmentFunctionName,
        formFlags: UInt32? = nil
    ) -> [StatePlan] {
        [
            plan(
                label: label, vertexFunctionName: vertexFunctionName,
                fragmentFunctionName: fragmentFunctionName, sourceOver: false,
                formFlags: formFlags, pixelFormat: pixelFormat),
            plan(
                label: "\(label).blend", vertexFunctionName: vertexFunctionName,
                fragmentFunctionName: blendFragmentFunctionName, sourceOver: true,
                formFlags: formFlags, pixelFormat: pixelFormat),
            plan(
                label: "\(label).replace", vertexFunctionName: vertexFunctionName,
                fragmentFunctionName: replaceFragmentFunctionName, sourceOver: false,
                formFlags: formFlags, pixelFormat: pixelFormat),
        ]
    }

    /// 塗りの有無を渡す function constant の番号 (シェーダ側の `kFormHasFill`)。
    static let formHasFillConstantIndex = 0
    /// 輪郭の有無を渡す function constant の番号 (シェーダ側の `kFormHasStroke`)。
    static let formHasStrokeConstantIndex = 1
    /// 1 画素より細い塗りを含むかを渡す function constant の番号 (シェーダ側の `kFormHasThinFill`)。
    static let formHasThinFillConstantIndex = 2
    /// 縁が画素の軸に斜めになりうる形を含むかを渡す function constant の番号 (シェーダ側の
    /// `kFormHasObliqueEdge`・#2991)。
    static let formHasObliqueEdgeConstantIndex = 3
    /// 光と周囲を受けうるかを渡す function constant の番号 (シェーダ側の `kShapeLitValue`)。
    /// 利用者の断片が宣言する番号と重ならないよう、大きく取ってある。
    static let shapeLitConstantIndex = 65000

    /// その頂点関数で組む断片に、光と周囲の枝を残すか ([#1778])。
    ///
    /// **`false` は枝を原稿から外す。** 平面と立体の輪郭は向きを 0 で出し、光・周囲・
    /// 背景の旗も持たない列なので、枝は必ず偽になる — 外しても色の式は同じで、居るだけの
    /// 費用だけが消える (面を覆う半透明のクアッド 40 枚で GPU 時間 −35%)。
    ///
    /// **`true` は枝を残す。** 立体の塗りは光・周囲・背景 (`Canvas.replaceSurface(with:)` の
    /// 置き換える列) のすべてを通るので枝が要る。知らない頂点関数も同じく残す側に倒す —
    /// 外すのは「必ず偽」と言える関数に限る。
    ///
    /// **三角形の経路の断片は、どちらの値でも必ず特化して組む。** function constant を
    /// 読む関数は、値を渡さない記述のままではパイプラインにできない (Metal の検証層が
    /// 「特化した関数を使え」と断る — 実測)。
    ///
    /// [#1778]: https://github.com/mokume-metal/mokume/issues/1778
    static func shapeLit(forVertexFunction name: String) -> Bool {
        switch name {
        case flatVertexFunctionName, solidStrokeVertexFunctionName: false
        default: true
        }
    }

    /// 断片を特化する値。**渡さない値は `nil`** で、``specialized(_:_:)`` はそれを決めない。
    struct FragmentConstants: Equatable {
        /// 基本図形の断片へ渡す旗の組 (`kFormHas*`)。
        var formFlags: UInt32?
        /// 三角形の経路の断片へ渡す光の有無 (`kShapeLitValue`)。
        var lit: Bool?
    }

    /// その列の断片へ渡す特化の値。**光の有無を決めるのはここだけ**で、``makeState`` は
    /// 返した値をそのまま特化に渡す ([#2293])。
    ///
    /// 光の枝を外し損ねても色は変わらず遅くなるだけなので、絵の検査では捕まらない。
    /// 決める箇所を 1 つにして、`UnlitFragmentTests` がここを見る。
    ///
    /// - 基本図形の断片 (`formFlags` あり) は旗だけを受け取り、`kShapeLitValue` を読まない
    /// - 三角形の経路の断片は光の有無だけを受け取り、`kFormHas*` を読まない
    ///   (値は ``shapeLit(forVertexFunction:)``)
    ///
    /// [#2293]: https://github.com/mokume-metal/mokume/issues/2293
    static func fragmentConstants(
        vertexFunctionName: String, formFlags: UInt32?
    ) -> FragmentConstants {
        FragmentConstants(
            formFlags: formFlags,
            lit: formFlags == nil ? shapeLit(forVertexFunction: vertexFunctionName) : nil)
    }

    /// 断片を旗の組と光の有無で特化する記述。
    ///
    /// **渡さない値は決めない** — 三角形の経路の断片は `kFormHas*` を読まないので旗を
    /// 渡す先が無く、基本図形の断片は `kShapeLitValue` を読まないので光の有無を渡す先が
    /// 無い。どちらも無ければ特化せずに元の記述を返す。
    ///
    /// ## `specializedName` は渡さない
    ///
    /// **特化した関数に名前を付けない。渡すなら C の識別子 (`[A-Za-z_][A-Za-z0-9_]*`)
    /// に限る。** そこから外れた綴りを渡すと、**パイプラインの作成は成功したまま断片が
    /// 1 度も走らなくなる** — エラーも警告も返らず、検証層も黙る。症状は「その列の図形が
    /// 画面から消える」だけで、原因へ辿る手掛かりが 1 つも残らない ([#776])。
    ///
    /// 断片段だけが黙るのは、**断片を持たないパイプラインが合法だから**である
    /// (``makeDepthOnlyState`` がそれを組んでいる)。頂点段・計算段なら同じ誤りは
    /// 「関数が要る」の表明に当たって落ちるが、その表明文も名前については何も言わない。
    ///
    /// 名前は飾りの札ではなく、**特化した関数に付け直す新しい名前**である — Metal 3 の
    /// 同名の口 (`MTLFunctionDescriptor.specializedName`) がそう書いている。Metal 4 の
    /// 側は「optional な名前を割り当てる」としか書いておらず、**綴りへの要求はどこにも
    /// 書かれていない** (書かれていないとおり任意の名前を許すべきなのか、識別子に限る
    /// のが仕様なのかは決められていない。Apple への報告の文面は #776 にある)。
    ///
    /// 読める札が欲しいだけなら、パイプラインの `label` が既にそれを持っている
    /// (`mokume.forms.1` など)。分かった振る舞いは `SpecializedNameTests` が固定して
    /// いるので、Metal 側が変われば赤で知らせる。
    ///
    /// [#776]: https://github.com/mokume-metal/mokume/issues/776
    nonisolated static func specialized(
        _ function: MTL4LibraryFunctionDescriptor, _ values: [StatePlan.BoolConstant]
    ) -> MTL4FunctionDescriptor {
        guard !values.isEmpty else { return function }
        let constants = MTLFunctionConstantValues()
        for value in values {
            var flag = value.value
            constants.setConstantValue(&flag, type: .bool, index: value.index)
        }

        let descriptor = MTL4SpecializedFunctionDescriptor()
        descriptor.functionDescriptor = function
        descriptor.constantValues = constants
        return descriptor
    }

    /// 特化の値を、渡す番号と組にして並べる (``specialized(_:_:)`` へ渡す形)。
    private static func specializationValues(
        _ constants: FragmentConstants
    ) -> [StatePlan.BoolConstant] {
        var values: [StatePlan.BoolConstant] = []
        if let formFlags = constants.formFlags {
            values.append(.init(index: formHasFillConstantIndex, value: (formFlags & FormInstance.fillsFlag) != 0))
            values.append(.init(index: formHasStrokeConstantIndex, value: (formFlags & FormInstance.strokesFlag) != 0))
            values.append(.init(index: formHasThinFillConstantIndex, value: (formFlags & FormInstance.thinFillsFlag) != 0))
            values.append(.init(index: formHasObliqueEdgeConstantIndex, value: (formFlags & FormInstance.obliqueEdgesFlag) != 0))
        }
        if let lit = constants.lit {
            values.append(.init(index: shapeLitConstantIndex, value: lit))
        }
        return values
    }

    /// パイプライン 1 本の組み方。**main で解いた平たい値だけを持つ** ので、裏の糸でも記述子を
    /// 組める ([#2365])。
    ///
    /// 記述子は関数の記述を代入の時点で写し取る (`copy`) ので、ライブラリが出来る前に組んで
    /// おいて後から差すことはできない。裏で組む経路は、ライブラリが出来た後にここから組む。
    /// その場で組む経路も同じここを通る — 組み方を 2 か所に持たない。
    ///
    /// [#2365]: https://github.com/mokume-metal/mokume/issues/2365
    nonisolated struct StatePlan: Sendable {
        /// 特化で渡す真偽の値 1 つ。
        struct BoolConstant: Sendable, Equatable {
            let index: Int
            let value: Bool
        }

        let label: String
        let vertexFunctionName: String
        /// 断片の名前。`nil` なら奥行きだけを書く (色の面も宣言しない)。
        let fragmentFunctionName: String?
        let specialization: [BoolConstant]
        let sourceOver: Bool
        let pixelFormat: MTLPixelFormat

        func descriptor(
            vertexLibrary: any MTLLibrary, fragmentLibrary: any MTLLibrary
        ) -> MTL4RenderPipelineDescriptor {
            let vertexFunction = MTL4LibraryFunctionDescriptor()
            vertexFunction.name = vertexFunctionName
            vertexFunction.library = vertexLibrary

            let descriptor = MTL4RenderPipelineDescriptor()
            descriptor.label = label
            descriptor.vertexFunctionDescriptor = vertexFunction
            guard let fragmentFunctionName else {
                descriptor.fragmentFunctionDescriptor = nil
                return descriptor
            }

            let fragmentFunction = MTL4LibraryFunctionDescriptor()
            fragmentFunction.name = fragmentFunctionName
            fragmentFunction.library = fragmentLibrary
            // 基本図形の断片は光の有無を読まず、三角形の経路の断片は旗を読まない
            descriptor.fragmentFunctionDescriptor = ShapePipeline.specialized(
                fragmentFunction, specialization)


            // **固定機能のブレンドを使うのは、乗算済みの source-over だけ。** 色は
            // アルファ乗算済みなので ([ADR-0011] 決定 4)、重ねるのは
            // `source + destination × (1 − source.a)` の 1 本で、係数の組
            // (`one` / `oneMinusSourceAlpha`) がそのままこの式になる — 断片が書いていた
            // 式と一致するので、割ったことでアルファの扱いがばらつく余地は無い。
            //
            // 残りの混ぜ方は係数の組では表せないので、今までどおり断片が下地を読んで
            // 混ぜる (`mokume_composite`)。
            //
            // [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = pixelFormat
            if sourceOver {
                attachment.blendingState = .enabled
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            } else {
                attachment.blendingState = .disabled
            }
            return descriptor
        }

        /// その場で組む。
        func makeNow(
            compiler: any MTL4Compiler, vertexLibrary: any MTLLibrary,
            fragmentLibrary: any MTLLibrary
        ) throws(RenderFailure) -> any MTLRenderPipelineState {
            let descriptor = descriptor(vertexLibrary: vertexLibrary, fragmentLibrary: fragmentLibrary)
            do {
                return try compiler.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                throw .pipelineUnavailable(reason: error.localizedDescription)
            }
        }

        /// 裏で組む。組んでいる間、呼んだ側の糸を塞がない。
        func make(
            compiler: any MTL4Compiler, vertexLibrary: any MTLLibrary,
            fragmentLibrary: any MTLLibrary
        ) async throws(RenderFailure) -> any MTLRenderPipelineState {
            let descriptor = descriptor(vertexLibrary: vertexLibrary, fragmentLibrary: fragmentLibrary)
            do {
                return try await compiler.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                throw .pipelineUnavailable(reason: error.localizedDescription)
            }
        }
    }

    /// 混ぜ方ごとの 3 本を、利用者の断片のライブラリが出来てから組む仕事 ([#2365])。
    ///
    /// [#2365]: https://github.com/mokume-metal/mokume/issues/2365
    nonisolated struct StatesJob: Sendable {
        let compiler: any MTL4Compiler
        let vertexLibrary: any MTLLibrary
        /// `composite`・`blend`・`replace` の順。
        let plans: [StatePlan]

        func makeNow(fragmentLibrary: any MTLLibrary) throws(RenderFailure) -> BuiltStates {
            var states: [any MTLRenderPipelineState] = []
            for plan in plans {
                states.append(try plan.makeNow(
                    compiler: compiler, vertexLibrary: vertexLibrary, fragmentLibrary: fragmentLibrary))
            }
            return BuiltStates(states: states)
        }

        func make(fragmentLibrary: any MTLLibrary) async throws(RenderFailure) -> BuiltStates {
            var states: [any MTLRenderPipelineState] = []
            for plan in plans {
                states.append(try await plan.make(
                    compiler: compiler, vertexLibrary: vertexLibrary, fragmentLibrary: fragmentLibrary))
            }
            return BuiltStates(states: states)
        }
    }

    /// ``StatesJob`` が組んだ 3 本。main で ``BlendStates`` に収める。
    nonisolated struct BuiltStates: Sendable {
        let states: [any MTLRenderPipelineState]
    }

    private static func plan(
        label: String, vertexFunctionName: String, fragmentFunctionName: String,
        sourceOver: Bool, formFlags: UInt32?, pixelFormat: MTLPixelFormat
    ) -> StatePlan {
        StatePlan(
            label: label, vertexFunctionName: vertexFunctionName,
            fragmentFunctionName: fragmentFunctionName,
            specialization: specializationValues(
                fragmentConstants(vertexFunctionName: vertexFunctionName, formFlags: formFlags)),
            sourceOver: sourceOver, pixelFormat: pixelFormat)
    }


    /// 奥行きだけを書くパイプラインを組む (影の焼き付け)。
    ///
    /// 断片を渡さないと、ラスタライズと前後判定だけが走る。色の面は 1 つも宣言しない —
    /// 宣言すると、書く断片が無いのに面が付いている形になる。
    private static func makeDepthOnlyState(
        compiler: any MTL4Compiler, vertexLibrary: any MTLLibrary, label: String,
        vertexFunctionName: String
    ) throws(RenderFailure) -> any MTLRenderPipelineState {
        try StatePlan(
            label: label, vertexFunctionName: vertexFunctionName, fragmentFunctionName: nil,
            specialization: [], sourceOver: false, pixelFormat: .invalid
        ).makeNow(compiler: compiler, vertexLibrary: vertexLibrary, fragmentLibrary: vertexLibrary)
    }
}
