// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 外で作ったモデルを読んで置く。整え方は ``Model`` が定める。
extension Canvas {

    // モデルを読む。読み終わるまで返らない。
    public func loadModel(_ path: String, normalize: Bool = true) throws(ModelFailure) -> Model {
        if let cached = modelCache[ModelRequest(path: path, normalize: normalize)] {
            return cached
        }
        let model = Model.make(
            name: path, parsed: try ModelFile.load(path), fitting: fitting(normalize: normalize))
        return remember(model, path: path, normalize: normalize)
    }

    // モデルを読む。**読んでいる間も、置ける形へ整えている間も、他の仕事を止めない。**
    public func requestModel(_ path: String, normalize: Bool = true) async throws(ModelFailure)
        -> Model
    {
        try await requestModel(path, normalize: normalize, prepared: nil)
    }

    /// 待たない読み方の本体。
    ///
    /// **整えるところまで別の仕事で済ませる** (#2801)。読み取った並びを置ける形にする
    /// ``Model/make(name:parsed:fitting:)`` は全頂点を何度も走り、50 万三角形で約 80 ms かかる。
    /// 読み込みだけを別にして整えを main へ戻すと、「待たない」はずの読み方がそのぶん描画も
    /// 入力も止める。main に残すのは控えへの登録だけである — 控えは面のもので、別の仕事から
    /// 触らない。整える長さは面の大きさ (`let`) から先に採り、値として渡す。
    ///
    /// - Parameter prepared: 整え終えたモデルを、**整えたその場で**受け取る (検査だけが渡す)。
    ///   受け取るのは `Model` なので、整え終えた所でしか呼べない — 整えを main に戻すと、
    ///   これも main で呼ばれる。
    func requestModel(
        _ path: String, normalize: Bool, prepared: (@Sendable (Model) -> Void)?
    ) async throws(ModelFailure) -> Model {
        if let cached = modelCache[ModelRequest(path: path, normalize: normalize)] {
            return cached
        }
        let fitting = fitting(normalize: normalize)
        let model: Model
        do {
            model = try await Task.detached(priority: .utility) {
                let model = Model.make(
                    name: path, parsed: try ModelFile.load(path), fitting: fitting)
                prepared?(model)
                return model
            }.value
        } catch let failure as ModelFailure {
            throw failure
        } catch {
            throw .unreadable(path: path)
        }
        return remember(model, path: path, normalize: normalize)
    }

    // 読み込んだモデルを置く。
    public func model(_ model: Model) {
        guard style.hasFill || style.hasStroke else { return }
        guard !model.isEmpty else { return warnEmptyModel(model) }
        if style.hasFill {
            // 向きを形から求めたか (両面か) は角ごとに点が持つ (#2342)
            placeMesh(.model(identity: model.identity), winding: { model.winding }) {
                model.mesh
            }
        }
        strokeSolidEdges(of: .model(identity: model.identity)) { model.mesh }
    }

    /// 整えるときに、いちばん長い辺を合わせる長さ。`nil` なら整えない。
    ///
    /// **整える長さは面から決める。** 固定の長さにすると、面の大きさによって
    /// 「読めているのに見えない」が起きる
    private func fitting(normalize: Bool) -> Float? {
        normalize ? min(width, height) / 2 : nil
    }

    /// 控えに入れる。**量が上限を超えたら、収まるまで古い順に捨てる**
    /// (``Canvas/modelCache``)。`loadModel` も `requestModel` もここを通るので、追い出しは
    /// 両方に効く。
    private func remember(_ model: Model, path: String, normalize: Bool) -> Model {
        modelCache.insert(model, for: ModelRequest(path: path, normalize: normalize))
        return model
    }

    /// 面が 1 つも無いモデルを置いたことを、初回だけ知らせる。
    ///
    /// **読めなかったのとは違う。** 投げてしまうと、利用者は読み込みの側を直そうと
    /// して、実際には空のファイルを渡しているという事実に辿り着けない。
    private func warnEmptyModel(_ model: Model) {
        // 読み飛ばしを数える単位は形式で違う (``Model/skippedLines``)。STL は面のほか、写せな
        // かった mesh・submesh も数えるので、面とは呼ばず「要素」と言う
        let unit = ModelFile.Format(path: model.name) == .stl ? "elements" : "lines"
        warnOnce(
            .emptyModel,
            "\"\(model.name)\" could be read, but it has no faces at all "
                + "(\(model.skippedLines) \(unit) were skipped). Placing it shows nothing")
    }
}

/// 控えの鍵。**整え方が違えば別のもの**なので、鍵に含める。
struct ModelRequest: Hashable {
    var path: String
    var normalize: Bool
}
