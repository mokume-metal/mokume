// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 打たれた引数を、**宣言**に沿って解く。
///
/// ## なぜ 1 本にするのか
///
/// `run` / `watch` (``Invocation``)・`new`・`bundle`・`doctor` の 4 つが、同じ骨格を
/// 4 回書いていた — index を回す while、`--x` の次を値として取る、`-` 始まりなら知らない
/// 選択肢、それ以外は位置引数で 2 つ目ならエラー。**4 本あると、ずれても誰も気付かない**
/// ([#814](https://github.com/mokume-metal/mokume/issues/814))。
///
/// 4 本目は `doctor` で、これは知らない選択肢を投げずに脇へ置く。**その振る舞いは正しい**
/// (切り分けの口が使い方で止まると、いちばん要るときに読めない) が、正しさが構造では
/// なく「別実装であること」に表れていた。ここでは ``Surplus`` の 1 値になる。
///
/// ## 文面は宣言が持つ
///
/// 「値が欠けた」「位置引数が 2 つ目」の言い方は口ごとに違う (場所 / 名前、置き場 /
/// 構成の名前)。**ここで一律の文面を作らない** — 打った人が次に何を書けばよいかは、
/// その口だけが知っている。ここが持つのは、どの口でも同じ「知らない選択肢」だけである。
enum Arguments {
    /// 値を取る選択肢の宣言。
    struct Option {
        /// 受ける綴り。**先頭が鍵**になる (``Parsed/values`` から引くときの名前)。
        let flags: [String]
        /// 値が欠けていたときの言い方。**打たれた綴り**を受け取る — `-c` と
        /// `--configuration` のどちらで打たれたかは、直す人にとって同じではない。
        let missingValue: (String) -> String

        init(_ flags: [String], missingValue: @escaping (String) -> String) {
            self.flags = flags
            self.missingValue = missingValue
        }

        /// ``Parsed/values`` に載る名前。
        var key: String { flags[0] }
    }

    /// 宣言に載っていないもの (知らない選択肢・2 つ目の位置引数) の扱い。
    enum Surplus {
        /// 使い方を出して止まる。
        ///
        /// - Parameter extraPositional: 位置引数が 2 つ目に来たときの言い方。
        case reject(extraPositional: (String) -> String)
        /// 脇へ置いて解き続ける。`doctor` だけがこちらを選ぶ。
        case ignore
    }

    /// 解いた結果。
    ///
    /// **位置引数は 1 つまで**である。4 つの口はどれも 1 つしか取らないので、それ以上を
    /// 受ける形は書かない (ADR-0001 原則 4 — 実際に踏まれてから足す)。
    struct Parsed: Equatable {
        /// 位置引数 (場所・名前)。
        var positional: String?
        /// 選択肢の値。鍵は ``Option/key``。
        var values: [String: String] = [:]
        /// 脇へ置いたもの。``Surplus/ignore`` のときだけ増える。**打たれた順に並ぶ。**
        var ignored: [String] = []
    }

    /// 解く。
    static func parse(
        _ arguments: [String], options: [Option] = [], surplus: Surplus
    ) throws(CommandFailure) -> Parsed {
        var parsed = Parsed()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if let option = options.first(where: { $0.flags.contains(argument) }) {
                index += 1
                guard index < arguments.count else { throw .usage(option.missingValue(argument)) }
                parsed.values[option.key] = arguments[index]
            } else if argument.hasPrefix("-") {
                // **知らない選択肢を黙って位置引数にしない。** `-c` が場所として解釈された
                // 結果が「スケッチが見つからない: …/-c」で、何を直せばよいか分からない (#680)
                switch surplus {
                case .reject: throw .usage("知らない選択肢: \(argument)\n\n" + Command.usage())
                case .ignore: parsed.ignored.append(argument)
                }
            } else if parsed.positional == nil {
                parsed.positional = argument
            } else {
                switch surplus {
                case .reject(let extraPositional): throw .usage(extraPositional(argument))
                case .ignore: parsed.ignored.append(argument)
                }
            }
            index += 1
        }
        return parsed
    }
}
