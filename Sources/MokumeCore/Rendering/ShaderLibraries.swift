// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// シェーダの原文を読み、組み立てる。組んだもののうち、持ち主をまたいで使うものを抱える。
///
/// ## なぜ描画の土台から出ているのか
///
/// **投入と待ちに要るものを 1 つも使わないからである。** 投入も、待ちも、コマンドの置き場も、
/// 常駐の集合も使わない — ``RenderDevice`` の中核 (投入と待ち) と共有しているものが 1 つも
/// 無い。同じ型に居ると「シェーダを組み立てるには描画の土台の状態が要る」と読めてしまうが、
/// 実際には要らない ([#959](https://github.com/mokume-metal/mokume/issues/959))。
///
/// 転送メソッドを ``RenderDevice`` に残していないのも同じ理由で、残すと**組み立ては
/// あちらの仕事だという読みが残る**。呼ぶ側は `gpu.shaders` を通る。
///
/// ## なぜ状態を持つのか
///
/// **同じ原文を 2 度組まないためである** ([#728])。当初 (#959) は `device` 1 つだけを持つ
/// 値で、`gpu.shaders` は触るたびに作り直されていた。それでは組んだものを抱えておく場所が
/// どこにも無く、`Present` は画面へ差し出す経路 (``PresentPipeline``) と書き出す経路
/// (``OutputPass``) が 1 度ずつ組み、パイプラインの組み立て器 (`MTL4Compiler`) は持ち主
/// ごとに 1 本ずつ、5 本作られていた。
///
/// 持ち主どうしは互いを知らないので、分け合う場所は両方が触る ``RenderDevice`` の側にしか
/// 置けない。**分け合う範囲はこの GPU 1 つである** — 組んだものは組んだ GPU の上でしか
/// 使えないので、型の外 (共有の控え) へは広げない。
///
/// 抱えるのは**同梱の原文から組むもの**と組み立て器だけである。利用者の断片は持ち主
/// (``ShaderBox``) が控え、ここは組むだけ — 利用者の断片を控える話は別に扱う
/// ([#1432](https://github.com/mokume-metal/mokume/issues/1432))。
///
/// ## 原文はビルドに含まれない
///
/// シェーダの原文は資源として運ばれ、走らせてから組み立てる — この道具立てでは原文を
/// ビルドに含める手がないためである。**原文の誤りはここまで来ないと分からない**ので、
/// `make ci-check` が別途ビルド時に組み立てて落とす (`scripts/check-shaders.sh`)。
///
/// [#728]: https://github.com/mokume-metal/mokume/issues/728
final class ShaderLibraries {
    let device: any MTLDevice

    /// 原文を組みに行った回数。名前ごとに数え、**組めなかった回も数える**。
    ///
    /// **同じ原文を 2 度組んでいないことを検査が数で見る** (``ArgumentTablePool/built`` と
    /// 同じ作法)。組めなかった回を数えるのは、同じだけ時間を払うからである。
    private(set) var librariesBuilt: [String: Int] = [:]

    /// 組んだ `Present`。最初に頼まれたときに組む。
    private var present: (any MTLLibrary)?
    /// パイプラインの組み立て器。最初に頼まれたときに作る。
    private var madeCompiler: (any MTL4Compiler)?

    init(device: any MTLDevice) {
        self.device = device
    }

    /// 画面へ差し出す経路と書き出す経路が読む `Present`。**組むのは最初の 1 度だけ。**
    ///
    /// 2 つの経路が同じ断片を読むのは、明るさの曲線と伝達関数を 2 か所に持たないためで
    /// (``OutputPass`` の冒頭)、同じ原文なら組んだものも同じである。
    func presentLibrary() throws(RenderFailure) -> any MTLLibrary {
        if let present { return present }
        let library = try makeLibrary(named: "Present")
        present = library
        return library
    }

    /// パイプラインの組み立て器。**この GPU の上で 1 本だけ作り、全部の持ち主が使う。**
    ///
    /// 組み立て器は何本のパイプラインでも組めるので、持ち主ごとに作る理由が無い。
    func compiler() throws(RenderFailure) -> any MTL4Compiler {
        if let madeCompiler { return madeCompiler }
        let descriptor = MTL4CompilerDescriptor()
        descriptor.label = "mokume.compiler"
        guard let compiler = try? device.makeCompiler(descriptor: descriptor) else {
            throw .shaderCompilerUnavailable
        }
        madeCompiler = compiler
        return compiler
    }

    /// 同梱したシェーダを、前置き無しで組み立てる。
    ///
    /// シェーダの原文は資源として運ばれ、ここで組み立てる — この道具立てでは原文を
    /// ビルドに含める手がないため。**原文の誤りはここまで来ないと分からない**ので、
    /// `make ci-check` が別途ビルド時に組み立てて落とす (`scripts/check-shaders.sh`)。
    ///
    /// **外からは呼ばせない。** 呼べば同じ原文をもう 1 度組む。前置き無しで組むのはいま
    /// `Present` だけで、それは ``presentLibrary()`` が抱える。
    private func makeLibrary(named name: String) throws(RenderFailure) -> any MTLLibrary {
        let source = try bundledShaderSource(named: name)
        return try compile(source, name: name, reportedAs: "\(name).metal")
    }

    /// 図形を塗る断片を、共通部分を前置きしてから組み立てる。
    ///
    /// **前置きは無条件。** 断片が既に宣言を持っているかは見ない (ShaderSource を参照)。
    func makeShapeLibrary(
        named name: String, body: String, values: [String: ShaderValue] = [:],
        surfaces: [String: ShaderSurface] = [:]
    ) throws(RenderFailure) -> any MTLLibrary {
        let common = try preludedShaderSource(named: "Common")
        let source = ShaderSource.assemble(
            common: common, values: values, surfaces: surfaces, body: body)
        return try compile(source, name: name)
    }

    /// 計算の断片を、共通部分を前置きしてから組み立てる。
    ///
    /// **前置きは無条件** (塗りと同じ理由 — ShaderSource を参照)。塗りと違って入口の
    /// 関数は用意せず、束ねる先の宣言ごと利用者が書く。
    func makeComputeLibrary(
        named name: String, body: String, values: [String: ShaderValue] = [:]
    ) throws(RenderFailure) -> any MTLLibrary {
        let common = try preludedShaderSource(named: "Compute")
        let source = ShaderSource.assemble(common: common, values: values, body: body)
        return try compile(source, name: name)
    }

    /// 効果の断片を、前置きと合わせて組み立てる。
    func makeEffectLibrary(
        named name: String, body: String, values: [String: ShaderValue] = [:]
    ) throws(RenderFailure) -> any MTLLibrary {
        let common = try preludedShaderSource(named: "Effect")
        let source = ShaderSource.assemble(common: common, values: values, body: body)
        return try compile(source, name: name)
    }

    /// 原文を組む。**組む口はここ 1 つ**で、回数もここで数える。
    ///
    /// - Parameters:
    ///   - name: 数えるときの名前。
    ///   - reported: 組めなかったときに名乗る名前。省けば `name`。
    private func compile(
        _ source: String, name: String, reportedAs reported: String? = nil
    ) throws(RenderFailure) -> any MTLLibrary {
        librariesBuilt[name, default: 0] += 1
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw .shaderCompilationFailed(
                name: reported ?? name, reason: error.localizedDescription)
        }
    }

    /// 前置きの断片を、種別番号の正本 (`Kinds.metal`) 付きで読む。
    ///
    /// **3 本の前置き (Common / Compute / Effect) すべてに入る。** 番号は断片が
    /// `switch` する数で、ずれても例外は出ず別の種別として効くだけなので、Metal 側でも
    /// 1 箇所に集めて `mokume_kindLayout` が書き出せるようにしてある ([#802])。
    ///
    /// [#802]: https://github.com/mokume-metal/mokume/issues/802
    func preludedShaderSource(named name: String) throws(RenderFailure) -> String {
        try bundledShaderSource(named: "Kinds") + "\n" + bundledShaderSource(named: name)
    }

    /// 同梱している断片を読む。
    ///
    /// **探すのは [ModuleResources] に任せる。** 道具立ての口だけを使うと、包みに入れて
    /// 配ったときに組み上げた機械の絶対パスへ落ちる ([ADR-0029] 決定 4)。
    ///
    /// [ADR-0029]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0029-post-run-surfaces.md
    func bundledShaderSource(named name: String) throws(RenderFailure) -> String {
        guard let url = ModuleResources.url(forResource: name, withExtension: "metal"),
            let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw .shaderSourceMissing(name: "\(name).metal")
        }
        return source
    }
}
