// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// frame-rate-probe の引数の解き方。
//
// **解けない引数は、使い方の誤りとして断る** (理由を標準エラーへ書いて `exit(2)`)。
// 知らない引数だけが断られ、値を取る引数の値が欠けている・数でない・意味のない数のときは
// 黙って既定のまま走っていた (#2490)。`--seconds nan` は測り終える条件が永遠に偽になり、
// プロセスが終わらない。
//
// main.swift の最上位は走らせると窓を開いてしまうので、解き方だけをここへ出して
// 検査から呼べるようにしてある (FrameRateProbeTests)。

import Foundation

/// 解いた引数。既定は測り始める前の値と同じ (6 秒・畳まない・画面のスリープを断る)。
struct ProbeArguments: Equatable {
    /// 測る秒数。有限の正の数。
    var seconds = 6.0
    /// 窓を畳むまでの秒数。畳まないときは `nil`。有限の 0 以上の数。
    var minimizeAfter: Double?
    /// 画面のスリープを断らない (画面が消えることそのものを測るときだけ立てる)。
    var allowsDisplaySleep = false

    /// 使い方の誤り。`message` は標準エラーへそのまま書く。
    struct Failure: Error, Equatable {
        let message: String
    }

    static func parse(_ arguments: [String]) throws -> ProbeArguments {
        var parsed = ProbeArguments()
        var rest = arguments.makeIterator()
        while let argument = rest.next() {
            switch argument {
            case "--seconds":
                parsed.seconds = try number(
                    after: argument, in: &rest, requirement: "有限の正の数") { $0 > 0 }
            case "--minimize-after":
                // **自分で畳む。** よそのプロセスの窓を osascript から畳むにはアクセシビリティの
                // 許可が要り、許可の無い環境では「検査が落ちた」と「窓を畳めなかった」を
                // 区別できない (#223)
                parsed.minimizeAfter = try number(
                    after: argument, in: &rest, requirement: "有限の 0 以上の数") { $0 >= 0 }
            case "--allow-display-sleep":
                // **画面が消えることそのものを測るときだけ外す。** 断ったまま測ると
                // 「スリープを作れなかったのに緑」という嘘が出る (#874)
                parsed.allowsDisplaySleep = true
            default:
                throw Failure(message: "知らない引数: \(argument)")
            }
        }
        return parsed
    }

    /// `flag` の次の引数を数として読む。欠けている・数でない・`nan` `inf` のような有限でない
    /// 数・`accepts` が断る数は、どれも使い方の誤りにする。
    private static func number(
        after flag: String, in rest: inout IndexingIterator<[String]>,
        requirement: String, accepts: (Double) -> Bool
    ) throws -> Double {
        guard let value = rest.next() else {
            throw Failure(message: "\(flag) には値が要る (\(requirement))")
        }
        guard let parsed = Double(value), parsed.isFinite, accepts(parsed) else {
            throw Failure(message: "\(flag) の値は\(requirement)でなければならない: \(value)")
        }
        return parsed
    }
}
