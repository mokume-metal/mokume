// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 書き込みをどう扱ったか。
///
/// **黙って何もしない道を作らない。** 知らない名前・型の違い・候補の外・非有限の数は、
/// どれも「効かない」と同じ見え方になるので、理由を面へ返せる形で持つ
/// ([ADR-0030] 決定 3)。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
enum ParamOutcome: Equatable {
    /// 書いたとおりに入った。
    case applied
    /// 範囲へ収めて入った。**収めたことは黙らない。** 値は宣言の型のまま持つ —
    /// 組は成分ごとに収めるので、数 1 つでは表せない。
    case clamped(requested: ParamValue, applied: ParamValue)
    /// 宣言と型が違う。
    case typeMismatch
    /// 許した候補の外。
    case notInChoices
    /// 有限の数でない (NaN・無限)。宣言の型へ読み替えると `Float` に収まらず無限になる数も
    /// 含む (`1e300` を `Float` の値へ)。**置かずに、前の値を保つ** ([ADR-0030] 決定 3)。
    /// 有限の端へ収めない — `clamped` は「宣言した範囲へ収めた」という意味のまま保つ。
    case notFinite
}

/// 宣言された値の索引。
///
/// **起動時に 1 度だけ作る。** 宣言の名前・型・範囲はプロセスの間は変わらないので、
/// フレームごとに数え直す理由が無い。**面に出る顔ぶれ** (``declarations``) は、零へ畳めなかった
/// 宣言が非有限の間だけ外れていて、値が有限になると**同じプロセスの中で 1 度だけ**増える
/// ([#2858](https://github.com/mokume-metal/mokume/issues/2858))。名前は ``Param(_:name:)`` の展開がコンパイル時に決めたもので、
/// ここが作り直すことはない ([ADR-0030] 決定 5)。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
struct ParamRegistry {
    private let boxes: [(name: String, box: any DeclaredParam)]

    init(of sketch: any Sketch) {
        boxes = ParamCatalog.indexed(from: sketch)
    }

    /// 宣言が 1 つも無いか。
    var isEmpty: Bool { boxes.isEmpty }

    /// いまの姿。**並びは宣言した順** (基底の側から)。
    ///
    /// **値が非有限の宣言は含めない** ([#2858](https://github.com/mokume-metal/mokume/issues/2858))。
    /// 生まれのときに零へ畳めなかった自作の ``ParamRepresentable`` は非有限の値のまま置かれ
    /// (``ParamBox`` の説明)、載せると `JSONEncoder` が拒んで、保存 (`params.json`) も応答
    /// (`report.json`) も**他の値を含めて**書けなくなる。外すのは保存・応答・見張りが宣言の姿を
    /// 読むこの 1 点だけで、出口ごとには落とさない (ADR-0030 決定 3)。値は宣言を作る (読む) ときに
    /// 見るので、見張りは値の変化を拾い続け、**値が有限になれば次の保存と応答に戻る**。
    var declarations: [ParamDeclaration] {
        boxes.map(\.box.declaration).filter { $0.value.hasOnlyFiniteNumbers }
    }

    /// 保存へ併記する、宣言が生まれたときの既定値。**並びは宣言した順で、保存の `values` に載る宣言
    /// (``declarations``) のうち、既定値が有限のものだけ**。
    ///
    /// 既定値を持たない宣言 (``DeclaredParam/defaultValue`` が `nil`) と、畳めなくて非有限のまま置かれた
    /// 既定値は載せない。載せないものは、コードの既定値が変わったかを見ずに、名前と型だけで戻る
    /// ([ADR-0030] 決定 6 の改訂 (2026-10-28)・[#2402](https://github.com/mokume-metal/mokume/issues/2402))。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    var defaults: [NamedParamValue] {
        boxes.compactMap { entry in
            guard entry.box.declaration.value.hasOnlyFiniteNumbers,
                let value = entry.box.defaultValue, value.hasOnlyFiniteNumbers
            else { return nil }
            return NamedParamValue(name: entry.name, value: value)
        }
    }

    /// その名前の宣言が生まれたときの値。**宣言が無い・既定値を持たない・非有限なら `nil`。**
    func defaultValue(of name: String) -> ParamValue? {
        guard let box = boxes.first(where: { $0.name == name })?.box,
            let value = box.defaultValue, value.hasOnlyFiniteNumbers
        else { return nil }
        return value
    }

    /// 許した候補。文字の値にだけ付き、宣言が無ければ `nil`。
    func choices(of name: String) -> [String]? {
        boxes.first(where: { $0.name == name })?.box.declaration.choices
    }

    /// つまみへ渡す箱。**並びは宣言した順。**
    ///
    /// 窓がここから受け取るのは、**索引をもう 1 度引かせないため**である。引き直すと
    /// 起動のたびに 2 度数えることになり、重複した宣言の警告まで 2 度出る — 読み手には
    /// 「重複が 2 個ある」と読める
    /// ([#994](https://github.com/mokume-metal/mokume/issues/994) の 13)。
    var knobs: [any DeclaredParam] { boxes.map(\.box) }

    /// その名前の宣言があるか。
    func declares(_ name: String) -> Bool {
        boxes.contains { $0.name == name }
    }

    /// 名前を指して書き換える。
    func write(_ value: ParamValue, to name: String) -> ParamOutcome? {
        guard let entry = boxes.first(where: { $0.name == name }) else { return nil }
        return entry.box.write(value)
    }
}
