// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// シェーダの原文を読み、組み立てる。
///
/// ## なぜ描画の土台から出ているのか
///
/// **`device` しか要らないからである。** 投入も、待ちも、コマンドの置き場も、常駐の集合も
/// 使わない — ``RenderDevice`` の中核 (投入と待ち) と共有しているものが 1 つも無い。
/// 同じ型に居ると「シェーダを組み立てるには描画の土台の状態が要る」と読めてしまうが、
/// 実際には要らない ([#959](https://github.com/mokume-metal/mokume/issues/959))。
///
/// 転送メソッドを ``RenderDevice`` に残していないのも同じ理由で、残すと**組み立ては
/// あちらの仕事だという読みが残る**。呼ぶ側は `gpu.shaders` を通る。
///
/// ## 原文はビルドに含まれない
///
/// シェーダの原文は資源として運ばれ、走らせてから組み立てる — この道具立てでは原文を
/// ビルドに含める手がないためである。**原文の誤りはここまで来ないと分からない**ので、
/// `make ci-check` が別途ビルド時に組み立てて落とす (`scripts/check-shaders.sh`)。
struct ShaderLibraries {
    let device: any MTLDevice

    /// 同梱したシェーダを読み込む。
    ///
    /// シェーダの原文は資源として運ばれ、ここで組み立てる — この道具立てでは原文を
    /// ビルドに含める手がないため。**原文の誤りはここまで来ないと分からない**ので、
    /// `make ci-check` が別途ビルド時に組み立てて落とす (`scripts/check-shaders.sh`)。
    func makeLibrary(named name: String) throws(RenderFailure) -> any MTLLibrary {
        let source = try bundledShaderSource(named: name)
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw .shaderCompilationFailed(
                name: "\(name).metal", reason: error.localizedDescription)
        }
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
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw .shaderCompilationFailed(
                name: name, reason: error.localizedDescription)
        }
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
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw .shaderCompilationFailed(name: name, reason: error.localizedDescription)
        }
    }

    /// 効果の断片を、前置きと合わせて組み立てる。
    func makeEffectLibrary(
        named name: String, body: String, values: [String: ShaderValue] = [:]
    ) throws(RenderFailure) -> any MTLLibrary {
        let common = try preludedShaderSource(named: "Effect")
        let source = ShaderSource.assemble(common: common, values: values, body: body)
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw .shaderCompilationFailed(name: name, reason: error.localizedDescription)
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
