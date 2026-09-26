// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import simd

/// 図形を描くためのパイプラインと、資源の受け渡し口。
///
/// この世代の Metal では、シェーダへ資源を渡すのは**引数のテーブル**で、GPU 上の
/// 番地を指す。テーブルの用意とパイプラインの構築をここにまとめる。
///
/// 頂点を組み立てる側は組み込みのものしかない — 利用者が差し替えるのは塗りだけなので、
/// **利用者の断片から作るパイプラインも、頂点側は同じものを使う。**
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

        /// その混ぜ方で描くパイプライン。
        func state(for mode: BlendMode) -> any MTLRenderPipelineState {
            switch mode {
            case .blend: blend
            case .replace: replace
            default: composite
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
    static let bufferBindCount = 12
    /// 引数のテーブルに束ねられる面の数。利用者の面の口が最後に並ぶ。
    static let textureBindCount = surfaceTextureIndex + surfaceCapacity

    /// 組み込みの塗りで描くパイプライン。**混ぜ方ごとに 3 本ある** (``BlendStates``)。
    let states: BlendStates

    /// 立体を組み込みの塗りで描くパイプライン。頂点の落とし方だけが違う。
    let solidStates: BlendStates

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
    /// **1 画素より細い塗りを含むかでも分かれる** (``FormInstance/thinFillsFlag``・[#1477])。
    /// 塗りを持つ組 (旗 1 と 3) にだけ、細い塗りの枝を残した組 (旗 5 と 7) がある。
    ///
    /// [#752]: https://github.com/mokume-metal/mokume/issues/752
    /// [#771]: https://github.com/mokume-metal/mokume/issues/771
    /// [#1477]: https://github.com/mokume-metal/mokume/issues/1477
    private let formStatesByFlags: [UInt32: BlendStates]

    /// 組むパイプラインの旗の組。細い塗りの旗は塗りを持つ組にしか立たない
    /// (``FormInstance/mayHaveThinFill(unitsPerDrawnPixel:)`` が塗りの無い形に「含まない」と答える)。
    static let formFlagCombinations: [UInt32] = [
        FormInstance.fillsFlag, FormInstance.strokesFlag,
        FormInstance.fillsFlag | FormInstance.strokesFlag,
        FormInstance.fillsFlag | FormInstance.thinFillsFlag,
        FormInstance.fillsFlag | FormInstance.strokesFlag | FormInstance.thinFillsFlag,
    ]

    /// その旗の組で描くパイプラインの 3 本組。
    func formStates(for flags: UInt32) -> BlendStates {
        guard let states = formStatesByFlags[flags] else {
            preconditionFailure("no form pipeline was built for the flag combination \(flags)")
        }
        return states
    }

    /// 平面の奥行きの扱い — **常に通し、書かない**。
    ///
    /// 平面は奥行きを持たない挿入レイヤーなので ([ADR-0021] 決定 2)、書かないことで
    /// 後から来た立体の前後関係を汚さない。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    let flatDepthState: (any MTLDepthStencilState)?

    /// 立体の奥行きの扱い — **手前だけを通し、書く**。
    let solidDepthState: (any MTLDepthStencilState)?

    let argumentTable: any MTL4ArgumentTable

    private let vertexLibrary: any MTLLibrary
    private let compiler: any MTL4Compiler
    private let pixelFormat: MTLPixelFormat

    init(gpu: RenderDevice, pixelFormat: MTLPixelFormat) throws(RenderFailure) {
        self.pixelFormat = pixelFormat
        let library = try gpu.shaders.makeShapeLibrary(
            named: "Shapes", body: gpu.shaders.bundledShaderSource(named: "Shapes"))
        self.vertexLibrary = library

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

        self.shadowState = try Self.makeDepthOnlyState(
            compiler: compiler, vertexLibrary: library, label: "mokume.shadow",
            vertexFunctionName: Self.solidVertexFunctionName)
        // 旗の組ごとに 1 組。旗 1 (塗りだけ)・2 (輪郭だけ)・3 (両方) と、塗りを持つ組に
        // 1 画素より細い塗りの枝を残したもの (5・7)
        var formStates: [UInt32: BlendStates] = [:]
        for flags in Self.formFlagCombinations {
            formStates[flags] = try Self.makeBlendStates(
                compiler: compiler, vertexLibrary: library, fragmentLibrary: library,
                pixelFormat: pixelFormat, label: "mokume.forms.\(flags)",
                vertexFunctionName: Self.formVertexFunctionName,
                fragmentFunctionName: Self.formFragmentFunctionName,
                blendFragmentFunctionName: Self.formBlendFragmentFunctionName,
                replaceFragmentFunctionName: Self.formReplaceFragmentFunctionName,
                formFlags: flags)
        }
        self.formStatesByFlags = formStates

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

        let tableDescriptor = MTL4ArgumentTableDescriptor()
        tableDescriptor.label = "mokume.shapes.arguments"
        tableDescriptor.maxBufferBindCount = Self.bufferBindCount
        tableDescriptor.maxTextureBindCount = Self.textureBindCount
        do {
            argumentTable = try gpu.device.makeArgumentTable(descriptor: tableDescriptor)
        } catch {
            throw .argumentTableUnavailable(reason: error.localizedDescription)
        }
    }

    /// 平面の頂点を落とす関数の名前。
    static let flatVertexFunctionName = "shapeVertexMain"
    /// 立体の頂点を落とす関数の名前。
    static let solidVertexFunctionName = "solidVertexMain"
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
            compiler: compiler, vertexLibrary: vertexLibrary, fragmentLibrary: fragmentLibrary,
            pixelFormat: pixelFormat, label: label, vertexFunctionName: vertexFunctionName)
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
        BlendStates(
            composite: try makeState(
                compiler: compiler, vertexLibrary: vertexLibrary,
                fragmentLibrary: fragmentLibrary, pixelFormat: pixelFormat,
                label: label, vertexFunctionName: vertexFunctionName,
                fragmentFunctionName: fragmentFunctionName, formFlags: formFlags),
            blend: try makeState(
                compiler: compiler, vertexLibrary: vertexLibrary,
                fragmentLibrary: fragmentLibrary, pixelFormat: pixelFormat,
                label: "\(label).blend", vertexFunctionName: vertexFunctionName,
                fragmentFunctionName: blendFragmentFunctionName, sourceOver: true,
                formFlags: formFlags),
            replace: try makeState(
                compiler: compiler, vertexLibrary: vertexLibrary,
                fragmentLibrary: fragmentLibrary, pixelFormat: pixelFormat,
                label: "\(label).replace", vertexFunctionName: vertexFunctionName,
                fragmentFunctionName: replaceFragmentFunctionName, formFlags: formFlags))
    }

    /// 塗りの有無を渡す function constant の番号 (シェーダ側の `kFormHasFill`)。
    static let formHasFillConstantIndex = 0
    /// 輪郭の有無を渡す function constant の番号 (シェーダ側の `kFormHasStroke`)。
    static let formHasStrokeConstantIndex = 1
    /// 1 画素より細い塗りを含むかを渡す function constant の番号 (シェーダ側の `kFormHasThinFill`)。
    static let formHasThinFillConstantIndex = 2

    /// 断片を旗の組で特化する記述。
    ///
    /// **渡さない断片は特化しない** — 三角形の経路の断片は `kFormHas*` を読まないので、
    /// 値を渡す先が無い。
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
    private static func specialized(
        _ function: MTL4LibraryFunctionDescriptor, formFlags: UInt32
    ) -> MTL4FunctionDescriptor {
        let values = MTLFunctionConstantValues()
        var hasFill = (formFlags & FormInstance.fillsFlag) != 0
        var hasStroke = (formFlags & FormInstance.strokesFlag) != 0
        var hasThinFill = (formFlags & FormInstance.thinFillsFlag) != 0
        values.setConstantValue(&hasFill, type: .bool, index: formHasFillConstantIndex)
        values.setConstantValue(&hasStroke, type: .bool, index: formHasStrokeConstantIndex)
        values.setConstantValue(&hasThinFill, type: .bool, index: formHasThinFillConstantIndex)

        let descriptor = MTL4SpecializedFunctionDescriptor()
        descriptor.functionDescriptor = function
        descriptor.constantValues = values
        return descriptor
    }

    private static func makeState(
        compiler: any MTL4Compiler, vertexLibrary: any MTLLibrary,
        fragmentLibrary: any MTLLibrary, pixelFormat: MTLPixelFormat, label: String,
        vertexFunctionName: String = ShapePipeline.flatVertexFunctionName,
        fragmentFunctionName: String = "mokume_fragmentMain",
        sourceOver: Bool = false,
        formFlags: UInt32? = nil
    ) throws(RenderFailure) -> any MTLRenderPipelineState {
        let vertexFunction = MTL4LibraryFunctionDescriptor()
        vertexFunction.name = vertexFunctionName
        vertexFunction.library = vertexLibrary

        let fragmentFunction = MTL4LibraryFunctionDescriptor()
        fragmentFunction.name = fragmentFunctionName
        fragmentFunction.library = fragmentLibrary

        let descriptor = MTL4RenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunctionDescriptor = vertexFunction
        descriptor.fragmentFunctionDescriptor =
            formFlags.map { specialized(fragmentFunction, formFlags: $0) } ?? fragmentFunction

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

        do {
            return try compiler.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw .pipelineUnavailable(reason: error.localizedDescription)
        }
    }

    /// 奥行きだけを書くパイプラインを組む (影の焼き付け)。
    ///
    /// 断片を渡さないと、ラスタライズと前後判定だけが走る。色の面は 1 つも宣言しない —
    /// 宣言すると、書く断片が無いのに面が付いている形になる。
    private static func makeDepthOnlyState(
        compiler: any MTL4Compiler, vertexLibrary: any MTLLibrary, label: String,
        vertexFunctionName: String
    ) throws(RenderFailure) -> any MTLRenderPipelineState {
        let vertexFunction = MTL4LibraryFunctionDescriptor()
        vertexFunction.name = vertexFunctionName
        vertexFunction.library = vertexLibrary

        let descriptor = MTL4RenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunctionDescriptor = vertexFunction
        descriptor.fragmentFunctionDescriptor = nil

        do {
            return try compiler.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw .pipelineUnavailable(reason: error.localizedDescription)
        }
    }
}
