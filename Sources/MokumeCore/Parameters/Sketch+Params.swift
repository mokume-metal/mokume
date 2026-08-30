// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics

extension Sketch {
    /// 宣言した値の一覧。
    ///
    /// 並びは**基底の側から宣言順**で、継承したスケッチでも書いた順に読める。
    /// 窓・外からの書き込み・保存は、いずれもこの一覧が指す 1 つの値を読み書きする
    /// ([ADR-0013] 決定 3)。
    ///
    /// [ADR-0013]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0013-parameter-model.md
    public var params: [ParamDeclaration] { ParamCatalog.collect(from: self) }
}

/// 宣言された値を集める。
///
/// 名前は ``Param(_:name:)`` の展開が**コンパイル時に**決めており、ここが見るのは
/// 置き場そのものである — プロパティの名前から名前を作り直さない ([ADR-0030] 決定 5)。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
enum ParamCatalog {
    /// 名前と置き場の組を集める。走らせている間に何度も呼ぶものではない
    /// (起動時に 1 度引き、以降は ``ParamRegistry`` が持ち回る)。
    static func indexed(from object: Any) -> [(name: String, box: any DeclaredParam)] {
        var entries: [(name: String, box: any DeclaredParam)] = []
        var seen: Set<String> = []
        for box in boxes(of: object) {
            let name = box.declaration.name
            guard seen.insert(name).inserted else {
                // 同じ型の中の重複はビルドが止める。ここへ来るのは基底と派生で
                // 同じ名前を宣言した場合だけで、機械では防げない。黙って片方を
                // 落とすと「書いたのに動かない値」になるので名指しする。
                Diagnostics.warn("つまみ \"\(name)\" が二重に宣言されている。先に宣言されたほうを使う")
                continue
            }
            entries.append((name: name, box: box))
        }
        return entries
    }

    /// 宣言を集める。
    static func collect(from object: Any) -> [ParamDeclaration] {
        indexed(from: object).map(\.box.declaration)
    }

    /// 置き場を基底の側から順に拾う。
    private static func boxes(of object: Any) -> [any DeclaredParam] {
        var mirrors: [Mirror] = []
        var mirror: Mirror? = Mirror(reflecting: object)
        while let current = mirror {
            mirrors.append(current)
            mirror = current.superclassMirror
        }
        return mirrors.reversed().flatMap { level in
            level.children.compactMap { $0.value as? any DeclaredParam }
        }
    }
}
