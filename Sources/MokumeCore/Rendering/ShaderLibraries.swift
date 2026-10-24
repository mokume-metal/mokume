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
    private var imageInput: (any MTLLibrary)?
    private var builtinEffect: (any MTLLibrary)?
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

    /// 画像入力の共通断片。描き場所が増えても同じ原文を組み直さない。
    func imageInputLibrary() throws(RenderFailure) -> any MTLLibrary {
        if let imageInput { return imageInput }
        let library = try makeLibrary(named: "ImageInput")
        imageInput = library
        return library
    }

    /// 組み込みの効果のライブラリ。**組むのは最初の 1 度だけ** — 効果のパイプラインを持つ面が増えても
    /// (描き場所・``Image/filtered(_:)`` の作業の面)、同梱の同じ原文を組み直さない (冷えた状態で数十 ms)。
    func builtinEffectLibrary() throws(RenderFailure) -> any MTLLibrary {
        if let builtinEffect { return builtinEffect }
        let library = try makeEffectLibrary(
            named: "builtin", body: try bundledShaderSource(named: "Builtin"),
            bodyName: Self.bundledName("Builtin"))
        builtinEffect = library
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
    /// **外からは呼ばせない。** 呼べば同じ原文をもう 1 度組む。前置き無しで組む同梱の断片も、
    /// 専用の口が抱える (`Present` と `ImageInput`)。
    private func makeLibrary(named name: String) throws(RenderFailure) -> any MTLLibrary {
        let source = try bundledShaderSource(named: name)
        return try compile(source, name: name, reportedAs: "\(name).metal")
    }

    /// 図形を塗る断片を、共通部分を前置きしてから組み立てる。
    ///
    /// **前置きは無条件。** 断片が既に宣言を持っているかは見ない (ShaderSource を参照)。
    func makeShapeLibrary(
        named name: String, body: String, bodyName: String? = nil,
        values: [String: ShaderValue] = [:], surfaces: [String: ShaderSurface] = [:]
    ) throws(RenderFailure) -> any MTLLibrary {
        try shapeLibraryJob(
            named: name, body: body, bodyName: bodyName, values: values, surfaces: surfaces
        ).runNow()
    }

    /// ``makeShapeLibrary(named:body:bodyName:values:surfaces:)`` の組み立てを、走らせずに用意する。
    /// 裏で組む経路 (``ShaderBox``・[#2365]) が使う。
    ///
    /// [#2365]: https://github.com/mokume-metal/mokume/issues/2365
    func shapeLibraryJob(
        named name: String, body: String, bodyName: String? = nil,
        values: [String: ShaderValue] = [:], surfaces: [String: ShaderSurface] = [:]
    ) throws(RenderFailure) -> LibraryJob {
        try userJob(
            prelude: "Common", named: name, body: body, bodyName: bodyName, values: values,
            surfaces: surfaces, entry: .paint(surfaces: !surfaces.isEmpty))
    }

    /// 計算の断片を、共通部分を前置きしてから組み立てる。
    ///
    /// **前置きは無条件** (塗りと同じ理由 — ShaderSource を参照)。塗りと違って入口の
    /// 関数は用意せず、束ねる先の宣言ごと利用者が書く。
    func makeComputeLibrary(
        named name: String, body: String, bodyName: String? = nil,
        values: [String: ShaderValue] = [:]
    ) throws(RenderFailure) -> any MTLLibrary {
        try computeLibraryJob(named: name, body: body, bodyName: bodyName, values: values).runNow()
    }

    /// ``makeComputeLibrary(named:body:bodyName:values:)`` の組み立てを、走らせずに用意する。
    func computeLibraryJob(
        named name: String, body: String, bodyName: String? = nil,
        values: [String: ShaderValue] = [:]
    ) throws(RenderFailure) -> LibraryJob {
        try userJob(
            prelude: "Compute", named: name, body: body, bodyName: bodyName, values: values,
            entry: nil)
    }

    /// 効果の断片を、前置きと合わせて組み立てる。
    func makeEffectLibrary(
        named name: String, body: String, bodyName: String? = nil,
        values: [String: ShaderValue] = [:]
    ) throws(RenderFailure) -> any MTLLibrary {
        try effectLibraryJob(named: name, body: body, bodyName: bodyName, values: values).runNow()
    }

    /// ``makeEffectLibrary(named:body:bodyName:values:)`` の組み立てを、走らせずに用意する。
    func effectLibraryJob(
        named name: String, body: String, bodyName: String? = nil,
        values: [String: ShaderValue] = [:]
    ) throws(RenderFailure) -> LibraryJob {
        try userJob(
            prelude: "Effect", named: name, body: body, bodyName: bodyName, values: values,
            entry: .effect)
    }

    /// 利用者の断片を組む仕事。**塗り・効果・計算の利用者の断片は、すべてここを通る。**
    ///
    /// - **`values:`・`surfaces:` の名前の字の並びを、組み立ての前に検める** ([#2783])。書けない名前
    ///   (`tint color`・空・`;` を含む) は組まずに断る。検めをここ 1 か所に置くのは、断片を作る
    ///   口 (文字列・ファイル × 3 種) と差し替えの経路がすべて通るからで、口ごとに写すと足し忘れる
    ///   口ができる
    /// - 組めなかった理由は、入口の書き違え ([#2782]) と、Metal で使えない名前 ([#2783] の反証) を
    ///   言い直す (``LibraryJob/Restatement``)
    ///
    /// [#2782]: https://github.com/mokume-metal/mokume/issues/2782
    /// [#2783]: https://github.com/mokume-metal/mokume/issues/2783
    private func userJob(
        prelude preludeName: String, named name: String, body: String, bodyName: String?,
        values: [String: ShaderValue], surfaces: [String: ShaderSurface] = [:],
        entry: ShaderEntryPoint?
    ) throws(RenderFailure) -> LibraryJob {
        let fragment = bodyName ?? name
        if let reason = ShaderSource.unusableNames(values: values, surfaces: surfaces, in: fragment) {
            throw .shaderCompilationFailed(name: name, reason: reason)
        }
        let source = ShaderSource.assemble(
            prelude: try prelude(named: preludeName), values: values, surfaces: surfaces,
            body: .init(name: fragment, text: body))
        return job(
            source, name: name,
            restatement: .init(
                fragment: fragment, entry: entry,
                names: ShaderSource.declaredNames(values: values, surfaces: surfaces)))
    }

    /// 原文を組む。
    private func compile(
        _ source: String, name: String, reportedAs reported: String? = nil
    ) throws(RenderFailure) -> any MTLLibrary {
        try job(source, name: name, reportedAs: reported).runNow()
    }

    /// 原文を組む仕事を用意する。**組む口はここ 1 つ**で、回数もここで数える。
    ///
    /// 数えるのは用意した時点である。裏で組む仕事も、組みに行くと決めた回として数える
    /// (組めなかった回を数えるのと同じ理由)。
    ///
    /// - Parameters:
    ///   - name: 数えるときの名前。
    ///   - reported: 組めなかったときに名乗る名前。省けば `name`。
    ///   - restatement: 組めなかった理由の言い直しに要るもの。利用者の断片だけが持つ。
    private func job(
        _ source: String, name: String, reportedAs reported: String? = nil,
        restatement: LibraryJob.Restatement? = nil
    ) -> LibraryJob {
        librariesBuilt[name, default: 0] += 1
        return LibraryJob(
            device: device, source: source, reportedName: reported ?? name, restatement: restatement)
    }

    /// 原文を組む仕事 1 つ。**その場で組むことも、裏で組むこともできる** ([#2365])。
    ///
    /// 2 つの口は同じ原文・同じ失敗の写像を通る。裏で組む口は main actor に触らないので、
    /// 組み上がりを main の継続に頼らずに受け取れる (``ShaderBox`` の「裏で組む」)。
    ///
    /// [#2365]: https://github.com/mokume-metal/mokume/issues/2365
    nonisolated struct LibraryJob: Sendable {
        let device: any MTLDevice
        let source: String
        let reportedName: String
        let restatement: Restatement?

        /// 利用者の断片の、組めなかった理由の言い直しに要るもの。
        struct Restatement: Sendable {
            /// 断片が名乗る名前 (``ShaderSource/bodyName(_:url:)``)。
            let fragment: String
            /// 前置きが呼ぶ入口。計算は前置きが入口を呼ばないので持たない (入口は
            /// ``ComputePipeline/StateJob`` が見る)。
            let entry: ShaderEntryPoint?
            /// 渡された名前から作った宣言の、行ごとの名前。
            let names: ShaderSource.DeclaredNames

            func restating(_ reason: String) -> String {
                let named = names.restating(reason, in: fragment)
                return entry?.restating(named, in: fragment) ?? named
            }
        }

        /// その場で組む。
        func runNow() throws(RenderFailure) -> any MTLLibrary {
            do {
                return try device.makeLibrary(source: source, options: nil)
            } catch {
                throw failure(error)
            }
        }

        /// 裏で組む。組んでいる間、呼んだ側の糸を塞がない。
        func run() async throws(RenderFailure) -> any MTLLibrary {
            do {
                return try await device.makeLibrary(source: source, options: nil)
            } catch {
                throw failure(error)
            }
        }

        /// 組めなかった理由。**入口を書き違えた断片なら期待する入口の形を (#2782)、Metal で使えない
        /// 名前を渡した断片ならその名前を (#2783)、先頭に足す。**
        private func failure(_ error: any Error) -> RenderFailure {
            let reason = error.localizedDescription
            return .shaderCompilationFailed(
                name: reportedName, reason: restatement?.restating(reason) ?? reason)
        }
    }

    /// 前置きの断片を、種別番号の正本 (`Kinds.metal`) 付きで読む。
    ///
    /// **3 本の前置き (Common / Compute / Effect) すべてに入る。** 番号は断片が
    /// `switch` する数で、ずれても例外は出ず別の種別として効くだけなので、Metal 側でも
    /// 1 箇所に集めて `mokume_kindLayout` が書き出せるようにしてある ([#802])。
    ///
    /// 区切りは名前を持ち、組み立てた原稿の中で本体の名前 (``bundledName(_:)``) を名乗る
    /// (``ShaderSource/assemble(prelude:values:surfaces:body:)``)。
    ///
    /// [#802]: https://github.com/mokume-metal/mokume/issues/802
    func prelude(named name: String) throws(RenderFailure) -> [ShaderSource.Part] {
        [
            .init(name: Self.bundledName("Kinds"), text: try bundledShaderSource(named: "Kinds")),
            .init(name: Self.bundledName(name), text: try bundledShaderSource(named: name)),
        ]
    }

    /// 同梱している断片が、組み立てた原稿の中で名乗る名前 (`mokume/Common.metal`)。
    ///
    /// **頭に `mokume/` を付ける。** 利用者のファイルが `Common.metal` という名前でも、本体の
    /// 前置きの行と見分けられる。
    static func bundledName(_ name: String) -> String { "mokume/\(name).metal" }

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
