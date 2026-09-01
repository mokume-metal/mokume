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

    static func usage(_ name: String = name) -> String {
        """
        使い方: \(name) <コマンド>

          new <名前> [--path <場所>] [--local <ライブラリの場所>]
              スケッチ一式を作る。--local はこのリポジトリを直に指すとき (開発時)

          run [<場所>] [-c <構成>]
              スケッチを作って走らせる。場所を省くといまいるところ。
              -c は debug / release (省くと道具立ての既定)

          watch [<場所>] [-c <構成>]
              保存したら作り直して差し替える

          mcp [<場所>]
              エージェントの窓口を立てる (標準入出力でやりとりする)

          bundle [<場所>] [--out <置き場>]
              別の機械で動く形に束ねる (名乗りは \(AppIdentity.fileName) に書く)

          doctor [<場所>]
              動かないときに、環境の前提と手元の状態を並べる

          help
              これ

        道具: \(ToolVersion.describe())
        """
    }

    static func dispatch(_ arguments: [String]) throws(CommandFailure) {
        guard let first = arguments.first else { throw .usage(usage()) }
        let rest = Array(arguments.dropFirst())
        switch first {
        case "new":
            try NewCommand.run(rest)
        case "run":
            try RunCommand.run(rest)
        case "watch":
            try WatchCommand.run(rest)
        case "mcp":
            try MCPCommand.run(rest)
        case "bundle":
            try BundleCommand.run(rest)
        case "doctor":
            // 投げない。切り分けの口が失敗で終わると、いちばん要るときに読めない
            DoctorCommand.run(rest)
        case "help", "--help", "-h":
            print(usage())
        // **どの版にもある口に載せる。** 古い版を持つ人はこの綴りを知らないので、
        // 到達できる口は help である (#634 の完了条件 3)。ここは慣習の綴りを受けるだけ
        case "version", "--version", "-v":
            print(ToolVersion.describe())
        default:
            throw .usage("知らないコマンド: \(first)\n\n" + usage())
        }
    }
}
