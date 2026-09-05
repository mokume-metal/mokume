// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics

/// 利用者が書いた断片を持つものの骨。
///
/// ``Shader`` (塗り) ・``EffectShader`` (効果) ・``Computation`` (計算) が**内側に
/// 1 つずつ持つ**。3 つとも「宣言と照らして値を書き換える」「保存を拾って組み直す」を
/// 同じ順で書いていて、**直すときに 1 つ書き落とせる形**だった — [#787] が実際に
/// 開けた穴がそれである ([#892] で畳んだ)。
///
/// **組み立てそのものは持ち主に残る。** 何を組むか (塗りの平面と立体・効果の 1 本・
/// 計算の 1 本) も、組み上がったものをどう差し替えるかも 3 者で違い、ここに畳むと
/// 「平面と立体の両方が組み上がってから差し替える」のような約束が見えなくなる。
///
/// [#787]: https://github.com/mokume-metal/mokume/issues/787
/// [#892]: https://github.com/mokume-metal/mokume/issues/892
final class ShaderBox {
    /// 断片の名前。
    let name: String
    /// 断片の在処。保存を拾い直すのに使う。持たなければ拾い直さない。
    let url: URL?
    /// いま効いている値。
    private(set) var values: [String: ShaderValue]
    /// 直近の差し替えが失敗していれば、その理由。
    private(set) var failure: String?
    /// 何度差し替わったか。**外から「届いたか」を待ち時間ではなく数で判定できる。**
    private(set) var generation = 0
    /// 最後に組み上がった断片の中身。**同じものを組み直さない**ための控え。
    private var compiledBody: String
    private(set) var watcher: FileWatcher?

    /// 警告の頭に付ける名乗り (`shader` / `effect` / `computation`)。
    private let label: String
    /// 宣言していない名前を渡されたときに案内する、値の書き場所。
    private let valuesHint: String

    init(
        name: String, url: URL?, body: String, values: [String: ShaderValue],
        label: String, valuesHint: String
    ) {
        self.name = name
        self.url = url
        self.values = values
        self.compiledBody = body
        self.label = label
        self.valuesHint = valuesHint
    }

    /// 保存を拾い始める。
    ///
    /// **持ち主が組み上がってから呼ぶ。** 初期化の途中で拾い始めると、まだ組み上がって
    /// いない持ち主の `reload` が走る。
    func watch(_ onChange: @escaping () -> Void) {
        guard let url else { return }
        watcher = FileWatcher(url: url, onChange: onChange)
    }

    /// 宣言と照らして値を書き換える。書き換えたら `true`。
    ///
    /// **宣言していない名前は受け付けない** — 断片は組み立てるときに値の宣言ごと
    /// 組み上がるので、後から名前を増やすと組み直しになる。増やすかどうかは
    /// 断片を読み込む (作る) ときに決める。
    @discardableResult
    func assign(_ name: String, _ value: ShaderValue) -> Bool {
        guard let existing = values[name] else {
            Diagnostics.warn(
                "\(label): 宣言していない値 \"\(name)\" は渡せません。"
                    + "\(valuesHint) に書いてください "
                    + "(いまの値: \(values.keys.sorted().joined(separator: ", ")))")
            return false
        }
        guard existing.componentCount == value.componentCount else {
            Diagnostics.warn(
                "\(label): 値 \"\(name)\" の形が宣言と違います "
                    + "(\(existing.metalType) のところへ \(value.metalType))")
            return false
        }
        values[name] = value
        return true
    }

    /// いまの値を、断片へ渡す並びに詰めたもの。
    var packedValues: [Float] { ShaderSource.pack(values) }

    /// 断片を読み直して、`rebuild` に組ませる。
    ///
    /// **失敗しても前のものを消さない。** 削ってから入れ直す形にすると、組み立てに
    /// 失敗した瞬間に元の断片ごと消えて絵が出なくなる。`rebuild` が投げたら、持ち主が
    /// 抱えている組み上がりはそのまま残る。
    ///
    /// - Parameter rebuild: 読み直した中身から組み立てて差し替える。投げてよい。
    func reload(_ rebuild: (String) throws(RenderFailure) -> Void) {
        guard let url else { return }
        guard let body = try? String(contentsOf: url, encoding: .utf8) else {
            failure = "断片を読めませんでした: \(url.path)"
            Diagnostics.warn("\(label): \(failure!)")
            return
        }
        // **同じ中身なら組み直さない。** 1 度の保存でファイル側と親ディレクトリ側の
        // 両方が反応するので、素直に組み直すと 1 度の保存で 2 度組み立てることになる
        guard body != compiledBody else { return }
        do {
            try rebuild(body)
            compiledBody = body
            failure = nil
            generation += 1
        } catch {
            failure = "\(error)"
            Diagnostics.warn("\(label): 断片を組み立て直せませんでした: \(error.headline)")
        }
    }
}
