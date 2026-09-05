// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 面に出る値が名乗る型の綴り。**書く側と読む側の正典。**
///
/// 値の隣に型を書くのは、値だけでは 1.0 が実数なのか整数なのか、2 成分なのか
/// 3 成分なのかを読み手が推測することになるからである ([ADR-0030] 決定 4)。
/// その綴りが書く側と読む側で割れると、**書いたものを自分で読めなくなる** —
/// しかもコンパイルは通るので、割れたことは誰も言わない。
///
/// ## 足すと止まる
///
/// ``ParamValue`` にケースを足すと ``ParamValue/paramType`` の網羅 `switch` が
/// 止まり、ここへ綴りを足すとデコード側 (``ParamValue/init(from:)``) の網羅
/// `switch` が止まる。
///
/// 綴りの全集合は `Schemas/params-report.schema.json` と
/// `Schemas/params-request.schema.json` の `enum` と一致していなければならない。
/// **一致は `scripts/tests/wire_vocabulary_test.py` が見る** (`make hooks-test`)。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
enum ParamTypeName: String, CaseIterable, Sendable {
    case float
    case int
    case bool
    case string
    case color
    case vec2
    case vec3
}
