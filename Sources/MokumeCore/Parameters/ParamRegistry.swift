// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 書き込みをどう扱ったか。
///
/// **黙って何もしない道を作らない。** 知らない名前・型の違い・候補の外は、どれも
/// 「効かない」と同じ見え方になるので、理由を面へ返せる形で持つ
/// ([ADR-0030] 決定 3)。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
enum ParamOutcome: Equatable {
    /// 書いたとおりに入った。
    case applied
    /// 範囲へ収めて入った。**収めたことは黙らない。**
    case clamped(requested: Double, applied: Double)
    /// 宣言と型が違う。
    case typeMismatch
    /// 許した候補の外。
    case notInChoices
}

/// 宣言された値の索引。
///
/// **起動時に 1 度だけ作る。** 宣言はプロセスの間は変わらないので、フレームごとに
/// 数え直す理由が無い。名前は ``Param(_:name:)`` の展開がコンパイル時に決めたもので、
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
    var declarations: [ParamDeclaration] { boxes.map(\.box.declaration) }

    /// 名前を指して書き換える。
    func write(_ value: ParamValue, to name: String) -> ParamOutcome? {
        guard let entry = boxes.first(where: { $0.name == name }) else { return nil }
        return entry.box.write(value)
    }
}
