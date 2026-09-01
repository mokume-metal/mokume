// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 走らせる口が受け取るもの。
///
/// ## なぜ 1 つにするのか
///
/// `run` と `watch` は同じものを受ける (どのスケッチを・どの構成で)。別々に解くと、
/// **片方だけが選択肢を受ける**状態が生まれる — 実際、構成を選ぶ口はどちらにも無く、
/// `-c release` は場所として解釈されていた ([#680](https://github.com/mokume-metal/mokume/issues/680))。
///
/// ## 構成は「選ばれたか」と「名乗る名前」を分ける
///
/// 選ばれなければ道具立ての既定に任せる — こちらが `-c debug` と書き固めると、道具立てが
/// 既定を変えた日に黙ってずれる。一方で**名乗りには名前が要る**ので、選ばれていないときは
/// 既定の名前を名乗る。同じ値から両方が出るので、名乗りと実体が食い違わない。
struct Invocation: Equatable {
    /// スケッチの場所。渡されなければ、いまいるところ。
    var place: String?
    /// 選ばれた構成。渡されなければ道具立ての既定に任せる。
    var configuration: String?

    /// スケッチの場所 (URL)。
    var directory: URL {
        URL(
            fileURLWithPath: place ?? FileManager.default.currentDirectoryPath,
            isDirectory: true)
    }

    /// 名乗るときの構成の名前。
    var configurationName: String { configuration ?? RunCommand.defaultConfigurationName }

    /// 構成を選ぶ綴り。**道具立てに合わせる** — 渡す先が同じものなので、ここで別の名前を
    /// 作ると読み替えが要る。
    static let configurationFlags = ["-c", "--configuration"]

    /// 引数を解く。
    ///
    /// **知らない選択肢は黙って場所にしない。** `-c` が場所として解釈された結果が
    /// 「スケッチが見つからない: …/-c」で、これは何を直せばよいか分からない ([#680])。
    ///
    /// [#680]: https://github.com/mokume-metal/mokume/issues/680
    static func parse(_ arguments: [String]) throws(CommandFailure) -> Invocation {
        var invocation = Invocation()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if configurationFlags.contains(argument) {
                index += 1
                guard index < arguments.count else {
                    throw .usage("\(argument) のあとに構成の名前が要る (debug / release)")
                }
                invocation.configuration = arguments[index]
            } else if argument.hasPrefix("-") {
                throw .usage("知らない選択肢: \(argument)\n\n" + Command.usage())
            } else {
                guard invocation.place == nil else {
                    throw .usage("場所は 1 つだけ: \(argument)")
                }
                invocation.place = argument
            }
            index += 1
        }
        return invocation
    }
}
