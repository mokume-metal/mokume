// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics
import simd

// 外で作ったモデルを読んで置く。整え方は ``Model`` が定める。
extension Canvas {

    // モデルを読む。読み終わるまで返らない。
    public func loadModel(_ path: String, normalize: Bool = true) throws(ModelFailure) -> Model {
        if let cached = modelCache[ModelRequest(path: path, normalize: normalize)] {
            return cached
        }
        let parsed = try ModelFile.load(path)
        return remember(parsed, path: path, normalize: normalize)
    }

    // モデルを読む。**読んでいる間、他の仕事を止めない。**
    public func requestModel(_ path: String, normalize: Bool = true) async throws(ModelFailure)
        -> Model
    {
        if let cached = modelCache[ModelRequest(path: path, normalize: normalize)] {
            return cached
        }
        let parsed: ModelFile.Parsed
        do {
            parsed = try await Task.detached(priority: .utility) {
                try ModelFile.load(path)
            }.value
        } catch let failure as ModelFailure {
            throw failure
        } catch {
            throw .unreadable(path: path)
        }
        return remember(parsed, path: path, normalize: normalize)
    }

    // 読み込んだモデルを置く。
    public func model(_ model: Model) {
        guard hasFill else { return }
        guard !model.isEmpty else { return warnEmptyModel(model) }
        placeMesh(.model(identity: model.identity), isDerived: model.hasDerivedNormals) {
            model.mesh
        }
    }

    /// 整えて控えに入れる。
    private func remember(
        _ parsed: ModelFile.Parsed, path: String, normalize: Bool
    ) -> Model {
        nextModelIdentity += 1
        let model = Model.make(
            name: path, parsed: parsed,
            // **整える長さは面から決める。** 固定の長さにすると、面の大きさによって
            // 「読めているのに見えない」が起きる
            fitting: normalize ? min(width, height) / 2 : nil,
            identity: nextModelIdentity)
        modelCache[ModelRequest(path: path, normalize: normalize)] = model
        return model
    }

    /// 面が 1 つも無いモデルを置いたことを、初回だけ知らせる。
    ///
    /// **読めなかったのとは違う。** 投げてしまうと、利用者は読み込みの側を直そうと
    /// して、実際には空のファイルを渡しているという事実に辿り着けない。
    private func warnEmptyModel(_ model: Model) {
        guard !warnedEmptyModel else { return }
        warnedEmptyModel = true
        Diagnostics.warn(
            "「\(model.name)」は読めましたが、面が 1 つもありません "
                + "(読み飛ばした行 \(model.skippedLines))。置いても何も出ません")
    }
}

/// 控えの鍵。**整え方が違えば別のもの**なので、鍵に含める。
struct ModelRequest: Hashable {
    var path: String
    var normalize: Bool
}
