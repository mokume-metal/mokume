// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import simd

/// 効果を通すためのパイプラインと、中間の置き場。
///
/// **中間の置き場はここが 1 か所で持つ** ([ADR-0023] 決定 5 — 毎フレーム走る段は
/// フレームごとに新しい置き場を確保しない)。段ごとに持たせると、段数の違う効果を
/// 併用したときに枚数が変わり、変わるたびに確保が走る。
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
final class EffectPipeline {
    /// 利用者が渡した値の口の番号 (シェーダ側の `buffer(0)`)。
    static let valuesBufferIndex = 0
    /// 組み込みの効果に効く設定の口の番号 (シェーダ側の `buffer(1)`)。
    static let controlBufferIndex = 1
    /// 面の大きさと時刻の口の番号 (シェーダ側の `buffer(2)`)。
    static let frameBufferIndex = 2
    /// 入りの絵の口の番号 (シェーダ側の `texture(0)`)。
    static let sourceTextureIndex = 0
    /// 組み合わせる相手の絵の口の番号 (シェーダ側の `texture(1)`)。
    static let pairedTextureIndex = 1
    /// 引数のテーブルに束ねられる置き場の数。上の口の番号はすべてこれより小さい
    /// (`ShaderInterfaceTests` が、入口の関数が宣言する番号と突き合わせる)。
    static let bufferBindCount = 3
    /// 引数のテーブルに束ねられる面の数。
    static let textureBindCount = 2

    /// 入口の関数の名前。**組み込みも利用者の効果も同じ**。
    static let vertexFunctionName = "mokume_effectVertexMain"
    static let fragmentFunctionName = "mokume_effectMain"
    /// 変わった画素だけを重ねる断片の関数の名前 ([#1524])。組み込みの原文 (`Builtin.metal`) にだけある。
    ///
    /// [#1524]: https://github.com/mokume-metal/mokume/issues/1524
    static let keepChangedFunctionName = "mokume_keepChanged"

    /// 1 段ぶんの置き場の間隔 (バイト)。設定 128 / 面 32 / 値の順に詰める。
    ///
    /// 設定の枠は、まとめた段 (``BuiltinEffectKind/fused``) が段ごとの `float4` を並べるために
    /// 広い ([#2371])。間隔は 256 の倍数に保つ (定数の置き場の境)。
    ///
    /// 面は 2 つの `float4` で、段の面の大きさと秒数・出す大きさを持つ (断片が位置と大きさを
    /// 出す画素で受け取るため・#1639)。
    ///
    /// [#2371]: https://github.com/mokume-metal/mokume/issues/2371
    static let passStride = 512
    static let controlOffset = 0
    static let controlSize = 128
    static let frameOffset = 128
    static let frameSize = 32
    static let valuesOffset = 192
    /// 1 つの効果が渡せる値の数。**利用者に見える上限**なので、間隔を広げても変えない。
    static let valueSlotCapacity = 48

    private let gpu: RenderDevice
    private let compiler: any MTL4Compiler
    private let pixelFormat: MTLPixelFormat

    /// 組み込みの効果を通すパイプライン。**種別ごとに特化した 1 本を、初めて使うときに組む**
    /// ([#2371])。13 種を 1 本に詰めると、レジスタの割り当てが最も重い枝で決まり、軽い段まで
    /// 占有率が落ちる。代償は、種別を初めて使うフレームで 1 本ぶん (冷えた状態で約 50 ms・
    /// [#2365]) 止まること — [#1795] で受けた交換である。
    ///
    /// [#1795]: https://github.com/mokume-metal/mokume/issues/1795
    /// [#2365]: https://github.com/mokume-metal/mokume/issues/2365
    /// [#2371]: https://github.com/mokume-metal/mokume/issues/2371
    private var builtinStates: [BuiltinEffectKind: any MTLRenderPipelineState] = [:]
    /// 全種入りの 1 本 (``generalBuiltinState()``)。検査が頼んだときだけ組む。
    private var generalBuiltin: (any MTLRenderPipelineState)?
    /// 偽にすると、特化せず全種入りの 1 本で走る。**検査が画素を突き合わせるためにある**で、
    /// 本番の経路は触らない。
    var specializesBuiltinEffects = true
    /// 偽にすると、隣り合う画素ごとの効果をまとめず、段ごとに別のパスで描く
    /// (``Effect/fusingPixelStages(_:)``)。**検査と計測が前後を突き合わせるためにある**で、
    /// 本番の経路は触らない。
    var fusesPixelStages = true
    /// 種別ごとのパイプラインを組んだ回数。**使った種別の数で止まる**ことを検査が見る。
    private(set) var builtinStatesBuilt = 0
    /// 組み込みの原文を組んだもの。変わった画素だけを重ねるパイプライン
    /// (``keepChangedState()``) を、頼まれたときにここから組む。
    private let builtinLibrary: any MTLLibrary
    /// 変わった画素だけを重ねるパイプライン。**頼まれてはじめて組む** ([#1524])。
    ///
    /// [#1524]: https://github.com/mokume-metal/mokume/issues/1524
    private var keepChangedStorage: (any MTLRenderPipelineState)?
    /// 変わった画素だけを重ねる段のテーブル。**段の採番から取らない** ([#1524]) — この段は描き切り
    /// だけでなく出力段からも積まれ、出力段の投入は段の採番を 0 へ戻さない。束ねる面はいつも同じ
    /// 2 枚 (描く先と、変える前の絵) なので、1 枚を使い回しても束ね先は変わらない。
    ///
    /// [#1524]: https://github.com/mokume-metal/mokume/issues/1524
    private var keepChangedTableStorage: (any MTL4ArgumentTable)?
    /// 止まっている間に控えへ描くときの奥行き ([#1524])。描く先の奥行きをパスの前に写して使う。
    ///
    /// [#1524]: https://github.com/mokume-metal/mokume/issues/1524
    private var carryDepthStorage: StageImage?
    /// 控えへ描くときの奥行きを作った回数。**止まっている間に図形を描き切らない面では 0 のまま。**
    private(set) var carryDepthsBuilt = 0

    /// 段ごとの引数のテーブル。**段ごとに別のものを使う** — 1 枚を使い回して番地を
    /// 書き換えると、まだ走っていない段の束ね先まで変わる (計算の段と同じ理由)。
    private var tablePool: ArgumentTablePool
    /// テーブルを作った回数。**毎フレーム確保していないことを検査が数で見る**
    /// (``ArgumentTablePool/built``)。
    var tablesBuilt: Int { tablePool.built }

    /// 段ごとの設定・面・値を置く領域。**フレームごとに書くので環に載る** ([#754])。
    ///
    /// 載る環は `Canvas` のものである — 段は描き切りと同じコマンドに積まれ、**同じ投入が
    /// 読む**ので、待つ相手も同じでよい。
    ///
    /// [#754]: https://github.com/mokume-metal/mokume/issues/754
    private let passStorage: GrowableBuffer
    /// このフレームで使う置き場。``reservePasses(_:)`` が決める。
    ///
    /// **段を 1 つでも組む前に必ず ``reservePasses(_:)`` を通る** (効果の並びも拡大も
    /// そうしている)。通らずにここを読むと、前のスロットの置き場を指したままになる。
    private(set) var passBuffer: any MTLBuffer
    /// 置き場を取り直した回数。**長回しで増えないことを検査が見る。**
    var buffersBuilt: Int { passStorage.reallocations }

    /// 中間の絵。**使い回す**ので、フレームごとには作らない。
    ///
    /// 色だけの絵 (``StageImage``) である。描画先と同じ型にすると、段が見ない奥行きの
    /// 面が 1 枚ずつ付いてくる (#753)。
    private var scratch: [StageImage] = []
    /// 中間の絵を確保した回数。
    private(set) var scratchBuilt = 0
    /// 縮めた中間の絵。`reduced[level - 1]` が 1 / 2^level の絵の列 (#755)。
    private var reduced: [[StageImage]] = Array(repeating: [], count: maxReductionLevel)
    /// 縮めた絵を確保した回数。**長回しで増えないことを検査が見る。**
    private(set) var reducedBuilt = 0
    /// 効果を通す前の絵の控え ([#1469])。**効果を頼まれてはじめて作り、使い回す**
    /// ([ADR-0023] 決定 5)。
    ///
    /// 効果の並びは描く先を入りの絵として読み、最後の段がこれへ効果を通した絵を書く。書けたら、描く先と
    /// **面を取り替える** (``Canvas/exchangeTargetWithCarry()``・[#2388]) — 取り替えた後の描く先が効果を
    /// 通した絵で、これには効果を通す前の絵が残る。次のフレームの入りは、これを描く先へ戻した絵になる
    /// (``Canvas`` の描き切りが、もう一度取り替える)。
    ///
    /// **面は描く先と入れ替わるので、「控えの面」は固定していない。** 面を持ち歩く側は、控えの面を値で
    /// 写し取らない (``HeldTexture``・``RenderTarget/exchangePartner``)。
    ///
    /// [#1469]: https://github.com/mokume-metal/mokume/issues/1469
    /// [#2388]: https://github.com/mokume-metal/mokume/issues/2388
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    private var carryStorage: StageImage?
    /// 控えを作った回数。**効果を頼まない面では 0 のまま**であることを検査が見る — 細かさを
    /// 下げた面は拡大のためにこのパイプラインが立つので、パイプラインの有無では見られない。
    private(set) var carriesBuilt = 0
    /// 作ってある控え。**作らずに覗く** (戻す側は、控えが無ければ戻すものも無い)。
    var existingCarry: StageImage? { carryStorage }
    /// 画素を書き戻す前の描く先の写し ([#1524])。
    ///
    /// 効果を通したフレームの後、次のフレームより前 (止まっている間のコールバック) に書いた画素を
    /// 書き戻すたびに、その直前にここへ写す。書き戻した後の描く先と比べ、**違う画素だけ**を効果を
    /// 通す前の絵 (``carry()``) へ写す。止まっている間に画素を書き戻したときにはじめて作り、
    /// 使い回す ([ADR-0023] 決定 5)。
    ///
    /// [#1524]: https://github.com/mokume-metal/mokume/issues/1524
    private var pictureBeforeChangeStorage: StageImage?
    /// 描く先を変える前の絵の控えを作った回数。**止まっている間に描く先を変えない面では 0 の
    /// まま**であることを検査が見る。
    private(set) var picturesBeforeChangeBuilt = 0
    /// いちばん小さい段。1/8 より下は持たない (半径から段を選ぶ側 ``Effect/reductionLevel(for:)`` も
    /// ここで止まる)。
    static let maxReductionLevel = 3
    private let width: Int
    private let height: Int

    init(
        gpu: RenderDevice, ring: FrameRing, width: Int, height: Int, pixelFormat: MTLPixelFormat
    ) throws(RenderFailure) {
        self.gpu = gpu
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.passStorage = GrowableBuffer(
            gpu: gpu, ring: ring, stride: Self.passStride, minimumCapacity: 8,
            label: "mokume.effect.passes")

        let compiler = try gpu.shaders.compiler()
        self.compiler = compiler

        // 組み込みのライブラリは、この GPU で 1 度だけ組む (面ごとに組み直さない)
        self.builtinLibrary = try gpu.shaders.builtinEffectLibrary()

        passBuffer = try passStorage.buffer(holding: 8)
        tablePool = ArgumentTablePool(
            gpu: gpu, label: "mokume.effect.arguments",
            bufferBindCount: Self.bufferBindCount, textureBindCount: Self.textureBindCount)
    }

    /// 利用者の効果のパイプラインを組む。
    func makeState(library: any MTLLibrary, label: String) throws(RenderFailure)
        -> any MTLRenderPipelineState
    {
        try stateJob(label: label).makeNow(library: library)
    }

    /// ``makeState(library:label:)`` を、断片のライブラリが出来る前に用意する。裏で組む経路
    /// (``ShaderBox``・[#2365]) が使う。
    ///
    /// [#2365]: https://github.com/mokume-metal/mokume/issues/2365
    func stateJob(label: String, fragment: String = EffectPipeline.fragmentFunctionName) -> StateJob {
        StateJob(
            compiler: compiler, pixelFormat: pixelFormat, label: label,
            vertexFunctionName: Self.vertexFunctionName, fragmentFunctionName: fragment)
    }

    /// その種別に特化した、組み込みの効果を通すパイプライン。無ければ組む ([#2371])。
    ///
    /// [#2371]: https://github.com/mokume-metal/mokume/issues/2371
    func builtinState(for kind: BuiltinEffectKind) throws(RenderFailure) -> any MTLRenderPipelineState {
        guard specializesBuiltinEffects else { return try generalBuiltinState() }
        if let state = builtinStates[kind] { return state }
        let made = try StateJob(
            compiler: compiler, pixelFormat: pixelFormat,
            label: "mokume.effect.builtin.\(kind.metalName)",
            vertexFunctionName: Self.vertexFunctionName,
            fragmentFunctionName: Self.fragmentFunctionName,
            specializedKind: kind.rawValue
        ).makeNow(library: builtinLibrary)
        builtinStates[kind] = made
        builtinStatesBuilt += 1
        return made
    }

    /// 種別に特化しない、全種入りの 1 本。**検査だけが通る** — 特化したパイプラインと同じ画素を
    /// 出すことを、種別ごとに突き合わせる (``specializesBuiltinEffects``)。
    private func generalBuiltinState() throws(RenderFailure) -> any MTLRenderPipelineState {
        if let generalBuiltin { return generalBuiltin }
        let made = try StateJob(
            compiler: compiler, pixelFormat: pixelFormat, label: "mokume.effect.builtin.general",
            vertexFunctionName: Self.vertexFunctionName,
            fragmentFunctionName: Self.fragmentFunctionName,
            specializedKind: StateJob.anyKind
        ).makeNow(library: builtinLibrary)
        generalBuiltin = made
        return made
    }

    /// 変わった画素だけを重ねるパイプライン。無ければ組む ([#1524])。
    ///
    /// 読むのは入りの口 (描く先) と相手の口 (変える前の絵) の 2 枚で、同じ値の画素は捨てる。
    /// 書き込む先は前の内容を読む (``Canvas`` の `encodeKeepChanged(into:)`) ので、捨てた画素には
    /// 効果を通す前の絵が残る。
    ///
    /// [#1524]: https://github.com/mokume-metal/mokume/issues/1524
    func keepChangedState() throws(RenderFailure) -> any MTLRenderPipelineState {
        if let keepChangedStorage { return keepChangedStorage }
        let made = try stateJob(
            label: "mokume.effect.keepChanged", fragment: Self.keepChangedFunctionName
        ).makeNow(library: builtinLibrary)
        keepChangedStorage = made
        return made
    }

    /// 1 本の組み方。**main で決めた値だけを持つ** ので、裏の糸でも組める (``ShapePipeline/StatePlan``
    /// と同じ理由・[#2365])。
    ///
    /// [#2365]: https://github.com/mokume-metal/mokume/issues/2365
    nonisolated struct StateJob: Sendable {
        let compiler: any MTL4Compiler
        let pixelFormat: MTLPixelFormat
        let label: String
        let vertexFunctionName: String
        let fragmentFunctionName: String
        /// 組み込みの効果の種別 (``BuiltinEffectKind``)。立てると断片をその種別へ特化する
        /// (`Builtin.metal` の `kEffectKindValue`)。利用者の効果は立てない。
        var specializedKind: UInt32?

        /// `kEffectKindValue` の関数定数の番号 (`Builtin.metal`)。
        static let kindConstantIndex = 65001
        /// 特化しない印 (`kEffectKindAny`)。全種入りの 1 本を組むときに渡す。
        static let anyKind: UInt32 = 0xFFFF_FFFF

        private func descriptor(library: any MTLLibrary) -> MTL4RenderPipelineDescriptor {
            let vertexFunction = MTL4LibraryFunctionDescriptor()
            vertexFunction.name = vertexFunctionName
            vertexFunction.library = library

            let fragmentFunction = MTL4LibraryFunctionDescriptor()
            fragmentFunction.name = fragmentFunctionName
            fragmentFunction.library = library

            let descriptor = MTL4RenderPipelineDescriptor()
            descriptor.label = label
            descriptor.vertexFunctionDescriptor = vertexFunction
            if let specializedKind {
                let constants = MTLFunctionConstantValues()
                var kind = specializedKind
                constants.setConstantValue(&kind, type: .uint, index: Self.kindConstantIndex)
                let specialized = MTL4SpecializedFunctionDescriptor()
                specialized.functionDescriptor = fragmentFunction
                specialized.constantValues = constants
                descriptor.fragmentFunctionDescriptor = specialized
            } else {
                descriptor.fragmentFunctionDescriptor = fragmentFunction
            }
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = pixelFormat
            // **混ぜない。** 段は入りの絵を丸ごと受け取って出りの絵を丸ごと書くので、
            // 下地と混ぜる余地が無い (混ぜたい効果は自分で相手を読む)
            attachment.blendingState = .disabled
            return descriptor
        }

        /// その場で組む。
        func makeNow(library: any MTLLibrary) throws(RenderFailure) -> any MTLRenderPipelineState {
            do {
                return try compiler.makeRenderPipelineState(descriptor: descriptor(library: library))
            } catch {
                throw .pipelineUnavailable(reason: error.localizedDescription)
            }
        }

        /// 裏で組む。組んでいる間、呼んだ側の糸を塞がない。
        func make(library: any MTLLibrary) async throws(RenderFailure) -> any MTLRenderPipelineState {
            do {
                return try await compiler.makeRenderPipelineState(descriptor: descriptor(library: library))
            } catch {
                throw .pipelineUnavailable(reason: error.localizedDescription)
            }
        }
    }

    /// `index` 段目のテーブル。足りなければ伸ばす (``ArgumentTablePool``)。
    func table(at index: Int) throws(RenderFailure) -> any MTL4ArgumentTable {
        try tablePool.table(at: index)
    }

    /// 段の数だけ置き場を確保する。**足りているうちは取り直さない。**
    ///
    /// **このフレームのスロットを選び直す口でもある。** 環は描き切りごとに進むので、
    /// 段を組む前にここを通って ``passBuffer`` を引き直す必要がある。
    func reservePasses(_ count: Int) throws(RenderFailure) {
        passBuffer = try passStorage.buffer(holding: count)
    }

    /// `index` 枚目の中間の絵。足りなければ確保する。
    ///
    /// `level` が 1 以上なら **1 / 2^level に縮めた絵** (#755)。大きなぼかしはそこで回す。
    /// 縮めた絵も段ごとではなくここで 1 か所で持ち、フレームをまたいで使い回す。
    func scratch(at index: Int, level: Int = 0) throws(RenderFailure) -> StageImage {
        precondition(
            level >= 0 && level <= Self.maxReductionLevel, "there is no reduction level \(level)")
        guard level > 0 else {
            while scratch.count <= index {
                // 段は全画素を書くので、塗っておく必要が無い (コマンドの組み立て中なので塗れもしない)
                scratch.append(
                    try StageImage(
                        gpu: gpu, width: width, height: height, startingTransparent: false))
                scratchBuilt += 1
            }
            return scratch[index]
        }
        while reduced[level - 1].count <= index {
            reduced[level - 1].append(
                try StageImage(
                    gpu: gpu, width: Self.reduce(width, by: level),
                    height: Self.reduce(height, by: level), startingTransparent: false))
            reducedBuilt += 1
        }
        return reduced[level - 1][index]
    }

    /// 効果を通す前の絵の控え。無ければ作る。
    ///
    /// 大きさは描く細かさ (中間の絵と同じ)。**中身は、書かれる前に読まれることがある** — 最初の効果を通す
    /// フレームの最後の段が書くまで、控えは何も書かれていない。その投入が打ち切られると、取り替えた
    /// 描く先が (結末が届いて取り替えが戻るまでの間) 書かれていない面を読む (窓・書き出し・同じフレームに
    /// 置いた面)。**組み立ての外で作れるなら塗って作る** (`startingTransparent`・``Canvas/effects(_:)`` が頼む)
    /// ので、読んでも透明な黒である。コマンドを組み立てている最中に作るときは塗れない (その分は、打ち切られ
    /// た最初の効果を通すフレームの間だけ、書かれていない面を読みうる)。
    ///
    /// - Parameter startingTransparent: 作るなら、透明な黒に塗って作るか。組み立ての最中は偽にする。
    func carry(startingTransparent: Bool = false) throws(RenderFailure) -> StageImage {
        if let carryStorage { return carryStorage }
        let made = try StageImage(
            gpu: gpu, width: width, height: height, startingTransparent: startingTransparent)
        carryStorage = made
        carriesBuilt += 1
        return made
    }

    /// 変わった画素だけを重ねる段のテーブル。無ければ作る ([#1524])。
    func keepChangedTable() throws(RenderFailure) -> any MTL4ArgumentTable {
        if let keepChangedTableStorage { return keepChangedTableStorage }
        let descriptor = MTL4ArgumentTableDescriptor()
        descriptor.label = "mokume.effect.keepChanged"
        descriptor.maxBufferBindCount = Self.bufferBindCount
        descriptor.maxTextureBindCount = Self.textureBindCount
        let made: any MTL4ArgumentTable
        do {
            made = try gpu.device.makeArgumentTable(descriptor: descriptor)
        } catch {
            throw .argumentTableUnavailable(reason: error.localizedDescription)
        }
        keepChangedTableStorage = made
        return made
    }

    /// 止まっている間に控えへ描くときの奥行き。無ければ作る ([#1524])。
    ///
    /// 読まれる前に必ず描く先の奥行きから写されるか、パスの頭で消される。
    ///
    /// [#1524]: https://github.com/mokume-metal/mokume/issues/1524
    func carryDepth() throws(RenderFailure) -> StageImage {
        if let carryDepthStorage { return carryDepthStorage }
        let made = try StageImage(
            gpu: gpu, width: width, height: height, startingTransparent: false,
            pixelFormat: RenderTarget.depthFormat)
        carryDepthStorage = made
        carryDepthsBuilt += 1
        return made
    }

    /// 描く先を変える前の絵の控え。無ければ作る ([#1524])。
    ///
    /// 大きさは ``carry()`` と同じ。塗らないのは、読まれる前に必ず描く先から写される (``encodeKeepPicture(into:)``)
    /// うえ、コマンドを組み立てている最中に作られるので塗れもしないため。
    ///
    /// [#1524]: https://github.com/mokume-metal/mokume/issues/1524
    func pictureBeforeChange() throws(RenderFailure) -> StageImage {
        if let pictureBeforeChangeStorage { return pictureBeforeChangeStorage }
        let made = try StageImage(
            gpu: gpu, width: width, height: height, startingTransparent: false)
        pictureBeforeChangeStorage = made
        picturesBeforeChangeBuilt += 1
        return made
    }

    /// 縮めた絵の一辺。**上へ丸める**ので、元の絵の画素を 1 つも切り捨てない。
    static func reduce(_ size: Int, by level: Int) -> Int {
        max(1, (size + (1 << level) - 1) >> level)
    }
}
