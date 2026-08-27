// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 入口。
///
/// **引数の解釈は自前で持つ。** 外の道具を足すほどの形ではなく (コマンド 2 つと
/// 少数の選択肢)、依存はそれ自体が更新と互換の面倒を連れてくる。
enum Command {
    static let usage = """
        使い方: mokume-cli <コマンド>

          new <名前> [--path <場所>] [--local <ライブラリの場所>]
              スケッチ一式を作る。--local はこのリポジトリを直に指すとき (開発時)

          run [<場所>]
              スケッチを作って走らせる。場所を省くといまいるところ

          watch [<場所>]
              保存したら作り直して差し替える

          mcp [<場所>]
              エージェントの窓口を立てる (標準入出力でやりとりする)

          help
              これ
        """

    static func dispatch(_ arguments: [String]) throws(CommandFailure) {
        guard let first = arguments.first else { throw .usage(usage) }
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
        case "help", "--help", "-h":
            print(usage)
        default:
            throw .usage("知らないコマンド: \(first)\n\n" + usage)
        }
    }
}
