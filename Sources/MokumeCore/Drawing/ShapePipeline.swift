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
    /// で特化できる ([#771])。並びは旗 (``FormInstance/fillsFlag`` | `strokesFlag`) から
    /// 1 を引いた番号 — 塗りも輪郭も無い図形は置かれないので 0 は使わない。
    ///
    /// [#752]: https://github.com/mokume-metal/mokume/issues/752
    /// [#771]: https://github.com/mokume-metal/mokume/issues/771
    private let formStatesByFlags: [BlendStates]

    /// その旗の組で描くパイプラインの 3 本組。
    func formStates(for flags: UInt32) -> BlendStates {
        formStatesByFlags[Int(flags) - 1]
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
        let library = try gpu.makeShapeLibrary(
            named: "Shapes", body: gpu.bundledShaderSource(named: "Shapes"))
        self.vertexLibrary = library

        let compilerDescriptor = MTL4CompilerDescriptor()
        compilerDescriptor.label = "mokume.compiler"
        guard let compiler = try? gpu.device.makeCompiler(descriptor: compilerDescriptor) else {
            throw .shaderCompilerUnavailable
        }
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
        // 塗り / 輪郭の有無ごとに 1 組。旗 1 (塗りだけ)・2 (輪郭だけ)・3 (両方)
        var formStates: [BlendStates] = []
        for flags in 1...3 {
            formStates.append(
                try Self.makeBlendStates(
                    compiler: compiler, vertexLibrary: library, fragmentLibrary: library,
                    pixelFormat: pixelFormat, label: "mokume.forms.\(flags)",
                    vertexFunctionName: Self.formVertexFunctionName,
                    fragmentFunctionName: Self.formFragmentFunctionName,
                    blendFragmentFunctionName: Self.formBlendFragmentFunctionName,
                    replaceFragmentFunctionName: Self.formReplaceFragmentFunctionName,
                    formFlags: UInt32(flags)))
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
        tableDescriptor.maxBufferBindCount = 12
        tableDescriptor.maxTextureBindCount = Self.surfaceTextureIndex + Self.surfaceCapacity
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
    /// 三角形の経路の断片の名前 (**下地を読まない側**)。
    ///
    /// 三角形は塗る所だけを覆うので、置き換える列でも捨てる必要が無い — 重ねる列と
    /// 同じ入口で足りる (基本図形の経路は余白を持つので分かれる)。
    static let flatDirectFragmentFunctionName = "mokume_fragmentDirect"
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
    /// `mokume_fragmentDirect`) を使う — 利用者の断片もここから組む。
    private static func makeBlendStates(
        compiler: any MTL4Compiler, vertexLibrary: any MTLLibrary,
        fragmentLibrary: any MTLLibrary, pixelFormat: MTLPixelFormat, label: String,
        vertexFunctionName: String,
        fragmentFunctionName: String = ShapePipeline.flatFragmentFunctionName,
        blendFragmentFunctionName: String = ShapePipeline.flatDirectFragmentFunctionName,
        replaceFragmentFunctionName: String = ShapePipeline.flatDirectFragmentFunctionName,
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
        values.setConstantValue(&hasFill, type: .bool, index: formHasFillConstantIndex)
        values.setConstantValue(&hasStroke, type: .bool, index: formHasStrokeConstantIndex)

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
