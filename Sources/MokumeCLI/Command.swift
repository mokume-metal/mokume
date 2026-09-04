// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 入口。
///
/// **引数の解釈は自前で持つ。** 外の道具を足すほどの形ではなく (コマンド 2 つと
/// 少数の選択肢)、依存はそれ自体が更新と互換の面倒を連れてくる。
enum Command {
    /// 打たれた名前。
    ///
    /// **案内文は書き固めず、起動された名前から出す。** 配布物は `mokume` という名前で
    /// 入り、開発中は `swift run mokume-cli` で呼ばれる — どちらか一方を書き固めると、
    /// 印字した行がもう一方ではそのまま打てない。名前の正典を 2 つ持たないための一手
    /// でもある (Package.swift の product 名は SwiftPM の制約で `mokume-cli` のまま)。
    ///
    /// **どこからでも読めるようにする** (`nonisolated`)。案内文は失敗の側にも書かれて
    /// おり ([CommandFailure])、そちらは隔離を持たないため。値は起動時に決まって
    /// 変わらない文字列なので、隔離を外しても競合しない。
    nonisolated static let name = invokedName()

    /// 起動に使われた道の末尾。取れなければ配布時の名前に倒す。
    ///
    /// **URL に通さず自分で切る。** 空の道を URL(fileURLWithPath:) に渡すと今いる
    /// ディレクトリとして解決され、末尾は作業ディレクトリの名前になる — 案内文が
    /// 打てない名前を名乗ることになる (検査が拾った)。
    nonisolated static func invokedName(_ path: String = CommandLine.arguments.first ?? "")
        -> String
    {
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        return last.isEmpty ? "mokume" : last
    }

    /// 打てる口。
    ///
    /// **綴りの正典はここ 1 つ。** かつては口の名前が dispatch の `switch` と案内文に
    /// 別々の文字列リテラルで並んでおり、対応を保つ機械が居なかった
    /// ([#814](https://github.com/mokume-metal/mokume/issues/814))。いまは口を足すと
    /// ``dispatch(_:)`` の網羅 `switch` と ``usageEntry`` の両方が**コンパイラに
    /// 問われる** — 案内に並べないなら、並べないと書くことになる。
    enum Verb: String, CaseIterable {
        case new, run, watch, mcp, bundle, doctor, help, version

        /// 慣習の綴り。名前とは別に受けるだけで、案内には並べない。
        var aliases: [String] {
            switch self {
            case .help: ["--help", "-h"]
            case .version: ["--version", "-v"]
            default: []
            }
        }

        /// 打たれた綴りから口を解く。
        static func named(_ spelling: String) -> Verb? {
            allCases.first { $0.rawValue == spelling || $0.aliases.contains(spelling) }
        }

        /// 案内文に並べる 1 項目。**並べないものは `nil`。**
        ///
        /// `version` が `nil` なのは意図である — 古い版を持つ人はこの綴りを知らないので、
        /// 到達できる口は help のほうであり (#634 の完了条件 3)、案内は末尾で道具の版を
        /// 既に名乗っている。ここは慣習の綴りを受けるだけの口である。
        var usageEntry: (signature: String, description: String)? {
            switch self {
            case .new:
                (
                    "new <名前> [--path <場所>] [--local <ライブラリの場所>]",
                    "スケッチ一式を作る。--local はこのリポジトリを直に指すとき (開発時)"
                )
            case .run:
                (
                    "run [<場所>] [-c <構成>]",
                    """
                    スケッチを作って走らせる。場所を省くといまいるところ。
                    -c は debug / release (省くと道具立ての既定)
                    """
                )
            case .watch:
                ("watch [<場所>] [-c <構成>]", "保存したら作り直して差し替える")
            case .mcp:
                ("mcp [<場所>]", "エージェントの窓口を立てる (標準入出力でやりとりする)")
            case .bundle:
                (
                    "bundle [<場所>] [--out <置き場>]",
                    "別の機械で動く形に束ねる (名乗りは \(AppIdentity.fileName) に書く)"
                )
            case .doctor:
                ("doctor [<場所>]", "動かないときに、環境の前提と手元の状態を並べる")
            case .help:
                ("help", "これ")
            case .version:
                nil
            }
        }
    }

    static func usage(_ name: String = name) -> String {
        var lines = ["使い方: \(name) <コマンド>", ""]
        for verb in Verb.allCases {
            guard let entry = verb.usageEntry else { continue }
            lines.append("  \(entry.signature)")
            lines += entry.description.split(separator: "\n").map { "      \($0)" }
            lines.append("")
        }
        lines.append("道具: \(ToolVersion.describe())")
        return lines.joined(separator: "\n")
    }

    static func dispatch(_ arguments: [String]) throws(CommandFailure) {
        guard let first = arguments.first else { throw .usage(usage()) }
        let rest = Array(arguments.dropFirst())
        guard let verb = Verb.named(first) else {
            throw .usage("知らないコマンド: \(first)\n\n" + usage())
        }
        switch verb {
        case .new:
            try NewCommand.run(rest)
        case .run:
            try RunCommand.run(rest)
        case .watch:
            try WatchCommand.run(rest)
        case .mcp:
            try MCPCommand.run(rest)
        case .bundle:
            try BundleCommand.run(rest)
        case .doctor:
            // 投げない。切り分けの口が失敗で終わると、いちばん要るときに読めない
            DoctorCommand.run(rest)
        case .help:
            print(usage())
        case .version:
            print(ToolVersion.describe())
        }
    }
}
