// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

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

    /// 区画の基準。**スケッチの場所とは別の軸である。**
    ///
    /// - Parameter workDirectory: 環境変数が与えた基準 (`nil` なら与えられていない)。
    ///   **検査から渡せる形にしてある** — 既定の ``WorkDirectory/given`` はプロセス起動時に
    ///   一度だけ評価されるので、環境変数を与えた状況を検査から作れない。
    func facetBase(workDirectory: URL? = WorkDirectory.given) -> URL {
        Self.facetBase(under: directory, workDirectory: workDirectory)
    }

    /// 区画の基準を決める、**ただ 1 つの計算**。
    ///
    /// 走らせるスケッチは `MOKUME_WORK_DIR` に従って区画を読み書きするので、道具も同じ
    /// 側を見ないと**両者が別の区画を指す** (#331)。同じ判断が `run` / `watch` / `doctor` /
    /// 窓口の 4 箇所に写されていて、そのうち 2 箇所が黙って別の値を使っていた
    /// ([#791](https://github.com/mokume-metal/mokume/issues/791)・
    /// [#730](https://github.com/mokume-metal/mokume/issues/730))。**写しを作らない。**
    ///
    /// **環境そのものは読まない。** 環境変数から基準を解く規則は ``WorkDirectory`` が
    /// 持つ 1 箇所である ([ADR-0018] 決定 2)。ここが受け取るのは解かれた結果で、道具は
    /// それに自分の既定値を当てるだけでよい。
    ///
    /// - Parameter directory: 環境変数が基準を与えていないときに使う既定値。道具ごとに
    ///   違う (スケッチの場所・窓口へ渡された場所) ので、呼ぶ側が持つ。
    ///
    /// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
    static func facetBase(under directory: URL, workDirectory: URL? = WorkDirectory.given) -> URL {
        workDirectory ?? directory
    }

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
