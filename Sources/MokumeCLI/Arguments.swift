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
        /// 値が場所か。**場所なら、空の値を断る** (``emptyPlace(_:)``)。
        let takesPlace: Bool
        /// 値の取り得る範囲 (`nil` なら何でも)。**``Surplus/ignore`` のときだけ見る** — 範囲外の
        /// 語は値に取らず、元の位置のまま読む (`doctor -c /path/to/sketch` の場所を値に食わない)。
        /// 値を使う口は取った後に自分の言い方で断るので、そちらは変えない。
        let accepts: ((String) -> Bool)?

        init(
            _ flags: [String], takesPlace: Bool = false, accepts: ((String) -> Bool)? = nil,
            missingValue: @escaping (String) -> String
        ) {
            self.flags = flags
            self.takesPlace = takesPlace
            self.accepts = accepts
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
        ///
        /// **宣言した選択肢は値を取り、使われない前提で脇へ置く** (#2484)。値を取る選択肢を
        /// 宣言するのは、値が位置引数 (場所) に化けないようにするためで、使うためではない —
        /// `doctor -c release` の `release` を場所として診ない。値は ``Parsed/values`` に載り、
        /// 表示用には ``Parsed/setAside`` に載る。値が欠けていても (`doctor -c`) 止まらない。
        ///
        /// **`-` 始まりの語と、範囲外の語 (``Option/accepts``) は値に取らない** — 走らせる口と
        /// 同じ。`doctor -c --scratch-path out` の `out` や `doctor -c /path/to/sketch` の場所が
        /// 値に食われない。取らなかった選択肢は、値が無かったと名乗る。
        case ignore
    }

    /// 解いた結果。
    ///
    /// **位置引数は 1 つまで**である。ここを通る口 (窓口 `mcp` も含む・#2321) はどれも
    /// 1 つしか取らないので、それ以上を受ける形は書かない (ADR-0001 原則 4 — 実際に
    /// 踏まれてから足す)。
    struct Parsed: Equatable {
        /// 位置引数 (場所・名前)。
        var positional: String?
        /// 選択肢の値。鍵は ``Option/key``。
        var values: [String: String] = [:]
        /// 脇へ置いた、宣言に載っていないもの。``Surplus/ignore`` のときだけ増える。
        /// **打たれた順に並ぶ。**
        var ignored: [String] = []
        /// 使われずに脇へ置かれたもの全部の、打ったとおりの表示。``Surplus/ignore`` のときだけ
        /// 増える。**打たれた順に並び、宣言した選択肢は綴りと値を 1 つにして載る** (`-c release`)。
        /// 値はシェルの 1 語として読める形にする (空は `''`、空白入りは引用符つき・#2484)。
        var setAside: [String] = []
    }

    /// 空の場所を断る言い方。`flag` は選択肢の綴り (位置引数なら `nil`)。
    ///
    /// **空は場所を名指していない。** `URL(fileURLWithPath: "")` は走らせた場所に解けるので、
    /// 通すと `run "$DIR"` で `DIR` が空だった回が、黙って走らせた場所を使う
    /// ([#2485](https://github.com/mokume-metal/mokume/issues/2485))。打った値を別のものとして
    /// 読まない規律 (#680) を、場所を取る口すべてに 1 か所で効かせる。
    static func emptyPlace(_ flag: String?) -> CommandFailure {
        guard let flag else {
            return .usage(
                "The directory is empty, which names no place. Pass a directory, or leave it out"
                    + " to use where you ran this (is a variable you passed unset?)")
        }
        return .usage(
            "\(flag) is empty, which names no place. Pass a path after it"
                + " (is a variable you passed unset?)")
    }

    /// `--x=値` の綴りで、`=` の前が宣言済みの綴りなら、空白で区切るよう案内する文。
    ///
    /// **受け付ける形は増やさない** ([#2484](https://github.com/mokume-metal/mokume/issues/2484))。
    /// `Unknown option` と言うと、`run -c release` が通る人には綴りの何が違うのか分からない。
    /// 宣言されていない綴り (`--nope=1`) は、これまでどおり知らない選択肢である。
    private static func separatedSpelling(of argument: String, in options: [Option]) -> String? {
        guard let equals = argument.firstIndex(of: "=") else { return nil }
        let flag = String(argument[..<equals])
        guard options.contains(where: { $0.flags.contains(flag) }) else { return nil }
        let value = String(argument[argument.index(after: equals)...])
        // 値は貼って動く 1 語にする (#2320 の規律)。空白入りの `'my take.mov'` を裸で書くと、
        // 案内どおりに打って別の誤りになる
        return "\(argument) is not accepted: separate the value from \(flag) with a space,"
            + " as in \(flag) \(value.isEmpty ? "<value>" : GivenPath.shellWord(display: value))"
    }

    /// 解く。
    ///
    /// - Parameter positionalIsPlace: 位置引数が場所か。**場所なら、空を断る**
    ///   (``emptyPlace(_:)``)。名前を取る口 (`new`) は名前の規則で断るので立てない。
    static func parse(
        _ arguments: [String], options: [Option] = [], positionalIsPlace: Bool = false,
        surplus: Surplus
    ) throws(CommandFailure) -> Parsed {
        var parsed = Parsed()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if let option = options.first(where: { $0.flags.contains(argument) }) {
                index += 1
                if case .ignore = surplus {
                    // 使われない選択肢。値は取るが、止まらない (切り分けの口は止まらない)
                    if index < arguments.count, !arguments[index].hasPrefix("-"),
                        option.accepts?(arguments[index]) ?? true
                    {
                        parsed.values[option.key] = arguments[index]
                        parsed.setAside.append(
                            "\(argument) \(GivenPath.shellWord(display: arguments[index]))")
                        index += 1
                    } else {
                        // 次の語は値でない。取らずに、そのまま読み直す
                        parsed.setAside.append("\(argument) (no value)")
                    }
                    continue
                }
                guard index < arguments.count else { throw .usage(option.missingValue(argument)) }
                if option.takesPlace, arguments[index].isEmpty { throw emptyPlace(argument) }
                parsed.values[option.key] = arguments[index]
            } else if argument.hasPrefix("-") {
                // **知らない選択肢を黙って位置引数にしない。** `-c` が場所として解釈された
                // 結果が「スケッチが見つからない: …/-c」で、何を直せばよいか分からない (#680)
                switch surplus {
                case .reject:
                    if let spelling = separatedSpelling(of: argument, in: options) {
                        throw .usage(spelling + "\n\n" + Command.usage())
                    }
                    throw .usage("Unknown option: \(argument)\n\n" + Command.usage())
                case .ignore:
                    parsed.ignored.append(argument)
                    parsed.setAside.append(GivenPath.shellWord(display: argument))
                }
            } else if parsed.positional == nil {
                if positionalIsPlace, argument.isEmpty { throw emptyPlace(nil) }
                parsed.positional = argument
            } else {
                switch surplus {
                case .reject(let extraPositional): throw .usage(extraPositional(argument))
                case .ignore:
                    parsed.ignored.append(argument)
                    parsed.setAside.append(GivenPath.shellWord(display: argument))
                }
            }
            index += 1
        }
        return parsed
    }
}
