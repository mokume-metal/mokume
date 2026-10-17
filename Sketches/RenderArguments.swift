// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// `reference-sketches --render` の引数の解き方。
//
// **解けない引数は、使い方の誤りとして断る** (理由を標準エラーへ書いて `exit(2)`)。
// `--frames` の値が欠けている・数でないときは黙って静止画の経路へ落ち、負数は
// `0..<frames` で実行時に trap し、0 は空の置き場を黙って作り、置き場を省くと `--frames` が
// 置き場の名前として読まれていた (#2490。同じ約束を frame-rate-probe の値にも通した)。
//
// main.swift の最上位は走らせると描画を始めるので、解き方だけをここへ出して検査から呼べる
// ようにしてある (MokumeCoreTests の RenderArgumentsTests)。

import Foundation

/// `--render` に続く引数。
struct RenderArguments: Equatable {
    /// 書き出す置き場。省けば `shots`。
    var directory = "shots"
    /// 連番で出す枚数。`nil` なら 1 枚ずつ (静止画)。1 以上。
    var frames: Int?

    /// 使い方の誤り。`message` は標準エラーへそのまま書く。
    struct Failure: Error, Equatable {
        let message: String
    }

    /// - Parameter arguments: `--render` より後ろ。
    static func parse(_ arguments: [String]) throws -> RenderArguments {
        var parsed = RenderArguments()
        var directoryGiven = false
        var rest = arguments.makeIterator()
        while let argument = rest.next() {
            if argument == "--frames" {
                guard let value = rest.next() else {
                    throw Failure(message: "--frames には枚数が要る (1 以上の整数)")
                }
                guard let count = Int(value), count >= 1 else {
                    throw Failure(message: "--frames の値は 1 以上の整数でなければならない: \(value)")
                }
                parsed.frames = count
            } else if argument.hasPrefix("--") {
                throw Failure(message: "知らない引数: \(argument)")
            } else if directoryGiven {
                throw Failure(message: "置き場は 1 つだけ渡す: \(parsed.directory) のほかに \(argument)")
            } else {
                parsed.directory = argument
                directoryGiven = true
            }
        }
        return parsed
    }
}
